import Foundation
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

/// A server that answers from memory and records what the app asked.
final class ModelFakeServer: ServerAPI, TerminalBackend, @unchecked Sendable {
    let server: ServerInfo
    let events: AsyncStream<ClientEvent>
    private let continuation: AsyncStream<ClientEvent>.Continuation
    private let lock = NSLock()
    private var _live: [SessionInfo] = []
    private var _catalog: CatalogPage
    private var _created: [CreateSession] = []
    private var _closed: [SessionId] = []
    private var _references: [[SessionId]] = []
    private var _mutations: [ProjectIntent] = []

    init(identity: ServerId = ServerId(), catalog: CatalogPage) {
        server = ServerInfo(build: BuildInfo(version: "test"), instance: 1, server: identity)
        _catalog = catalog
        (events, continuation) = AsyncStream<ClientEvent>.makeStream()
    }

    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var live: [SessionInfo] {
        get { locked { _live } }
        set { locked { _live = newValue } }
    }

    var catalogPage: CatalogPage {
        get { locked { _catalog } }
        set { locked { _catalog = newValue } }
    }

    var created: [CreateSession] { locked { _created } }
    var closed: [SessionId] { locked { _closed } }
    var references: [[SessionId]] { locked { _references } }
    var mutations: [ProjectIntent] { locked { _mutations } }

    func send(_ event: ClientEvent) { continuation.yield(event) }

    var terminalBackend: TerminalBackend { self }
    func close() { continuation.finish() }

    func sessions() async throws -> [SessionInfo] { live }

    func createSession(_ session: CreateSession) async throws -> SessionInfo {
        let info = SessionInfo(project: session.project, id: SessionId(), directory: session.directory)
        locked {
            _created.append(session)
            _live.append(info)
        }
        return info
    }

    func closeSession(_ session: SessionId, operation: OperationId) async throws {
        locked { _closed.append(session) }
    }

    func endSession(_ session: SessionId) async throws { locked { _closed.append(session) } }
    func cancelCreation(_ operation: OperationId) async throws {}
    func writeInput(session: SessionId, bytes: Data) async throws {}

    func syncSessionReferences(owner: OperationId?, revision: UInt64, sessions: [SessionId]) async throws {
        locked { _references.append(sessions) }
    }

    func availableProjectSessions(_ project: ProjectId) async throws -> [ProjectSession] { [] }
    func catalog() async throws -> CatalogPage { catalogPage }

    func mutateProject(_ intent: ProjectIntent) async throws -> UInt64 {
        locked {
            _mutations.append(intent)
            if case .create(let descriptor) = intent.mutation {
                _catalog.projects.append(descriptor)
                _catalog.revision += 1
            }
            return _catalog.revision
        }
    }

    func listFolders(_ path: ServerPath) async throws -> [ServerPath] { [] }
    func activity() async throws -> ActivitySnapshot { ActivitySnapshot() }
    func acknowledgeActivity(_ events: [UInt64]) async throws {}
    func claimActivity(_ events: [UInt64]) async throws -> [UInt64] { events }
    func git(_ request: GitRequest) async throws -> GitReply { .summary(nil) }
    func files(_ request: FilesRequest) async throws -> FilesReply { .entries([]) }
    func serverSettings() async throws -> ServerSettingsDoc { ServerSettingsDoc() }
    func writeServerSettings(_ settings: ServerSettingsDoc) async throws {}
    func stopServer(force: Bool) async throws -> Bool { true }
    func restartServer() async throws {}

    func remoteAccess() async throws -> RemoteAccessState {
        RemoteAccessState(revision: 0, settings: RemoteAccessSettings(), status: .disabled)
    }

    func writeRemoteAccess(_ settings: RemoteAccessSettings) async throws -> RemoteAccessState { try await remoteAccess() }
    func startPairing(hosts: [String]) async throws -> PairingOffer { throw ClientError.disconnected }
    func cancelPairing() async throws -> RemoteAccessState { try await remoteAccess() }
    func revokeDevice(_ device: DeviceId) async throws -> RemoteAccessState { try await remoteAccess() }

    // MARK: TerminalBackend

    func attachTerminal(session: SessionId, size: Size) async throws -> TerminalAttachment { throw ClientError.disconnected }
    func detach(channel: ChannelId) async throws {}
    func sendInput(channel: ChannelId, _ input: TerminalInput) throws {}
    func ack(channel: ChannelId, seq: UInt64) throws {}
    func resize(channel: ChannelId, size: Size) throws {}
    func scroll(channel: ChannelId, _ scroll: ScrollRequest) throws {}
    func sendCellSize(channel: ChannelId, _ cell: CellSize) throws {}
    func clear(channel: ChannelId) throws {}

    func historyPage(channel: ChannelId, before: HistoryCursor?, maxRows: UInt16) async throws -> HistoryPage {
        throw ClientError.disconnected
    }

    func searchHistory(_ source: SearchSource, query: String, ignoreCase: Bool, before: HistoryCursor?,
                       maxResults: UInt16) async throws -> SearchPage {
        throw ClientError.disconnected
    }

    func setTerminalColors(_ colors: TerminalColors) async throws {}
    func upload(session: SessionId, name: String, bytes: Data) async throws -> ServerPath { "/tmp/upload" }
}

/// Connects every request to the same fake server.
struct FakeConnector: ServerConnector {
    let server: ModelFakeServer
    func connect() async throws -> ServerAPI { server }
}

enum ModelFixtures {
    /// A short temporary profile folder.
    static func profile() throws -> TabDirs {
        let root = URL(fileURLWithPath: "/tmp/tab-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TabDirs(root: root)
    }

    /// A real folder to add as a project.
    static func folder(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: "/tmp/tab-folders-\(UUID().uuidString.prefix(8))/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @MainActor
    static func model(_ dirs: TabDirs, server: ModelFakeServer) -> AppModel {
        AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { id, _ in
            id.isLocal ? FakeConnector(server: server) : nil
        }
    }

    /// Waits for `condition`, running the main actor meanwhile.
    @MainActor
    static func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}
