import Darwin
import Foundation
import TabCore
import TabProtocol

/// Whether the local server runs, without starting it.
public enum ServerStatus: Hashable, Sendable {
    case notRunning
    case running(HelloReply)
    /// A server runs but shares no protocol version with this build.
    case incompatible(server: [ProtocolVersion])
}

/// The server in this computer's profile folder, started from `tabd` beside
/// this program when nothing listens on its socket.
public struct LocalServer: Sendable {
    public let dirs: TabDirs
    /// The server program; `nil` finds `TAB_SERVER_BIN` or `tabd` beside this program.
    public var executable: URL?
    /// The app passes its own executable so the server keeps the app's
    /// privacy permissions; see `ServerHost`.
    public var hostApp: URL?
    /// How long a started server has to listen.
    public var startTimeout: TimeInterval = 10

    public init(dirs: TabDirs, executable: URL? = nil) {
        self.dirs = dirs
        self.executable = executable
    }

    /// The server of the profile folder this build and `TAB_DIR` select.
    public static func profile() throws -> LocalServer {
        LocalServer(dirs: try TabDirs.profile())
    }

    public var socket: URL { dirs.serverSocket }

    /// Connects and shakes hands, first starting the server if `start`.
    public func connect(kind: ClientKind, start: Bool = true, clientId: ClientId? = nil,
                        timeout: TimeInterval = 5) async throws -> ServerClient {
        let stream = try await blocking { [self] in try start ? listeningStream() : runningStream() }
        return try await ServerClient.connect(stream: stream, kind: kind, clientId: clientId, timeout: timeout)
    }

    /// The server's state, without starting it.
    public func status(timeout: TimeInterval = 5) async -> ServerStatus {
        do {
            let client = try await connect(kind: .cli, start: false, timeout: timeout)
            defer { client.close() }
            return .running(client.hello)
        } catch ClientError.versionUnsupported(let versions) {
            return .incompatible(server: versions)
        } catch {
            return .notRunning
        }
    }

    /// A connected socket to a running server; `notRunning` when none listens.
    public func runningStream() throws -> FileDescriptorStream {
        do {
            return try FileDescriptorStream.connect(unixSocket: socket.path)
        } catch let error as TransportError where Self.unavailable(error) {
            throw LocalServerError.notRunning
        } catch {
            throw ClientError(error)
        }
    }

    /// A connected socket, starting the server when nothing listens, such as
    /// when its socket is missing or left behind by a crash. Blocks until it
    /// listens or `startTimeout` passes. One process starts it at a time.
    public func listeningStream() throws -> FileDescriptorStream {
        let lock = try StartupLock(dirs.root.appendingPathComponent("server.startup-lock"), wait: startTimeout)
        defer { lock.release() }
        if let stream = try connectIfListening() { return stream }
        try launch()
        let deadline = Date().addingTimeInterval(startTimeout)
        while Date() < deadline {
            if let stream = try connectIfListening() { return stream }
            usleep(25_000)
        }
        throw LocalServerError.didNotStart(log: dirs.serverLog.path)
    }

    private func connectIfListening() throws -> FileDescriptorStream? {
        do {
            return try FileDescriptorStream.connect(unixSocket: socket.path)
        } catch let error as TransportError where Self.unavailable(error) {
            return nil
        } catch {
            throw ClientError(error)
        }
    }

    /// Starts the server detached, with its output appended to `server.log`.
    public func launch() throws {
        let server = try executable ?? Executable.serverURL()
        guard Executable.isExecutableFile(server) else { throw ExecutableError.notFound(server.path) }
        var environment = ProcessInfo.processInfo.environment
        environment["TAB_DIR"] = dirs.root.path
        let arguments = Self.serverArguments(dirs)
        if let app = hostApp ?? ServerHost.app(for: server) {
            try DetachedProcess.spawn(app, arguments: [ServerHost.flag] + arguments, environment: environment,
                                      log: dirs.serverLog, disclaim: true)
        } else {
            try DetachedProcess.spawn(server, arguments: arguments, environment: environment, log: dirs.serverLog)
        }
    }

    /// The server's command line for a profile folder.
    public static func serverArguments(_ dirs: TabDirs) -> [String] {
        ["--socket", dirs.serverSocket.path, "--settings", dirs.serverSettings.path, "--log", dirs.serverLog.path]
    }

    /// Nothing listens: the socket is missing, or a crashed server left it.
    static func unavailable(_ error: TransportError) -> Bool {
        if case .system(_, let code) = error { return code == ECONNREFUSED || code == ENOENT }
        return false
    }
}

public enum LocalServerError: Error, Hashable, Sendable, CustomStringConvertible {
    case notRunning
    case didNotStart(log: String)
    case busy

    public var description: String {
        switch self {
        case .notRunning: "the server isn't running"
        case .didNotStart(let log): "the server didn't start; see \(log)"
        case .busy: "another program is starting the server"
        }
    }
}

extension LocalServerError: LocalizedError {
    public var errorDescription: String? { description }
}

/// An exclusive `flock` on a file, so only one process starts the server.
struct StartupLock {
    private let descriptor: Int32

    init(_ url: URL, wait: TimeInterval) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ClientError.transport("open \(url.path): \(String(cString: strerror(errno)))") }
        let deadline = Date().addingTimeInterval(wait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(descriptor)
                throw LocalServerError.busy
            }
            usleep(25_000)
        }
        self.descriptor = descriptor
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Runs blocking work, such as connecting or waiting for a process, off the
/// cooperative thread pool.
func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try work() })
        }
    }
}
