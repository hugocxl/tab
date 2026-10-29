import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

/// A profile folder in `/tmp` with a short path, so the socket fits `SUN_LEN`.
func makeShortTemporaryFolder() throws -> URL {
    var template = Array("/tmp/tabXXXXXX".utf8CString)
    guard let path = mkdtemp(&template) else { throw POSIXError(.EIO) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true).resolvingSymlinksInPath()
}

/// A real server in a temporary profile, serving its Unix socket in this process.
final class CoreTestServer {
    let root: URL
    let configuration: ServerConfiguration
    private(set) var server: Server
    private(set) var runner: ServerRunner?

    /// - Parameter shell: written to `server.json` before the server starts,
    ///   so tests don't depend on the user's shell configuration.
    init(root: URL? = nil, shell: String = "/bin/sh", start: Bool = true) throws {
        let root = try root ?? makeShortTemporaryFolder()
        self.root = root
        let dirs = TabDirs(root: root)
        if !FileManager.default.fileExists(atPath: dirs.serverSettings.path) {
            let settings = #"{"defaultShell":"\#(shell)","historyBudgetBytes":1048576,"shellIntegration":false}"#
            try Data(settings.utf8).write(to: dirs.serverSettings)
        }
        configuration = ServerConfiguration(dirs: dirs, uploads: root.appendingPathComponent("uploads"),
                                            homeDirectory: root.path)
        server = try Server(configuration: configuration)
        if start { runner = try server.start() }
    }

    func connect(kind: ClientKind = .desktop, clientId: ClientId? = nil) throws -> CoreTestClient {
        let stream = try FileDescriptorStream.connect(unixSocket: configuration.socket.path)
        let client = CoreTestClient(stream: stream)
        try client.hello(kind: kind, clientId: clientId)
        return client
    }

    /// Stops the server and starts a new one on the same profile.
    func restart() throws {
        stop()
        server = try Server(configuration: configuration)
        runner = try server.start()
    }

    func stop() {
        guard let runner else { return }
        runner.stop()
        runner.wait()
        self.runner = nil
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: root)
    }
}

enum CoreTestError: Error, CustomStringConvertible {
    case timeout(String)
    case unexpected(String)

    var description: String {
        switch self {
        case .timeout(let what): "timed out waiting for \(what)"
        case .unexpected(let what): "unexpected \(what)"
        }
    }
}

/// A protocol client that records everything the server sends.
final class CoreTestClient: @unchecked Sendable {
    let connection: FrameConnection
    private let condition = NSCondition()
    private var nextRequest: UInt32 = 0
    private var replies: [RequestId: ReplyBody] = [:]
    private var receivedEvents: [EventBody] = []
    private var generation = 0
    private var frames: [ChannelId: [ScreenFrame]] = [:]
    private var messages: [ChannelId: [SessionMessage]] = [:]
    private var screens: [ChannelId: [UInt16: String]] = [:]
    private var closedFlag = false
    var isClosed: Bool { condition.withLock { closedFlag } }
    var events: [EventBody] { condition.withLock { receivedEvents } }

    init(stream: ByteStream) {
        connection = FrameConnection(stream: stream)
        connection.start(onFrame: { [weak self] frame in self?.received(frame) },
                         onClose: { [weak self] _ in self?.closed() })
    }

    deinit { connection.close() }

    func close() { connection.close() }

    private func received(_ frame: IncomingFrame) {
        condition.withLock {
            switch frame {
            case .message(.reply(let id, let body)): replies[id] = body
            case .message(.event(let event)): receivedEvents.append(event)
            case .screen(let channel, let screen):
                frames[channel, default: []].append(screen)
                var rows = screen.reset ? [:] : screens[channel] ?? [:]
                for row in screen.rows { rows[row.index] = row.runs.map(\.text).joined() }
                screens[channel] = rows
            case .session(let channel, let message): messages[channel, default: []].append(message)
            default: break
            }
            generation += 1
            condition.broadcast()
        }
    }

    private func closed() {
        condition.withLock {
            closedFlag = true
            generation += 1
            condition.broadcast()
        }
    }

    /// Waits until `check` returns a value, re-checking after every frame.
    /// `check` runs without the lock, so it may use the accessors.
    @discardableResult
    func wait<T>(_ what: String, timeout: TimeInterval = 10, _ check: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let seen = condition.withLock { generation }
            if let value = check() { return value }
            let changed = condition.withLock { () -> Bool in
                while generation == seen, condition.wait(until: deadline) {}
                return generation != seen
            }
            if !changed {
                if let value = check() { return value }
                throw CoreTestError.timeout(what)
            }
        }
    }

    @discardableResult
    func send(_ body: RequestBody) throws -> RequestId {
        let id = condition.withLock { () -> RequestId in
            nextRequest += 1
            return RequestId(nextRequest)
        }
        try connection.send(.request(id, body))
        return id
    }

    func reply(to id: RequestId, timeout: TimeInterval = 10) throws -> ReplyBody {
        try wait("reply \(id)", timeout: timeout) { condition.withLock { replies.removeValue(forKey: id) } }
    }

    func request(_ body: RequestBody, timeout: TimeInterval = 10) throws -> ReplyBody {
        try reply(to: try send(body), timeout: timeout)
    }

    func hello(kind: ClientKind, clientId: ClientId?) throws {
        guard case .hello = try request(.hello(Hello(client: kind, clientId: clientId))) else {
            throw CoreTestError.unexpected("hello reply")
        }
    }

    // MARK: Sessions

    func home() throws -> ProjectId {
        guard case .catalog(let page) = try request(.readCatalog(after: nil, revision: nil)) else {
            throw CoreTestError.unexpected("catalog reply")
        }
        return page.home
    }

    func createSession(project: ProjectId, directory: String, size: Size = Size(cols: 80, rows: 24),
                       command: String? = nil) throws -> SessionInfo {
        let reply = try request(.createSession(CreateSession(project: project, directory: ServerPath(directory),
                                                             size: size, command: command)))
        guard case .sessionCreated(let info) = reply else { throw CoreTestError.unexpected("\(reply)") }
        return info
    }

    func attach(_ session: SessionId, size: Size = Size(cols: 80, rows: 24)) throws -> AttachSnapshot {
        let reply = try request(.attach(session: session, size: size))
        guard case .attached(let snapshot, _) = reply else { throw CoreTestError.unexpected("\(reply)") }
        condition.withLock {
            screens[snapshot.channel] = Dictionary(snapshot.rows.map {
                ($0.index, $0.runs.map(\.text).joined())
            }, uniquingKeysWith: { _, new in new })
        }
        return snapshot
    }

    func sessions() throws -> [SessionInfo] {
        guard case .sessions(let sessions) = try request(.listSessions) else {
            throw CoreTestError.unexpected("sessions reply")
        }
        return sessions
    }

    func type(_ text: String, on channel: ChannelId) throws {
        try connection.send(.input(.text(text)), on: channel)
    }

    func ack(_ seq: UInt64, on channel: ChannelId) throws {
        try connection.send(.ack(seq), on: channel)
    }

    /// The screen's rows as text, top to bottom, from the attach snapshot and the frames since.
    func screen(_ channel: ChannelId) -> [String] {
        condition.withLock {
            let rows = screens[channel] ?? [:]
            return rows.keys.sorted().map { rows[$0] ?? "" }
        }
    }

    func frames(_ channel: ChannelId) -> [ScreenFrame] {
        condition.withLock { frames[channel] ?? [] }
    }

    func messages(_ channel: ChannelId) -> [SessionMessage] {
        condition.withLock { messages[channel] ?? [] }
    }

    /// Acks every frame as it arrives until a screen row, trimmed, is `text`.
    func waitForRow(_ text: String, on channel: ChannelId, timeout: TimeInterval = 15) throws {
        var acked: UInt64 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (found, latest) = condition.withLock { () -> (Bool, UInt64?) in
                let rows = screens[channel] ?? [:]
                return (rows.values.contains { $0.trimmingCharacters(in: .whitespaces) == text },
                        frames[channel]?.last?.seq)
            }
            if found { return }
            if let latest, latest > acked {
                acked = latest
                try ack(latest, on: channel)
            }
            _ = try? wait("a frame", timeout: 0.2) { () -> Bool? in
                (self.frames(channel).last?.seq ?? 0) > acked ? true : nil
            }
        }
        throw CoreTestError.timeout("row \(text) in \(screen(channel))")
    }
}

extension ReplyBody {
    var errorCode: ErrorCode? {
        if case .error(let error) = self { return error.code }
        return nil
    }
}

extension SavedScreen {
    var text: [String] { rows.map { $0.runs.map(\.text).joined() } }
}
