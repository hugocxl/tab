import Foundation
import Network
import TabClient
import TabCore
import TabProtocol

/// Loopback addresses in a remote tab's browser. WebKit never sends
/// `localhost`, `127.0.0.1` or `[::1]` through a proxy, so a remote tab
/// loads them under reserved names that `ServerProxy` maps back, and shows
/// and saves the real ones.
enum RemoteLoopback {
    static let suffix = ".tab-remote"
    private static let ip6Name = "ip6-localhost"

    /// `url` with a loopback host replaced by its reserved name.
    static func proxied(_ url: String) -> String {
        guard var components = URLComponents(string: url), let host = components.host?.lowercased() else { return url }
        switch host {
        case "localhost", "127.0.0.1": components.host = host + suffix
        case "::1", "[::1]": components.host = ip6Name + suffix
        default: return url
        }
        return components.string ?? url
    }

    /// `url` with a reserved name replaced by the loopback host it stands for.
    static func unproxied(_ url: String) -> String {
        guard var components = URLComponents(string: url), let host = components.host?.lowercased(),
              host.hasSuffix(suffix) else { return url }
        let real = String(host.dropLast(suffix.count))
        guard real == "localhost" || real == "127.0.0.1" || real == ip6Name else { return url }
        components.host = real == ip6Name ? "[::1]" : real
        return components.string ?? url
    }

    /// The host the server connects to for a name the browser asked for.
    static func serverHost(_ host: String) -> String {
        let lowered = host.lowercased()
        guard lowered.hasSuffix(suffix) else { return host }
        let real = String(lowered.dropLast(suffix.count))
        return real == ip6Name ? "::1" : real
    }

    /// Whether `url` names this computer, which a remote tab must not load directly.
    static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }
}

/// A SOCKS5 proxy on this Mac's loopback that sends a remote tab's browser
/// traffic through its server, one tunnel per connection, so pages load
/// from the server's network and `localhost` is the server's. It takes only
/// its random per-launch credentials, so other users of this Mac can't reach
/// the server through it, and passes names on for the server to resolve.
final class ServerProxy: @unchecked Sendable {
    let username = UUID().uuidString
    let password = UUID().uuidString
    private(set) var port: UInt16 = 0

    private let queue: DispatchQueue
    private let listener: NWListener
    /// The server's connection when it is connected.
    private let server: @Sendable () async -> ServerAPI?

    init(name: String, server: @escaping @Sendable () async -> ServerAPI?) throws {
        queue = DispatchQueue(label: "com.hugocorta.tab.browser.proxy.\(name)")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.server = server
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        listener.stateUpdateHandler = nil
        guard let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw ModelError("The browser's proxy for \(name) didn't start")
        }
        self.port = port
    }

    deinit {
        listener.cancel()
    }

    func stop() {
        listener.cancel()
    }

    /// The proxy settings for a website data store.
    var configuration: ProxyConfiguration {
        let proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any))
        proxy.applyCredential(username: username, password: password)
        return proxy
    }

    private func accept(_ connection: NWConnection) {
        let session = ProxyConnection(connection: connection, proxy: self)
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        session.start()
    }

    // MARK: One connection

    /// One browser connection: the handshake, then bytes both ways through a tunnel.
    private final class ProxyConnection: @unchecked Sendable {
        let connection: NWConnection
        let proxy: ServerProxy
        private var buffer = Data()

        init(connection: NWConnection, proxy: ServerProxy) {
            self.connection = connection
            self.proxy = proxy
        }

        func start() {
            read { [self] in greeting() }
        }

        /// Reads more into `buffer`, then runs `next`.
        private func read(_ next: @escaping () -> Void) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
                if let data { buffer.append(data) }
                guard error == nil, !complete || data?.isEmpty == false else {
                    connection.cancel()
                    return
                }
                next()
            }
        }

        private func handle<T: Equatable>(_ result: SOCKS5.Parse<T>, again: @escaping () -> Void, then: (T) -> Void) {
            switch result {
            case .needMore:
                read(again)
            case .invalid(let reply):
                finish(reply)
            case .done(let value, let consumed):
                buffer.removeFirst(consumed)
                then(value)
            }
        }

        private func greeting() {
            handle(SOCKS5.greeting(buffer), again: { [self] in greeting() }) { offersPassword in
                guard offersPassword else { return finish(Data([SOCKS5.version, SOCKS5.noAcceptableMethod])) }
                send(Data([SOCKS5.version, SOCKS5.userPassword])) { [self] in credentials() }
            }
        }

        private func credentials() {
            let result = SOCKS5.credentials(buffer, username: proxy.username, password: proxy.password)
            handle(result, again: { [self] in credentials() }) { matches in
                guard matches else { return finish(Data([1, 1])) }
                send(Data([1, 0])) { [self] in request() }
            }
        }

        private func request() {
            handle(SOCKS5.request(buffer), again: { [self] in request() }) { target in
                open(target)
            }
        }

        private func open(_ target: SOCKS5.Target) {
            let host = RemoteLoopback.serverHost(target.host)
            Task { [self] in
                guard let api = await proxy.server() else { return finish(SOCKS5.reply(.networkUnreachable)) }
                do {
                    let tunnel = try await api.openTunnel(host: host, port: target.port)
                    send(SOCKS5.reply(.succeeded)) { [self] in
                        let early = buffer
                        buffer = Data()
                        TunnelPump.run(connection, tunnel, early: early)
                    }
                } catch let failure as TunnelFailure {
                    finish(SOCKS5.reply(Self.reply(for: failure)))
                } catch {
                    finish(SOCKS5.reply(.generalFailure))
                }
            }
        }

        private static func reply(for failure: TunnelFailure) -> SOCKS5.Reply {
            switch failure {
            case .refused: .refused
            case .unreachable, .nameNotFound: .hostUnreachable
            case .timedOut: .timedOut
            case .tooMany, .failed, .unknown: .generalFailure
            }
        }

        private func send(_ data: Data, then: @escaping () -> Void) {
            connection.send(content: data, completion: .contentProcessed { [self] error in
                guard error == nil else { return connection.cancel() }
                then()
            })
        }

        private func finish(_ reply: Data?) {
            guard let reply else { return connection.cancel() }
            connection.send(content: reply, isComplete: true, completion: .contentProcessed { [self] _ in connection.cancel() })
        }
    }
}
