import Foundation
import Network
import TabProtocol

/// Copies a local TCP connection and a tunnel into each other until both
/// ends finished, granting the server credit only as its bytes are written
/// locally. The connection must be started.
public enum TunnelPump {
    /// - Parameter early: bytes the connection sent before the tunnel opened.
    public static func run(_ connection: NWConnection, _ tunnel: Tunnel, early: Data = Data()) {
        Task {
            if !early.isEmpty {
                do {
                    try await tunnel.write(early)
                } catch {
                    connection.cancel()
                    return
                }
            }
            upload(connection, tunnel)
        }
        Task {
            for await chunk in tunnel.bytes {
                guard await send(chunk, on: connection) else {
                    tunnel.close()
                    return
                }
                tunnel.consumed(chunk.count)
            }
            if tunnel.failure != nil {
                connection.cancel()
            } else {
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
    }

    private static func upload(_ connection: NWConnection, _ tunnel: Tunnel) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Limits.maxStreamChunk) { data, _, complete, error in
            Task {
                if let data, !data.isEmpty {
                    do {
                        try await tunnel.write(data)
                    } catch {
                        connection.cancel()
                        return
                    }
                }
                if error != nil {
                    tunnel.close()
                    connection.cancel()
                } else if complete {
                    tunnel.finishWriting()
                } else {
                    upload(connection, tunnel)
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}

/// Exposes a port of the server's on this computer's loopback: each
/// connection to `localPort` becomes a tunnel to `localhost:remotePort` on
/// the server. It covers what pages and simulators on the server can't reach,
/// such as a phone on the desk against the server's Metro.
public final class PortForwarder: @unchecked Sendable {
    public let remotePort: UInt16
    public private(set) var localPort: UInt16 = 0

    private let listener: NWListener
    private let queue: DispatchQueue
    private let open: @Sendable (UInt16) async throws -> Tunnel

    /// Listens on `127.0.0.1:localPort`, or a free port for `nil`.
    /// - Parameter open: opens a tunnel to the server's `localhost` on a port.
    public init(remotePort: UInt16, localPort: UInt16?, open: @escaping @Sendable (UInt16) async throws -> Tunnel) throws {
        self.remotePort = remotePort
        self.open = open
        queue = DispatchQueue(label: "TabClient.forward.\(remotePort)")
        let parameters = NWParameters.tcp
        let port = localPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failure.error = error
                ready.signal()
            case .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        listener.stateUpdateHandler = nil
        guard failure.error == nil, let bound = listener.port?.rawValue, bound != 0 else {
            listener.cancel()
            throw ClientError.transport("port \(localPort.map(String.init) ?? "") on this computer: "
                + (failure.error.map { "\($0)" } ?? "it didn't open"))
        }
        self.localPort = bound
    }

    deinit {
        listener.cancel()
    }

    public func stop() {
        listener.cancel()
    }

    private final class FailureBox: @unchecked Sendable {
        var error: NWError?
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        let remotePort = remotePort
        let open = open
        Task {
            do {
                TunnelPump.run(connection, try await open(remotePort))
            } catch {
                connection.cancel()
            }
        }
    }
}
