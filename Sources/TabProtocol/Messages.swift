import Foundation

/// A JSON message on the control channel (channel 0).
public enum Message: Hashable, Codable, Sendable {
    /// Every request gets exactly one reply with the same id.
    case request(RequestId, RequestBody)
    case reply(RequestId, ReplyBody)
    case event(EventBody)
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "request":
            let id: RequestId = try c("id")
            self = .request(id, (try? c("body")) ?? .unknown(Self.bodyType(c)))
        case "reply":
            let id: RequestId = try c("id")
            self = .reply(id, (try? c("body")) ?? .unknown(Self.bodyType(c)))
        case "event":
            self = .event((try? c("body")) ?? .unknown(Self.bodyType(c)))
        default:
            self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let id, let body):
            var c = try TaggedEncoding(encoder, "request")
            try c(id, "id")
            try c(body, "body")
        case .reply(let id, let body):
            var c = try TaggedEncoding(encoder, "reply")
            try c(id, "id")
            try c(body, "body")
        case .event(let body):
            var c = try TaggedEncoding(encoder, "event")
            try c(body, "body")
        case .unknown(let type):
            try TaggedEncoding(encoder, type)
        }
    }

    /// The `type` of a body this build can't read, so it can still answer.
    private static func bodyType(_ c: TaggedDecoding) -> String {
        let body = try? c.container.nestedContainer(keyedBy: TagKey.self, forKey: "body")
        return (try? body?.decode(String.self, forKey: "type")) ?? ""
    }
}

// MARK: - Handshake

/// The first request on a connection.
public struct Hello: Hashable, Codable, Sendable {
    public var versions: [ProtocolVersion]
    public var client: ClientKind
    public var clientId: ClientId?
    public var build: BuildInfo?

    public init(versions: [ProtocolVersion] = ProtocolVersion.supported, client: ClientKind,
                clientId: ClientId? = nil, build: BuildInfo? = nil) {
        self.versions = versions
        self.client = client
        self.clientId = clientId
        self.build = build
    }
}

public struct HelloReply: Hashable, Codable, Sendable {
    /// The version both sides speak from now on.
    public var version: ProtocolVersion
    public var server: ServerInfo
    public var features: [Feature]

    public init(version: ProtocolVersion, server: ServerInfo, features: [Feature] = Feature.all) {
        self.version = version
        self.server = server
        self.features = features
    }
}

// MARK: - Payloads

public struct CreateSession: Hashable, Codable, Sendable {
    public var project: ProjectId
    /// Makes retrying safe and lets the client cancel a slow start.
    public var operation: OperationId
    public var directory: ServerPath
    public var size: Size
    /// Run instead of an interactive shell, through the user's shell.
    public var command: String?
    /// More environment for the program, such as a proxy.
    public var environment: [String: String]

    public init(project: ProjectId, operation: OperationId = OperationId(), directory: ServerPath, size: Size,
                command: String? = nil, environment: [String: String] = [:]) {
        self.project = project
        self.operation = operation
        self.directory = directory
        self.size = size
        self.command = command
        self.environment = environment
    }
}

/// A color as `#rrggbb` in JSON.
public struct RGB: Hashable, Codable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var hex: String { "#" + Data([red, green, blue]).hexString }

    public init?(hex: String) {
        guard hex.hasPrefix("#"), let bytes = Data(hex: String(hex.dropFirst())), bytes.count == 3 else {
            return nil
        }
        self.init(bytes[bytes.startIndex], bytes[bytes.startIndex + 1], bytes[bytes.startIndex + 2])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = RGB(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a #rrggbb color: \(text)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The app's theme colors for a session's terminal.
public struct TerminalColors: Hashable, Codable, Sendable {
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    /// The 16 ANSI colors.
    public var ansi: [RGB]
    /// Overrides of the 256-color palette by index.
    public var palette: [Int: RGB]
    public var cursorStyle: CursorShape?
    public var cursorBlink: Bool?

    public init(foreground: RGB, background: RGB, cursor: RGB, ansi: [RGB], palette: [Int: RGB] = [:],
                cursorStyle: CursorShape? = nil, cursorBlink: Bool? = nil) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
        self.palette = palette
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
    }
}

/// Server-owned settings, kept in `server.json`.
public struct ServerSettingsDoc: Hashable, Codable, Sendable {
    /// `nil` uses the user's login shell.
    public var defaultShell: ServerPath?
    public var historyBudgetBytes: UInt64
    public var shellIntegration: Bool

    public static let defaultHistoryBudget: UInt64 = 16 * 1024 * 1024

    public init(defaultShell: ServerPath? = nil, historyBudgetBytes: UInt64 = defaultHistoryBudget,
                shellIntegration: Bool = true) {
        self.defaultShell = defaultShell
        self.historyBudgetBytes = historyBudgetBytes
        self.shellIntegration = shellIntegration
    }
}

/// What a `changed` event tells clients to read again.
public enum Topic: OpenEnum {
    case catalog
    case sessions
    case activity
    case remoteAccess
    case unknown(String)

    public static let knownCases: [Topic] = [.catalog, .sessions, .activity, .remoteAccess]

    public var rawValue: String {
        switch self {
        case .catalog: "catalog"
        case .sessions: "sessions"
        case .activity: "activity"
        case .remoteAccess: "remoteAccess"
        case .unknown(let value): value
        }
    }
}

// MARK: - Requests

public enum RequestBody: Hashable, Codable, Sendable {
    case agentModelCatalog(AgentModelCatalogRequest)
    case agentChat(AgentChatRequest)
    case agentComposerContext(AgentComposerContextRequest)
    case hello(Hello)
    case ping

    // Sessions
    case listSessions
    case createSession(CreateSession)
    case attach(session: SessionId, size: Size)
    /// Attaches without changing the session's size, e.g. for the CLI.
    case attachWithoutResize(SessionId)
    case detach(ChannelId)
    case endSession(SessionId)
    /// Ends a session unless another client shows it; safe to retry.
    case closeSession(session: SessionId, operation: OperationId)
    /// Forgets an ended session and its saved output.
    case discardSession(SessionId)
    case readSavedScreen(SessionId)
    /// History rows before `before` (newest first when `nil`) of an attached session.
    case historyPage(channel: ChannelId, before: HistoryCursor?, maxRows: UInt16)
    /// The same for a session's saved output.
    case savedHistoryPage(session: SessionId, before: HistoryCursor?, maxRows: UInt16)
    case searchHistory(source: SearchSource, query: String, ignoreCase: Bool, before: HistoryCursor?,
                       maxResults: UInt16)
    case clearScreen(ChannelId)
    case setTerminalColors(TerminalColors)
    /// The sessions this client shows, so closing the last pane ends them.
    case syncSessionReferences(owner: OperationId?, revision: UInt64, sessions: [SessionId])
    case identifyClient(ClientKind)
    case cancelCreation(OperationId)
    /// Writes bytes to a session's terminal (CLI `send`).
    case writeInput(session: SessionId, bytes: Data)

    // Catalog
    case readCatalog(after: ProjectId?, revision: UInt64?)
    case mutateProject(ProjectIntent)
    case listProjectSessions(project: ProjectId, after: SessionId?, revision: UInt64?)
    /// The folders directly inside an absolute path, for remote project pickers.
    case listFolders(ServerPath)

    // Server
    case readServerSettings
    case writeServerSettings(ServerSettingsDoc)
    /// Refused with `serverBusy` while terminals run, unless `force`.
    case stopServer(force: Bool)
    case stopServerIfIdle
    case restartServer

    // Git, files, exec, uploads
    case git(GitRequest)
    case files(FilesRequest)
    case exec(ExecRequest)
    case cancelExec(job: UInt64)
    case upload(UploadChunk)

    // Activity
    case readActivity
    case acknowledgeActivity([UInt64])
    /// This client delivers notifications for these events.
    case claimActivity([UInt64])

    // Mobile access
    case authenticate(DeviceCredential)
    case pair(PairRequest)
    case readRemoteAccess
    case writeRemoteAccess(RemoteAccessSettings)
    /// Empty `hosts` uses the server's own addresses.
    case startPairing(hosts: [String])
    case cancelPairing
    case revokeDevice(DeviceId)

    /// A request from a newer build; answer with an `unsupported` error.
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "hello": self = .hello(try c("hello"))
        case "agentModelCatalog": self = .agentModelCatalog(try c("request"))
        case "agentChat": self = .agentChat(try c("request"))
        case "agentComposerContext": self = .agentComposerContext(try c("request"))
        case "ping": self = .ping
        case "listSessions": self = .listSessions
        case "createSession": self = .createSession(try c("session"))
        case "attach": self = .attach(session: try c("session"), size: try c("size"))
        case "attachWithoutResize": self = .attachWithoutResize(try c("session"))
        case "detach": self = .detach(try c("channel"))
        case "endSession": self = .endSession(try c("session"))
        case "closeSession": self = .closeSession(session: try c("session"), operation: try c("operation"))
        case "discardSession": self = .discardSession(try c("session"))
        case "readSavedScreen": self = .readSavedScreen(try c("session"))
        case "historyPage":
            self = .historyPage(channel: try c("channel"), before: try c("before"), maxRows: try c("maxRows"))
        case "savedHistoryPage":
            self = .savedHistoryPage(session: try c("session"), before: try c("before"), maxRows: try c("maxRows"))
        case "searchHistory":
            self = .searchHistory(source: try c("source"), query: try c("query"), ignoreCase: try c("ignoreCase"),
                                  before: try c("before"), maxResults: try c("maxResults"))
        case "clearScreen": self = .clearScreen(try c("channel"))
        case "setTerminalColors": self = .setTerminalColors(try c("colors"))
        case "syncSessionReferences":
            self = .syncSessionReferences(owner: try c("owner"), revision: try c("revision"),
                                          sessions: try c("sessions"))
        case "identifyClient": self = .identifyClient(try c("kind"))
        case "cancelCreation": self = .cancelCreation(try c("operation"))
        case "writeInput": self = .writeInput(session: try c("session"), bytes: try c("bytes"))
        case "readCatalog": self = .readCatalog(after: try c("after"), revision: try c("revision"))
        case "mutateProject": self = .mutateProject(try c("intent"))
        case "listProjectSessions":
            self = .listProjectSessions(project: try c("project"), after: try c("after"), revision: try c("revision"))
        case "listFolders": self = .listFolders(try c("path"))
        case "readServerSettings": self = .readServerSettings
        case "writeServerSettings": self = .writeServerSettings(try c("settings"))
        case "stopServer": self = .stopServer(force: try c("force"))
        case "stopServerIfIdle": self = .stopServerIfIdle
        case "restartServer": self = .restartServer
        case "git": self = .git(try c("request"))
        case "files": self = .files(try c("request"))
        case "exec": self = .exec(try c("request"))
        case "cancelExec": self = .cancelExec(job: try c("job"))
        case "upload": self = .upload(try c("chunk"))
        case "readActivity": self = .readActivity
        case "acknowledgeActivity": self = .acknowledgeActivity(try c("events"))
        case "claimActivity": self = .claimActivity(try c("events"))
        case "authenticate": self = .authenticate(try c("credential"))
        case "pair": self = .pair(try c("request"))
        case "readRemoteAccess": self = .readRemoteAccess
        case "writeRemoteAccess": self = .writeRemoteAccess(try c("settings"))
        case "startPairing": self = .startPairing(hosts: try c("hosts"))
        case "cancelPairing": self = .cancelPairing
        case "revokeDevice": self = .revokeDevice(try c("device"))
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let hello):
            var c = try TaggedEncoding(encoder, "hello")
            try c(hello, "hello")
        case .agentModelCatalog(let request):
            var c = try TaggedEncoding(encoder, "agentModelCatalog")
            try c(request, "request")
        case .agentChat(let request):
            var c = try TaggedEncoding(encoder, "agentChat")
            try c(request, "request")
        case .agentComposerContext(let request):
            var c = try TaggedEncoding(encoder, "agentComposerContext")
            try c(request, "request")
        case .ping: try TaggedEncoding(encoder, "ping")
        case .listSessions: try TaggedEncoding(encoder, "listSessions")
        case .createSession(let session):
            var c = try TaggedEncoding(encoder, "createSession")
            try c(session, "session")
        case .attach(let session, let size):
            var c = try TaggedEncoding(encoder, "attach")
            try c(session, "session")
            try c(size, "size")
        case .attachWithoutResize(let session):
            var c = try TaggedEncoding(encoder, "attachWithoutResize")
            try c(session, "session")
        case .detach(let channel):
            var c = try TaggedEncoding(encoder, "detach")
            try c(channel, "channel")
        case .endSession(let session):
            var c = try TaggedEncoding(encoder, "endSession")
            try c(session, "session")
        case .closeSession(let session, let operation):
            var c = try TaggedEncoding(encoder, "closeSession")
            try c(session, "session")
            try c(operation, "operation")
        case .discardSession(let session):
            var c = try TaggedEncoding(encoder, "discardSession")
            try c(session, "session")
        case .readSavedScreen(let session):
            var c = try TaggedEncoding(encoder, "readSavedScreen")
            try c(session, "session")
        case .historyPage(let channel, let before, let maxRows):
            var c = try TaggedEncoding(encoder, "historyPage")
            try c(channel, "channel")
            try c(before, "before")
            try c(maxRows, "maxRows")
        case .savedHistoryPage(let session, let before, let maxRows):
            var c = try TaggedEncoding(encoder, "savedHistoryPage")
            try c(session, "session")
            try c(before, "before")
            try c(maxRows, "maxRows")
        case .searchHistory(let source, let query, let ignoreCase, let before, let maxResults):
            var c = try TaggedEncoding(encoder, "searchHistory")
            try c(source, "source")
            try c(query, "query")
            try c(ignoreCase, "ignoreCase")
            try c(before, "before")
            try c(maxResults, "maxResults")
        case .clearScreen(let channel):
            var c = try TaggedEncoding(encoder, "clearScreen")
            try c(channel, "channel")
        case .setTerminalColors(let colors):
            var c = try TaggedEncoding(encoder, "setTerminalColors")
            try c(colors, "colors")
        case .syncSessionReferences(let owner, let revision, let sessions):
            var c = try TaggedEncoding(encoder, "syncSessionReferences")
            try c(owner, "owner")
            try c(revision, "revision")
            try c(sessions, "sessions")
        case .identifyClient(let kind):
            var c = try TaggedEncoding(encoder, "identifyClient")
            try c(kind, "kind")
        case .cancelCreation(let operation):
            var c = try TaggedEncoding(encoder, "cancelCreation")
            try c(operation, "operation")
        case .writeInput(let session, let bytes):
            var c = try TaggedEncoding(encoder, "writeInput")
            try c(session, "session")
            try c(bytes, "bytes")
        case .readCatalog(let after, let revision):
            var c = try TaggedEncoding(encoder, "readCatalog")
            try c(after, "after")
            try c(revision, "revision")
        case .mutateProject(let intent):
            var c = try TaggedEncoding(encoder, "mutateProject")
            try c(intent, "intent")
        case .listProjectSessions(let project, let after, let revision):
            var c = try TaggedEncoding(encoder, "listProjectSessions")
            try c(project, "project")
            try c(after, "after")
            try c(revision, "revision")
        case .listFolders(let path):
            var c = try TaggedEncoding(encoder, "listFolders")
            try c(path, "path")
        case .readServerSettings: try TaggedEncoding(encoder, "readServerSettings")
        case .writeServerSettings(let settings):
            var c = try TaggedEncoding(encoder, "writeServerSettings")
            try c(settings, "settings")
        case .stopServer(let force):
            var c = try TaggedEncoding(encoder, "stopServer")
            try c(force, "force")
        case .stopServerIfIdle: try TaggedEncoding(encoder, "stopServerIfIdle")
        case .restartServer: try TaggedEncoding(encoder, "restartServer")
        case .git(let request):
            var c = try TaggedEncoding(encoder, "git")
            try c(request, "request")
        case .files(let request):
            var c = try TaggedEncoding(encoder, "files")
            try c(request, "request")
        case .exec(let request):
            var c = try TaggedEncoding(encoder, "exec")
            try c(request, "request")
        case .cancelExec(let job):
            var c = try TaggedEncoding(encoder, "cancelExec")
            try c(job, "job")
        case .upload(let chunk):
            var c = try TaggedEncoding(encoder, "upload")
            try c(chunk, "chunk")
        case .readActivity: try TaggedEncoding(encoder, "readActivity")
        case .acknowledgeActivity(let events):
            var c = try TaggedEncoding(encoder, "acknowledgeActivity")
            try c(events, "events")
        case .claimActivity(let events):
            var c = try TaggedEncoding(encoder, "claimActivity")
            try c(events, "events")
        case .authenticate(let credential):
            var c = try TaggedEncoding(encoder, "authenticate")
            try c(credential, "credential")
        case .pair(let request):
            var c = try TaggedEncoding(encoder, "pair")
            try c(request, "request")
        case .readRemoteAccess: try TaggedEncoding(encoder, "readRemoteAccess")
        case .writeRemoteAccess(let settings):
            var c = try TaggedEncoding(encoder, "writeRemoteAccess")
            try c(settings, "settings")
        case .startPairing(let hosts):
            var c = try TaggedEncoding(encoder, "startPairing")
            try c(hosts, "hosts")
        case .cancelPairing: try TaggedEncoding(encoder, "cancelPairing")
        case .revokeDevice(let device):
            var c = try TaggedEncoding(encoder, "revokeDevice")
            try c(device, "device")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

// MARK: - Replies

public enum ReplyBody: Hashable, Codable, Sendable {
    case agentModelCatalog(AgentModelCatalogReply)
    case agentChat(AgentChatSnapshot)
    case agentComposerContext(AgentComposerContextReply)
    case hello(HelloReply)
    /// The peer shares no protocol version with this server.
    case versionUnsupported(supported: [ProtocolVersion])
    case pong
    case error(ErrorReply)

    // Sessions
    case sessions([SessionInfo])
    case sessionCreated(SessionInfo)
    case attached(snapshot: AttachSnapshot, process: ForegroundProcess?)
    case detached
    case sessionEnded
    case sessionClosed
    case sessionDiscarded
    case creationCancelled
    case savedScreen(SavedScreen)
    case historyPage(HistoryPage)
    case searchPage(SearchPage)
    case screenCleared
    case terminalColorsSet
    case sessionReferencesSynced
    case clientIdentified(SessionClient)
    case inputWritten

    // Catalog
    case catalog(CatalogPage)
    case projectMutated(revision: UInt64)
    case projectSessions(ProjectSessions)
    /// Folder names, sorted ignoring case.
    case folders([ServerPath])

    // Server
    case serverSettings(ServerSettingsDoc)
    case serverSettingsWritten
    case serverStopping
    /// Terminals are running, so the server didn't stop.
    case serverBusy
    case serverRestarting

    // Git, files, exec, uploads
    case git(GitReply)
    case files(FilesReply)
    case exec(ExecResult)
    case execCancelled
    /// A chunk arrived; after the last one, the file's absolute path.
    case uploaded(ServerPath?)

    // Activity
    case activity(ActivitySnapshot)
    case activityAcknowledged
    /// The events this client now delivers notifications for.
    case activityClaimed([UInt64])

    // Mobile access
    case authenticated
    case paired(Paired)
    case remoteAccess(RemoteAccessState)
    case pairing(PairingOffer)

    /// A reply from a newer build.
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "hello": self = .hello(try c("hello"))
        case "versionUnsupported": self = .versionUnsupported(supported: try c("supported"))
        case "agentModelCatalog": self = .agentModelCatalog(try c("catalog"))
        case "agentChat": self = .agentChat(try c("snapshot"))
        case "agentComposerContext": self = .agentComposerContext(try c("context"))
        case "pong": self = .pong
        case "error": self = .error(try c("error"))
        case "sessions": self = .sessions(try c("sessions"))
        case "sessionCreated": self = .sessionCreated(try c("session"))
        case "attached": self = .attached(snapshot: try c("snapshot"), process: try c("process"))
        case "detached": self = .detached
        case "sessionEnded": self = .sessionEnded
        case "sessionClosed": self = .sessionClosed
        case "sessionDiscarded": self = .sessionDiscarded
        case "creationCancelled": self = .creationCancelled
        case "savedScreen": self = .savedScreen(try c("screen"))
        case "historyPage": self = .historyPage(try c("page"))
        case "searchPage": self = .searchPage(try c("page"))
        case "screenCleared": self = .screenCleared
        case "terminalColorsSet": self = .terminalColorsSet
        case "sessionReferencesSynced": self = .sessionReferencesSynced
        case "clientIdentified": self = .clientIdentified(try c("client"))
        case "inputWritten": self = .inputWritten
        case "catalog": self = .catalog(try c("page"))
        case "projectMutated": self = .projectMutated(revision: try c("revision"))
        case "projectSessions": self = .projectSessions(try c("page"))
        case "folders": self = .folders(try c("names"))
        case "serverSettings": self = .serverSettings(try c("settings"))
        case "serverSettingsWritten": self = .serverSettingsWritten
        case "serverStopping": self = .serverStopping
        case "serverBusy": self = .serverBusy
        case "serverRestarting": self = .serverRestarting
        case "git": self = .git(try c("reply"))
        case "files": self = .files(try c("reply"))
        case "exec": self = .exec(try c("result"))
        case "execCancelled": self = .execCancelled
        case "uploaded": self = .uploaded(try c("path"))
        case "activity": self = .activity(try c("snapshot"))
        case "activityAcknowledged": self = .activityAcknowledged
        case "activityClaimed": self = .activityClaimed(try c("events"))
        case "authenticated": self = .authenticated
        case "paired": self = .paired(try c("paired"))
        case "remoteAccess": self = .remoteAccess(try c("state"))
        case "pairing": self = .pairing(try c("offer"))
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let hello):
            var c = try TaggedEncoding(encoder, "hello")
            try c(hello, "hello")
        case .versionUnsupported(let supported):
            var c = try TaggedEncoding(encoder, "versionUnsupported")
            try c(supported, "supported")
        case .agentModelCatalog(let catalog):
            var c = try TaggedEncoding(encoder, "agentModelCatalog")
            try c(catalog, "catalog")
        case .agentChat(let snapshot):
            var c = try TaggedEncoding(encoder, "agentChat")
            try c(snapshot, "snapshot")
        case .agentComposerContext(let context):
            var c = try TaggedEncoding(encoder, "agentComposerContext")
            try c(context, "context")
        case .pong: try TaggedEncoding(encoder, "pong")
        case .error(let error):
            var c = try TaggedEncoding(encoder, "error")
            try c(error, "error")
        case .sessions(let sessions):
            var c = try TaggedEncoding(encoder, "sessions")
            try c(sessions, "sessions")
        case .sessionCreated(let session):
            var c = try TaggedEncoding(encoder, "sessionCreated")
            try c(session, "session")
        case .attached(let snapshot, let process):
            var c = try TaggedEncoding(encoder, "attached")
            try c(snapshot, "snapshot")
            try c(process, "process")
        case .detached: try TaggedEncoding(encoder, "detached")
        case .sessionEnded: try TaggedEncoding(encoder, "sessionEnded")
        case .sessionClosed: try TaggedEncoding(encoder, "sessionClosed")
        case .sessionDiscarded: try TaggedEncoding(encoder, "sessionDiscarded")
        case .creationCancelled: try TaggedEncoding(encoder, "creationCancelled")
        case .savedScreen(let screen):
            var c = try TaggedEncoding(encoder, "savedScreen")
            try c(screen, "screen")
        case .historyPage(let page):
            var c = try TaggedEncoding(encoder, "historyPage")
            try c(page, "page")
        case .searchPage(let page):
            var c = try TaggedEncoding(encoder, "searchPage")
            try c(page, "page")
        case .screenCleared: try TaggedEncoding(encoder, "screenCleared")
        case .terminalColorsSet: try TaggedEncoding(encoder, "terminalColorsSet")
        case .sessionReferencesSynced: try TaggedEncoding(encoder, "sessionReferencesSynced")
        case .clientIdentified(let client):
            var c = try TaggedEncoding(encoder, "clientIdentified")
            try c(client, "client")
        case .inputWritten: try TaggedEncoding(encoder, "inputWritten")
        case .catalog(let page):
            var c = try TaggedEncoding(encoder, "catalog")
            try c(page, "page")
        case .projectMutated(let revision):
            var c = try TaggedEncoding(encoder, "projectMutated")
            try c(revision, "revision")
        case .projectSessions(let page):
            var c = try TaggedEncoding(encoder, "projectSessions")
            try c(page, "page")
        case .folders(let names):
            var c = try TaggedEncoding(encoder, "folders")
            try c(names, "names")
        case .serverSettings(let settings):
            var c = try TaggedEncoding(encoder, "serverSettings")
            try c(settings, "settings")
        case .serverSettingsWritten: try TaggedEncoding(encoder, "serverSettingsWritten")
        case .serverStopping: try TaggedEncoding(encoder, "serverStopping")
        case .serverBusy: try TaggedEncoding(encoder, "serverBusy")
        case .serverRestarting: try TaggedEncoding(encoder, "serverRestarting")
        case .git(let reply):
            var c = try TaggedEncoding(encoder, "git")
            try c(reply, "reply")
        case .files(let reply):
            var c = try TaggedEncoding(encoder, "files")
            try c(reply, "reply")
        case .exec(let result):
            var c = try TaggedEncoding(encoder, "exec")
            try c(result, "result")
        case .execCancelled: try TaggedEncoding(encoder, "execCancelled")
        case .uploaded(let path):
            var c = try TaggedEncoding(encoder, "uploaded")
            try c(path, "path")
        case .activity(let snapshot):
            var c = try TaggedEncoding(encoder, "activity")
            try c(snapshot, "snapshot")
        case .activityAcknowledged: try TaggedEncoding(encoder, "activityAcknowledged")
        case .activityClaimed(let events):
            var c = try TaggedEncoding(encoder, "activityClaimed")
            try c(events, "events")
        case .authenticated: try TaggedEncoding(encoder, "authenticated")
        case .paired(let paired):
            var c = try TaggedEncoding(encoder, "paired")
            try c(paired, "paired")
        case .remoteAccess(let state):
            var c = try TaggedEncoding(encoder, "remoteAccess")
            try c(state, "state")
        case .pairing(let offer):
            var c = try TaggedEncoding(encoder, "pairing")
            try c(offer, "offer")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

// MARK: - Events

/// Something the server tells every client on the control channel.
public enum EventBody: Hashable, Codable, Sendable {
    case agentChatChanged(session: SessionId, revision: UInt64)
    /// Shared state reached `revision`; read it again.
    case changed(topic: Topic, revision: UInt64)
    case sessionMetadata(session: SessionId, metadata: SessionMetadata)
    case progress(session: SessionId, progress: SessionProgress)
    case sessionEnded(session: SessionId, reason: ExitReason)
    case gitChanged(project: ProjectId)
    case filesChanged(project: ProjectId, changes: FileChanges)
    /// The server is about to restart; reconnect.
    case serverRestarting
    /// The connection is closing because of this error.
    case fatal(ErrorReply)
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "changed": self = .changed(topic: try c("topic"), revision: try c("revision"))
        case "agentChatChanged": self = .agentChatChanged(session: try c("session"), revision: try c("revision"))
        case "sessionMetadata": self = .sessionMetadata(session: try c("session"), metadata: try c("metadata"))
        case "progress": self = .progress(session: try c("session"), progress: try c("progress"))
        case "sessionEnded": self = .sessionEnded(session: try c("session"), reason: try c("reason"))
        case "gitChanged": self = .gitChanged(project: try c("project"))
        case "filesChanged": self = .filesChanged(project: try c("project"), changes: try c("changes"))
        case "serverRestarting": self = .serverRestarting
        case "fatal": self = .fatal(try c("error"))
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .changed(let topic, let revision):
            var c = try TaggedEncoding(encoder, "changed")
            try c(topic, "topic")
            try c(revision, "revision")
        case .agentChatChanged(let session, let revision):
            var c = try TaggedEncoding(encoder, "agentChatChanged")
            try c(session, "session")
            try c(revision, "revision")
        case .sessionMetadata(let session, let metadata):
            var c = try TaggedEncoding(encoder, "sessionMetadata")
            try c(session, "session")
            try c(metadata, "metadata")
        case .progress(let session, let progress):
            var c = try TaggedEncoding(encoder, "progress")
            try c(session, "session")
            try c(progress, "progress")
        case .sessionEnded(let session, let reason):
            var c = try TaggedEncoding(encoder, "sessionEnded")
            try c(session, "session")
            try c(reason, "reason")
        case .gitChanged(let project):
            var c = try TaggedEncoding(encoder, "gitChanged")
            try c(project, "project")
        case .filesChanged(let project, let changes):
            var c = try TaggedEncoding(encoder, "filesChanged")
            try c(project, "project")
            try c(changes, "changes")
        case .serverRestarting: try TaggedEncoding(encoder, "serverRestarting")
        case .fatal(let error):
            var c = try TaggedEncoding(encoder, "fatal")
            try c(error, "error")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}
