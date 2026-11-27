import CryptoKit
import Foundation
import Network
import Security
import TabProtocol
import TabShared

/// A TLS connection to a Tab server as a blocking `ByteStream`. It trusts
/// only the certificate whose SHA-256 the pairing link named: the server's
/// certificate is self-signed and names no host, so the fingerprint is the
/// whole check.
///
/// `read` and `write` block until Network.framework completes them, so call
/// them from `FrameConnection`'s threads, never from `queue`.
final class TLSStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Bytes received beyond what the last read could take.
    private var leftover = Data()

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Opens a connection to `host` and finishes the TLS handshake, or throws
    /// within `timeout`.
    static func open(host: String, port: UInt16, fingerprint: Data, timeout: TimeInterval) async throws -> TLSStream {
        let queue = DispatchQueue(label: "tabios.tls.\(host)")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 7419,
                                      using: parameters(fingerprint: fingerprint, queue: queue))
        let stream = TLSStream(connection: connection, queue: queue)
        try await stream.start(timeout: timeout)
        return stream
    }

    private static func parameters(fingerprint: Data, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            complete(certificateFingerprint(sec_trust_copy_ref(trust).takeRetainedValue()) == fingerprint)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        // The server has no idle timeout; keepalives find a dead Wi-Fi link.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .responsiveData
        return parameters
    }

    /// The SHA-256 of the leaf certificate's DER bytes.
    static func certificateFingerprint(_ trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }

    private func start(timeout: TimeInterval) async throws {
        let once = Once()
        // Cancelling the task cancels the connection, which ends the wait below.
        try await withTaskCancellationHandler {
            try await waitUntilReady(timeout: timeout, once: once)
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    private func waitUntilReady(timeout: TimeInterval, once: Once) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // `waiting` means unreachable for now; another host may answer.
                    once.run {
                        connection.cancel()
                        continuation.resume(throwing: ClientError.transport(error.localizedDescription))
                    }
                case .cancelled:
                    once.run { continuation.resume(throwing: ClientError.disconnected) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                once.run {
                    connection.cancel()
                    continuation.resume(throwing: ClientError.timeout)
                }
            }
        }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard buffer.count > 0 else { return 0 }
        if let count = takeLeftover(into: buffer) { return count }
        let semaphore = DispatchSemaphore(value: 0)
        var received: Data?
        var failure: NWError?
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, error in
            received = data
            failure = error
            semaphore.signal()
        }
        semaphore.wait()
        if let data = received, !data.isEmpty {
            let count = min(data.count, buffer.count)
            data.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: count)
            if count < data.count {
                lock.withLock { leftover.append(data.dropFirst(count)) }
            }
            return count
        }
        if let failure { throw ClientError.transport(failure.localizedDescription) }
        // A receive for at least one byte only comes back empty when the peer closed.
        return 0
    }

    private func takeLeftover(into buffer: UnsafeMutableRawBufferPointer) -> Int? {
        lock.withLock {
            guard !leftover.isEmpty else { return nil }
            let count = min(leftover.count, buffer.count)
            leftover.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: count)
            leftover.removeFirst(count)
            return count
        }
    }

    func write(_ data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: NWError?
        connection.send(content: data, completion: .contentProcessed { error in
            failure = error
            semaphore.signal()
        })
        semaphore.wait()
        if let failure { throw ClientError.transport(failure.localizedDescription) }
    }

    func close() {
        connection.cancel()
    }
}

/// Runs a block at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
