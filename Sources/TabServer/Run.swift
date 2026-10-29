import Darwin
import Foundation
import TabCore
import TabProtocol

/// Where a server keeps its files, from `tabd` arguments and `TAB_DIR`.
public struct ServerConfiguration: Sendable {
    /// The profile folder: `sessions/`, `server.pid`, `remote.json`.
    public var dirs: TabDirs
    public var socket: URL
    public var settings: URL
    public var log: URL
    /// Files uploaded for sessions.
    public var uploads: URL
    /// The Home project's folder.
    public var homeDirectory: String

    public init(dirs: TabDirs, socket: URL? = nil, settings: URL? = nil, log: URL? = nil, uploads: URL? = nil,
                homeDirectory: String? = nil) {
        self.dirs = dirs
        self.socket = socket ?? dirs.serverSocket
        self.settings = settings ?? dirs.serverSettings
        self.log = log ?? dirs.serverLog
        self.uploads = uploads ?? Uploads.systemDirectory()
        self.homeDirectory = homeDirectory ?? ProcessInfo.processInfo.environment["HOME"].flatMap {
            $0.isEmpty ? nil : $0
        } ?? NSHomeDirectory()
    }

    /// Parses `--socket PATH`, `--settings PATH` and `--log PATH`; the rest
    /// comes from the profile folder.
    public static func parse(_ arguments: [String],
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> ServerConfiguration {
        var values: [String: String] = [:]
        var iterator = arguments.makeIterator()
        while let flag = iterator.next() {
            guard ["--socket", "--settings", "--log"].contains(flag) else {
                throw ServerStartError.usage("unknown argument: \(flag)")
            }
            guard values[flag] == nil else { throw ServerStartError.usage("duplicate argument: \(flag)") }
            guard let value = iterator.next(), !value.isEmpty, !value.hasPrefix("--") else {
                throw ServerStartError.usage("\(flag) requires a path")
            }
            values[flag] = value
        }
        let dirs = try TabDirs.profile(environment: environment)
        let url = { (flag: String) in values[flag].map { URL(fileURLWithPath: $0) } }
        return ServerConfiguration(dirs: dirs, socket: url("--socket"), settings: url("--settings"), log: url("--log"),
                                   homeDirectory: environment["HOME"])
    }
}

public enum ServerStartError: Error, CustomStringConvertible, Equatable {
    case usage(String)
    /// Another server holds this profile.
    case alreadyRunning(String)

    public var description: String {
        switch self {
        case .usage(let message): message
        case .alreadyRunning(let socket): "tabd already running at \(socket)"
        }
    }
}

extension Server {
    /// Starts serving, blocks until a client or a signal stops the server,
    /// then ends every session and returns.
    public func run(handleSignals: Bool = true) throws {
        let runner = try start()
        if handleSignals { runner.stopOnSignals() }
        runner.wait()
    }

    /// Takes the profile's lock, listens on the socket and serves clients in
    /// the background. Stop it with `ServerRunner.stop()`.
    @discardableResult
    public func start() throws -> ServerRunner {
        let runner = try ServerRunner(server: self)
        runner.begin()
        return runner
    }
}

/// A started server: its lock, listener and accept thread.
public final class ServerRunner: @unchecked Sendable {
    public let server: Server
    private let lockFile: FileLock
    private let listener: UnixSocketListener
    private let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopping = false
    private var finished = false
    private var retention: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    static let retentionInterval: TimeInterval = 60 * 60

    init(server: Server) throws {
        self.server = server
        let configuration = server.configuration
        let lockFile: FileLock
        do {
            lockFile = try FileLock.tryLock(configuration.dirs.serverPid)
        } catch FileLock.Failure.held {
            throw ServerStartError.alreadyRunning(configuration.socket.path)
        }
        let descriptor = lockFile.fileDescriptor
        let pid = Data("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        self.lockFile = lockFile
        do {
            listener = try UnixSocketListener(path: configuration.socket.path)
        } catch TransportError.addressInUse {
            throw ServerStartError.alreadyRunning(configuration.socket.path)
        }
        chmod(configuration.socket.path, 0o600)
    }

    fileprivate func begin() {
        server.stopRequested = { [weak self] in self?.stop() }
        let timer = DispatchSource.makeTimerSource(queue: server.lifecycle)
        timer.schedule(deadline: .now() + Self.retentionInterval, repeating: Self.retentionInterval)
        timer.setEventHandler { [weak server] in server?.pruneExpiredSessions() }
        timer.resume()
        retention = timer
        server.services.remote?.start(acceptor: server)
        ServerLog.info("server started: socket=\(server.configuration.socket.path) pid=\(getpid())")
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "tab.server.accept"
        thread.start()
    }

    private func acceptLoop() {
        while true {
            do {
                let stream = try listener.accept()
                server.serve(stream, origin: .local)
            } catch {
                if !lock.withLock({ stopping }) {
                    ServerLog.error("accept failed: \(error)")
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                break
            }
        }
        shutdown()
    }

    /// Stops accepting, ends every session, saves, and closes connections.
    public func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopping = true }
            return !stopping
        }
        if first { listener.close() }
    }

    private func shutdown() {
        retention?.cancel()
        server.services.remote?.stop()
        server.endAllSessions()
        server.closeConnections()
        signalSources.forEach { $0.cancel() }
        var held = stat()
        let pidIdentity: (device: dev_t, inode: ino_t)? =
            fstat(lockFile.fileDescriptor, &held) == 0 ? (held.st_dev, held.st_ino) : nil
        lockFile.unlock()
        removeOwnedFile(server.configuration.dirs.serverPid.path, identity: pidIdentity)
        ServerLog.info("server stopped")
        lock.withLock { finished = true }
        stopped.signal()
    }

    /// Blocks until the server stopped.
    public func wait() {
        stopped.wait()
        stopped.signal()
    }

    /// SIGTERM and SIGINT stop the server gracefully.
    public func stopOnSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: server.lifecycle)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signalSources.append(source)
        }
    }
}
