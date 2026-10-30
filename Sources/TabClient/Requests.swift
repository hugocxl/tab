import Foundation
import TabProtocol

/// Typed requests. Each throws `ClientError.unexpectedReply` when the server
/// answers with a reply that doesn't fit.
extension ServerClient {
    /// Reads or changes a server-owned agent conversation. Disconnecting does not close it.
    public func agentChat(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
        // Startup can include initialize, resume and turn/start RPCs. The server
        // cancels a stuck submission at 120 seconds, before this budget expires.
        let reply = try await self.request(.agentChat(request), timeout: max(defaultTimeout, 180))
        guard case .agentChat(let snapshot) = reply else { throw unexpected(reply) }
        return snapshot
    }

    // MARK: Sessions

    public func ping() async throws {
        let reply = try await request(.ping)
        guard case .pong = reply else { throw unexpected(reply) }
    }

    /// Live sessions on the server.
    public func sessions() async throws -> [SessionInfo] {
        let reply = try await request(.listSessions)
        guard case .sessions(let sessions) = reply else { throw unexpected(reply) }
        return sessions
    }

    public func createSession(_ session: CreateSession) async throws -> SessionInfo {
        let reply = try await request(.createSession(session), timeout: max(defaultTimeout, 30))
        guard case .sessionCreated(let info) = reply else { throw unexpected(reply) }
        return info
    }

    /// Attaches to a session at `size`, which becomes the session's size if
    /// this client owns it.
    public func attach(session: SessionId, size: Size) async throws -> Attachment {
        try await attachment(session, .attach(session: session, size: size))
    }

    /// Attaches without changing the session's size, such as for the CLI.
    public func attachWithoutResize(session: SessionId) async throws -> Attachment {
        try await attachment(session, .attachWithoutResize(session))
    }

    private func attachment(_ session: SessionId, _ body: RequestBody) async throws -> Attachment {
        let reply = try await request(body)
        guard case .attached(let snapshot, let process) = reply,
              let events = registerChannel(snapshot.channel) else { throw unexpected(reply) }
        return Attachment(session: session, channel: snapshot.channel, snapshot: snapshot, process: process,
                          events: events)
    }

    /// Detaches a channel; its event stream finishes. A channel the server no
    /// longer knows, such as of a session that just ended, counts as detached.
    public func detach(channel: ChannelId) async throws {
        defer { finishChannel(channel) }
        do {
            let reply = try await request(.detach(channel))
            guard case .detached = reply else { throw unexpected(reply) }
        } catch let error as ClientError where error.serverCode == .unknownChannel {
            return
        }
    }

    public func endSession(_ session: SessionId) async throws {
        let reply = try await request(.endSession(session))
        guard case .sessionEnded = reply else { throw unexpected(reply) }
    }

    /// Ends a session unless another client shows it. Reuse `operation` when
    /// retrying after a lost reply.
    public func closeSession(_ session: SessionId, operation: OperationId) async throws {
        let reply = try await request(.closeSession(session: session, operation: operation))
        guard case .sessionClosed = reply else { throw unexpected(reply) }
    }

    /// Forgets an ended session and its saved output.
    public func discardSession(_ session: SessionId) async throws {
        let reply = try await request(.discardSession(session))
        guard case .sessionDiscarded = reply else { throw unexpected(reply) }
    }

    public func readSavedScreen(_ session: SessionId) async throws -> SavedScreen {
        let reply = try await request(.readSavedScreen(session))
        guard case .savedScreen(let screen) = reply else { throw unexpected(reply) }
        return screen
    }

    public func historyPage(channel: ChannelId, before: HistoryCursor?, maxRows: UInt16) async throws -> HistoryPage {
        try await history(.historyPage(channel: channel, before: before, maxRows: maxRows))
    }

    public func savedHistoryPage(session: SessionId, before: HistoryCursor?, maxRows: UInt16) async throws
        -> HistoryPage {
        try await history(.savedHistoryPage(session: session, before: before, maxRows: maxRows))
    }

    private func history(_ body: RequestBody) async throws -> HistoryPage {
        let reply = try await request(body)
        guard case .historyPage(let page) = reply else { throw unexpected(reply) }
        return page
    }

    public func searchHistory(_ source: SearchSource, query: String, ignoreCase: Bool, before: HistoryCursor? = nil,
                              maxResults: UInt16) async throws -> SearchPage {
        let reply = try await request(.searchHistory(source: source, query: query, ignoreCase: ignoreCase,
                                                     before: before, maxResults: maxResults))
        guard case .searchPage(let page) = reply else { throw unexpected(reply) }
        return page
    }

    public func clearScreen(channel: ChannelId) async throws {
        let reply = try await request(.clearScreen(channel))
        guard case .screenCleared = reply else { throw unexpected(reply) }
    }

    /// Color defaults for this connection's sessions.
    public func setTerminalColors(_ colors: TerminalColors) async throws {
        let reply = try await request(.setTerminalColors(colors))
        guard case .terminalColorsSet = reply else { throw unexpected(reply) }
    }

    /// The sessions this client shows, so closing the last pane ends them.
    public func syncSessionReferences(owner: OperationId? = nil, revision: UInt64 = 0,
                                      sessions: [SessionId]) async throws {
        let reply = try await request(.syncSessionReferences(owner: owner, revision: revision, sessions: sessions))
        guard case .sessionReferencesSynced = reply else { throw unexpected(reply) }
    }

    public func identify(_ kind: ClientKind) async throws -> SessionClient {
        let reply = try await request(.identifyClient(kind))
        guard case .clientIdentified(let client) = reply else { throw unexpected(reply) }
        return client
    }

    public func cancelCreation(_ operation: OperationId) async throws {
        let reply = try await request(.cancelCreation(operation))
        guard case .creationCancelled = reply else { throw unexpected(reply) }
    }

    /// Writes bytes to a session's terminal without attaching to it.
    public func writeInput(session: SessionId, bytes: Data) async throws {
        let reply = try await request(.writeInput(session: session, bytes: bytes))
        guard case .inputWritten = reply else { throw unexpected(reply) }
    }

    // MARK: Catalog

    public func catalogPage(after: ProjectId? = nil, revision: UInt64? = nil) async throws -> CatalogPage {
        let reply = try await request(.readCatalog(after: after, revision: revision))
        guard case .catalog(let page) = reply,
              revision.map({ $0 == page.revision }) ?? true,
              page.projects.first.map({ first in after.map { first.id > $0 } ?? true }) ?? true
        else { throw unexpected(reply) }
        return page
    }

    /// Every project at one catalog revision, retrying a few times when it
    /// changes between pages.
    public func catalog() async throws -> CatalogPage {
        for _ in 0 ..< 8 {
            do {
                return try await catalogSnapshot()
            } catch let error as ClientError where error.serverCode == .catalogChanged {
                continue
            }
        }
        throw ClientError.timeout
    }

    private func catalogSnapshot() async throws -> CatalogPage {
        var result = try await catalogPage()
        while let after = result.next {
            let page = try await catalogPage(after: after, revision: result.revision)
            if let next = page.next, next <= after {
                throw ClientError.protocolViolation("invalid catalog pagination")
            }
            result.projects += page.projects
            if result.projects.count > Limits.maxProjects {
                throw ClientError.protocolViolation("too many projects")
            }
            result.next = page.next
        }
        return result
    }

    public func mutateProject(_ intent: ProjectIntent) async throws -> UInt64 {
        let reply = try await request(.mutateProject(intent))
        guard case .projectMutated(let revision) = reply else { throw unexpected(reply) }
        return revision
    }

    public func projectSessions(_ project: ProjectId, after: SessionId? = nil, revision: UInt64? = nil) async throws
        -> ProjectSessions {
        let reply = try await request(.listProjectSessions(project: project, after: after, revision: revision))
        guard case .projectSessions(let page) = reply,
              revision.map({ $0 == page.revision }) ?? true,
              page.sessions.allSatisfy({ $0.info.project == project }),
              page.sessions.first.map({ first in after.map { first.info.id > $0 } ?? true }) ?? true
        else { throw unexpected(reply) }
        return page
    }

    /// Every session of a project at one revision, retrying when it changes.
    public func allProjectSessions(_ project: ProjectId) async throws -> [ProjectSession] {
        for _ in 0 ..< 8 {
            do {
                var page = try await projectSessions(project)
                var sessions = page.sessions
                while let after = page.next {
                    page = try await projectSessions(project, after: after, revision: page.revision)
                    if let next = page.next, next <= after {
                        throw ClientError.protocolViolation("invalid session pagination")
                    }
                    sessions += page.sessions
                    if sessions.count > Limits.maxSessionReferences {
                        throw ClientError.protocolViolation("too many sessions")
                    }
                }
                return sessions
            } catch let error as ClientError where error.serverCode == .catalogChanged {
                continue
            }
        }
        throw ClientError.timeout
    }

    /// Sessions of a project that nobody shows: live or starting, not attached.
    public func availableProjectSessions(_ project: ProjectId) async throws -> [ProjectSession] {
        try await allProjectSessions(project).filter { session in
            !session.attached && (session.status == .live || session.status == .starting)
        }
    }

    /// The folders directly inside an absolute path on the server's computer.
    public func listFolders(_ path: ServerPath) async throws -> [ServerPath] {
        let reply = try await request(.listFolders(path))
        guard case .folders(let names) = reply else { throw unexpected(reply) }
        return names
    }

    // MARK: Server

    public func serverSettings() async throws -> ServerSettingsDoc {
        let reply = try await request(.readServerSettings)
        guard case .serverSettings(let settings) = reply else { throw unexpected(reply) }
        return settings
    }

    public func writeServerSettings(_ settings: ServerSettingsDoc) async throws {
        let reply = try await request(.writeServerSettings(settings))
        guard case .serverSettingsWritten = reply else { throw unexpected(reply) }
    }

    /// Stops the server. Without `force` it refuses while terminals run and
    /// returns false.
    @discardableResult
    public func stopServer(force: Bool) async throws -> Bool {
        let reply = try await request(.stopServer(force: force))
        switch reply {
        case .serverStopping: return true
        case .serverBusy: return false
        default: throw unexpected(reply)
        }
    }

    /// Stops the server only if no terminal runs or is starting.
    public func stopServerIfIdle() async throws -> Bool {
        let reply = try await request(.stopServerIfIdle)
        switch reply {
        case .serverStopping: return true
        case .serverBusy: return false
        default: throw unexpected(reply)
        }
    }

    public func restartServer() async throws {
        let reply = try await request(.restartServer)
        guard case .serverRestarting = reply else { throw unexpected(reply) }
    }

    // MARK: Git, files, exec, uploads

    public func git(_ request: GitRequest) async throws -> GitReply {
        let reply = try await self.request(.git(request), timeout: Self.gitTimeout(request.action))
        guard case .git(let value) = reply else { throw unexpected(reply) }
        return value
    }

    public func files(_ request: FilesRequest) async throws -> FilesReply {
        let reply = try await self.request(.files(request), timeout: 300)
        guard case .files(let value) = reply else { throw unexpected(reply) }
        return value
    }

    public func exec(_ request: ExecRequest) async throws -> ExecResult {
        let reply = try await self.request(.exec(request), timeout: TimeInterval(request.timeoutMs) / 1000 + 10)
        guard case .exec(let result) = reply else { throw unexpected(reply) }
        return result
    }

    public func cancelExec(job: UInt64) async throws {
        let reply = try await request(.cancelExec(job: job))
        guard case .execCancelled = reply else { throw unexpected(reply) }
    }

    /// Sends `bytes` as a file named `name` to keep with `session` on the
    /// server's computer, in chunks, and returns its absolute path there.
    public func upload(session: SessionId, name: String, bytes: Data) async throws -> ServerPath {
        guard UInt64(bytes.count) <= Limits.maxUploadBytes else { throw ClientError.invalid(.badRequest) }
        let upload = OperationId()
        var offset = 0
        repeat {
            let end = min(offset + Limits.maxUploadChunk, bytes.count)
            let chunk = bytes.subdata(in: bytes.startIndex + offset ..< bytes.startIndex + end)
            let last = end == bytes.count
            let reply = try await request(.upload(UploadChunk(session: session, upload: upload, name: name,
                                                              offset: UInt64(offset), bytes: chunk, last: last)),
                                          timeout: 60)
            switch (reply, last) {
            case (.uploaded(let path?), true): return path
            case (.uploaded(nil), false): offset = end
            default: throw unexpected(reply)
            }
        } while true
    }

    /// The reply budget of a Git action: worktree hooks have five minutes of
    /// their own on the server, on top of the Git work.
    static func gitTimeout(_ action: GitAction) -> TimeInterval {
        if case .worktree(let intent) = action, let hooks = intent.options?.hooks, !hooks.isEmpty {
            return 610
        }
        return 300
    }

    // MARK: Activity

    public func activity() async throws -> ActivitySnapshot {
        let reply = try await request(.readActivity)
        guard case .activity(let snapshot) = reply else { throw unexpected(reply) }
        return snapshot
    }

    public func acknowledgeActivity(_ events: [UInt64]) async throws {
        let reply = try await request(.acknowledgeActivity(events))
        guard case .activityAcknowledged = reply else { throw unexpected(reply) }
    }

    /// This client delivers notifications for the returned events.
    public func claimActivity(_ events: [UInt64]) async throws -> [UInt64] {
        let reply = try await request(.claimActivity(events))
        guard case .activityClaimed(let claimed) = reply else { throw unexpected(reply) }
        return claimed
    }

    // MARK: Mobile access

    public func remoteAccess() async throws -> RemoteAccessState {
        try remoteAccess(try await request(.readRemoteAccess))
    }

    public func writeRemoteAccess(_ settings: RemoteAccessSettings) async throws -> RemoteAccessState {
        try remoteAccess(try await request(.writeRemoteAccess(settings)))
    }

    /// A pairing offer listing `hosts` before the server's own addresses.
    public func startPairing(hosts: [String] = []) async throws -> PairingOffer {
        let reply = try await request(.startPairing(hosts: hosts))
        guard case .pairing(let offer) = reply else { throw unexpected(reply) }
        return offer
    }

    public func cancelPairing() async throws -> RemoteAccessState {
        try remoteAccess(try await request(.cancelPairing))
    }

    public func revokeDevice(_ device: DeviceId) async throws -> RemoteAccessState {
        try remoteAccess(try await request(.revokeDevice(device)))
    }

    private func remoteAccess(_ reply: ReplyBody) throws -> RemoteAccessState {
        guard case .remoteAccess(let state) = reply else { throw unexpected(reply) }
        return state
    }

    private func unexpected(_ reply: ReplyBody) -> ClientError {
        .unexpectedReply(reply.typeName)
    }
}
