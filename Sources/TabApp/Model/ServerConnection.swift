import Foundation
import TabClient
import TabCore
import TabProtocol

/// Opens one connection to a server: this computer's through its socket,
/// starting `tabd` when needed, or another computer's over SSH.
public protocol ServerConnector: Sendable {
    func connect() async throws -> ServerAPI
}

/// This computer's server.
struct LocalConnector: ServerConnector {
    let server: LocalServer

    func connect() async throws -> ServerAPI {
        try await server.connect(kind: .desktop, start: true)
    }
}

/// Another computer's server, through `ssh <destination> tab stdio`.
struct RemoteConnector: ServerConnector {
    let target: SSHTarget

    func connect() async throws -> ServerAPI {
        try await RemoteServer.connect(target, start: .ifNeeded, kind: .desktop)
    }

    /// The SSH target a Remote Servers entry describes.
    static func target(_ entry: ServerEntry) throws -> SSHTarget {
        if let command = entry.sshCommand, !command.isEmpty {
            return try SSHTarget.customCommand(command)
        }
        let port = entry.port.flatMap { UInt16(exactly: $0) }
        return try SSHTarget(destination: entry.ssh, port: port, identity: entry.identityFile)
    }
}

/// Where a server connection stands.
public enum ConnectionState: Equatable, Sendable {
    /// Not connected and not trying, such as a remote server nobody opened.
    case idle
    case connecting
    case ready
    /// The connection dropped; trying again after a wait.
    case reconnecting(attempt: Int)
    /// Connecting needs the user: a login, a host key, or a missing Tab.
    case needsUser(String)

    public var isReady: Bool { self == .ready }

    /// Whether the server's projects and terminals show as offline.
    public var isOffline: Bool {
        switch self {
        case .ready, .connecting, .idle: return false
        case .reconnecting, .needsUser: return true
        }
    }
}

/// One server: a main connection for terminals, catalog and activity, and a
/// side connection for Git, files, search and uploads so they never wait
/// behind terminal traffic. Reconnects with backoff after a drop and stops
/// when the user is needed. The model handles what the server says.
@MainActor
public final class ServerConnection {
    public let id: ServerId
    public private(set) var state: ConnectionState = .idle
    public private(set) var main: ServerAPI?
    public private(set) var side: ServerAPI?
    /// The last activity the server reported.
    public internal(set) var activity = ActivitySnapshot()
    /// Terminal progress by session.
    public internal(set) var progress: [SessionId: SessionProgress] = [:]
    /// The last error, for banners and the host menu.
    public var lastError: String? { lastFailure?.description }
    /// Why the last attempt failed, while not connected.
    public private(set) var lastFailure: ClientError?

    let connector: ServerConnector
    private let backoff: @Sendable (Int) -> TimeInterval
    private var task: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var failures = 0
    private var generation = 0

    /// Called on the main actor once both connections are up.
    var onReady: ((ServerConnection) -> Void)?
    /// Every control event of the main connection.
    var onEvent: ((ServerConnection, ClientEvent) -> Void)?
    /// The state changed.
    var onStateChange: ((ServerConnection) -> Void)?

    init(id: ServerId, connector: ServerConnector,
         backoff: @escaping @Sendable (Int) -> TimeInterval = { ReconnectBackoff.delay(afterFailures: $0) }) {
        self.id = id
        self.connector = connector
        self.backoff = backoff
    }

    /// Connects unless connected or already trying.
    public func start() {
        switch state {
        case .ready, .connecting: return
        case .reconnecting where task != nil: return
        default: break
        }
        attempt(wait: false)
    }

    /// Tries again now, such as after the user typed a password or the Mac woke.
    public func retryNow() {
        guard state != .ready else { return }
        task?.cancel()
        task = nil
        attempt(wait: false)
    }

    /// Closes both connections and stops trying.
    public func disconnect() {
        generation += 1
        task?.cancel()
        task = nil
        eventTask?.cancel()
        eventTask = nil
        main?.close()
        side?.close()
        main = nil
        side = nil
        setState(.idle)
    }

    private func attempt(wait: Bool) {
        generation += 1
        let generation = generation
        setState(failures == 0 ? .connecting : .reconnecting(attempt: failures))
        let connector = connector
        let delay = wait ? backoff(failures) : 0
        task = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            do {
                let main = try await connector.connect()
                let side: ServerAPI
                do {
                    side = try await connector.connect()
                } catch {
                    main.close()
                    throw error
                }
                self?.connected(main: main, side: side, generation: generation)
            } catch {
                self?.failed(error.clientError, generation: generation)
            }
        }
    }

    private func connected(main: ServerAPI, side: ServerAPI, generation: Int) {
        guard generation == self.generation else {
            main.close()
            side.close()
            return
        }
        task = nil
        failures = 0
        lastFailure = nil
        self.main = main
        self.side = side
        let events = main.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if generation != self.generation { return }
                self.onEvent?(self, event)
                if case .disconnected = event {
                    self.dropped(generation: generation)
                    return
                }
            }
        }
        setState(.ready)
        onReady?(self)
    }

    private func failed(_ error: ClientError, generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        failures += 1
        lastFailure = error
        guard error.recoverable else {
            setState(.needsUser(error.description))
            return
        }
        attempt(wait: true)
    }

    private func dropped(generation: Int) {
        guard generation == self.generation else { return }
        eventTask = nil
        side?.close()
        main = nil
        side = nil
        failures = max(failures, 1)
        attempt(wait: true)
    }

    private func setState(_ state: ConnectionState) {
        guard state != self.state else { return }
        self.state = state
        onStateChange?(self)
    }

    /// Unread agent events for `session`.
    func unread(_ session: SessionId) -> [AgentEvent] {
        activity.events.filter { $0.session == session && !$0.read }
    }

    /// The agent running in `session`, if any.
    func agent(_ session: SessionId) -> AgentActivity? {
        activity.agents.first { $0.session == session }
    }
}
