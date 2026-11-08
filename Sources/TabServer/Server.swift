import Foundation
import TabCore
import TabProtocol
import TabTerminal

/// The services the server core dispatches to. Each is optional so a server
/// can run without them (tests); requests for a missing one fail with
/// `unsupported`.
public struct ServerServices: Sendable {
    public var git: GitServiceProtocol?
    public var worktreeGuard: WorktreeOperationGuard?
    public var files: FilesServiceProtocol?
    public var detector: AgentDetector?
    public var remote: RemoteAccessProtocol?
    public var simulators: SimulatorService?

    public init(git: GitServiceProtocol? = nil, worktreeGuard: WorktreeOperationGuard? = nil,
                files: FilesServiceProtocol? = nil, detector: AgentDetector? = nil,
                remote: RemoteAccessProtocol? = nil, simulators: SimulatorService? = nil) {
        self.git = git
        self.worktreeGuard = worktreeGuard
        self.files = files
        self.detector = detector
        self.remote = remote
        self.simulators = simulators
    }
}

/// The server core: projects, sessions and connections. Construct it, hand
/// it the services (which take it as their `WorktreeCatalog` and
/// `ServiceEvents`), then `run()` or `start()` it.
public final class Server: @unchecked Sendable {
    public let configuration: ServerConfiguration
    /// This running server, as clients see it in `HelloReply`.
    public let info: ServerInfo

    let settings: ServerSettingsStore
    let catalog: Catalog
    let tabs: TabStore
    let archive: ArchiveStore
    let activity = Activity()
    let uploads: Uploads
    let agents: AgentSessions
    let agentComposerContext: AgentComposerContextService
    let agentModelCatalog: AgentModelCatalogService
    let agentHistory: AgentHistory
    let agentTitles: AgentTitles
    let shellIntegration: ShellIntegration?
    let lifecycle = DispatchQueue(label: "tab.server.lifecycle", qos: .utility)
    /// Ends the terminals of closed panes, which can take a while, away from
    /// requests and from `lifecycle`, where ending sessions report back.
    let cleanup = DispatchQueue(label: "tab.server.cleanup", qos: .utility)

    private let serviceLock = NSLock()
    private var installedServices = ServerServices()

    // Sessions.
    private let sessionLock = NSLock()
    private var sessions: [SessionId: SessionOwner] = [:]
    private var starting: Set<SessionId> = []
    private(set) var stopping = false
    /// Serializes creating, closing and discarding sessions and catalog
    /// changes that end sessions.
    let operations = NSRecursiveLock()

    // Connections.
    private let connectionLock = NSLock()
    private var connections: [Int: ClientConnection] = [:]
    private var nextConnection = 0
    private var counters = (attachment: UInt64(0), position: UInt64(0), attachmentChanges: UInt64(0))

    /// Runs once a client asked the server to stop.
    var stopRequested: (@Sendable () -> Void)?

    public init(configuration: ServerConfiguration) throws {
        self.configuration = configuration
        let dirs = configuration.dirs
        settings = try ServerSettingsStore(url: configuration.settings)
        let archive = try ArchiveStore(root: dirs.sessions)
        self.archive = archive
        let catalog = try Catalog(directory: dirs.sessions, homeDirectory: configuration.homeDirectory,
                                  hasSavedScreen: { archive.contains($0) })
        self.catalog = catalog
        tabs = try TabStore(directory: dirs.sessions, home: catalog.homeId,
                            isProject: { (try? catalog.project($0)) != nil }, isLive: { _ in false })
        agentComposerContext = AgentComposerContextService(home: URL(fileURLWithPath: configuration.homeDirectory),
            projectDirectory: { project in
                let directory = try catalog.project(project).directory
                guard directory.isDirectory else { throw ServiceError(.badPath, "The agent's project folder is unavailable") }
                return directory.url
            })
        agentModelCatalog = AgentModelCatalogService(home: URL(fileURLWithPath: configuration.homeDirectory),
            cacheDirectory: dirs.root.appendingPathComponent("agent-model-catalog"),
            projectDirectory: { project in
                let directory = try catalog.project(project).directory
                guard directory.isDirectory else { throw ServiceError(.badPath, "The agent's project folder is unavailable") }
                return directory.url
            })
        agentHistory = AgentHistory(home: URL(fileURLWithPath: configuration.homeDirectory))
        agentTitles = AgentTitles(history: agentHistory)
        agents = try AgentSessions(root: dirs.root.appendingPathComponent("agents"), projectDirectory: { project in
            let directory = try catalog.project(project).directory
            guard directory.isDirectory else { throw ServiceError(.badPath, "The agent's project folder is unavailable") }
            return directory.rawValue
        })
        agents.launchEnvironment = ["TAB_SERVER_ID": catalog.serverId.description]
        agents.projectContext = { id in
            guard let project = try? catalog.project(id) else { return nil }
            let kind: AgentContext.Project.Kind = project.home ? .home : project.kind == .worktree
                ? .worktree(of: project.parentId.flatMap { try? catalog.project($0).name }) : .project
            return AgentContext.Project(name: project.name, directory: project.directory.rawValue, kind: kind)
        }
        agents.cliDirectory = Executable.currentURL().map { $0.deletingLastPathComponent() }
            .flatMap { Executable.isExecutableFile($0.appendingPathComponent("tab")) ? $0.path : nil }
        uploads = Uploads(directory: configuration.uploads)

        do {
            shellIntegration = try ShellIntegration.install(into: dirs.root.appendingPathComponent("shell-integration"))
        } catch {
            ServerLog.error("shell integration unavailable: \(error)")
            shellIntegration = nil
        }
        let unclean = FileManager.default.fileExists(atPath: dirs.serverRunning.path)
        if unclean { ServerLog.error("the previous server stopped without ending its sessions") }
        info = ServerInfo(build: BuildInfo(version: Release.version), instance: UInt64.random(in: 1...UInt64.max),
                          server: catalog.serverId, previousStopUnclean: unclean)
        catalog.onChange = { [weak self] revision in self?.catalogChanged(revision) }
        tabs.onChange = { [weak self] revision in self?.tabsChanged(revision) }
        activity.onChange = { [weak self] revision in self?.activityChanged(revision) }
        agents.activityChanged = { [weak self] snapshot, directory in
            guard let self else { return }
            activity.updateChat(snapshot, title: agentTitles.title(for: snapshot, directory: directory))
        }
        agentTitles.onChange = { [weak self] in self?.agents.publishActivity() }
        agents.publishActivity()
        agents.changed = { [weak self] session, revision in
            self?.broadcast(.agentChatChanged(session: session, revision: revision))
        }
        agents.checkDirectory = { [weak self] directory in
            try self?.services.worktreeGuard?.checkSession(directory: directory)
        }
        resumeCleanup()
        pruneExpiredSessions()
    }

    /// Hands the server its services; call before `run()` or `start()`.
    public func install(_ services: ServerServices) {
        serviceLock.withLock { installedServices = services }
    }

    var services: ServerServices { serviceLock.withLock { installedServices } }
    var simulators: SimulatorService? { services.simulators }

    // MARK: Counters

    func nextAttachment() -> UInt64 {
        connectionLock.withLock {
            counters.attachment += 1
            return counters.attachment
        }
    }

    func nextPosition() -> UInt64 {
        connectionLock.withLock {
            counters.position += 1
            return counters.position
        }
    }

    /// Which sessions run, who owns them and who shows them changes with
    /// the catalog and with attachments.
    var sessionsRevision: UInt64 {
        catalog.revision &+ connectionLock.withLock { counters.attachmentChanges }
    }

    // MARK: Sessions

    func owner(_ session: SessionId) -> SessionOwner? {
        sessionLock.withLock { sessions[session] }
    }

    func liveSessions() -> [SessionInfo] {
        sessionLock.withLock { sessions.values.map(\.info).sorted { $0.id < $1.id } }
    }

    var hasSessions: Bool {
        sessionLock.withLock { !sessions.isEmpty || !starting.isEmpty }
    }

    func createSession(_ request: CreateSession, requester: ClientConnection?) throws -> SessionInfo {
        operations.lock()
        defer { operations.unlock() }
        let directory = request.directory
        do {
            try directory.validateAbsolute()
        } catch {
            throw ServiceError(.badPath, "The session folder must be an absolute path")
        }
        try services.worktreeGuard?.checkSession(directory: directory.rawValue)
        if let info = try catalog.creation(request.operation, project: request.project, directory: directory) {
            if owner(info.id) != nil { requester?.createdSession(info.id) }
            return info
        }
        try Validation.size(request.size)
        _ = try catalog.project(request.project)
        guard directory.isDirectory else { throw ServiceError(.badPath, "\(directory.rawValue) is not a folder") }
        if let pane = request.pane, tabs.pane(pane)?.content != .terminal(session: nil) {
            throw ServiceError(.badRequest, "The pane for this terminal was closed")
        }

        let id = try sessionLock.withLock { () throws -> SessionId in
            guard !stopping else { throw ServiceError(.spawnFailed, "The server is stopping") }
            var id = SessionId()
            while sessions[id] != nil || starting.contains(id) || archive.contains(id) { id = SessionId() }
            starting.insert(id)
            return id
        }
        let info = SessionInfo(project: request.project, id: id, directory: directory)
        do {
            try catalog.reserve(request.operation, info)
        } catch {
            _ = sessionLock.withLock { starting.remove(id) }
            throw error
        }
        let owner: SessionOwner
        do {
            let settings = settings.settings
            let spawn = SessionSpawn.request(
                settings: settings, integration: shellIntegration, directory: directory.rawValue, size: request.size,
                command: request.command, extra: request.environment, server: catalog.serverId, session: id)
            owner = try SessionOwner(info: info, request: spawn, historyBudgetBytes: settings.historyBudgetBytes,
                                     colors: requester?.colorsForNewSession, archive: archive, activity: activity,
                                     detector: services.detector, delegate: self)
            try owner.start()
        } catch {
            _ = sessionLock.withLock { starting.remove(id) }
            catalog.failCreation(request.operation, error)
            throw error
        }
        let stopNow = sessionLock.withLock { () -> Bool in
            starting.remove(id)
            sessions[id] = owner
            return stopping
        }
        if stopNow { owner.end(.serverStopped) }
        try? catalog.setLive(id)
        ServerLog.info("session created: \(id)")
        requester?.createdSession(id)
        if let input = request.input, !input.isEmpty {
            owner.writeInput(Data((input + "\r").utf8)) { error in
                if let error { ServerLog.error("session \(id) didn't take its startup command: \(error)") }
            }
        }
        if let pane = request.pane { show(id, in: pane, proxy: !request.environment.isEmpty) }
        return info
    }

    /// Shows a new terminal in the pane it was created for, or ends it when
    /// that pane closed meanwhile.
    private func show(_ session: SessionId, in pane: PaneId, proxy: Bool) {
        let shown: Bool
        do {
            shown = try tabs.edit { TabReducer.bind(session, to: pane, proxy: proxy, in: &$0) }
        } catch {
            ServerLog.error("session \(session) not shown in its pane: \(error)")
            shown = false
        }
        if !shown { endLater([session]) }
    }

    /// A live session a client may attach to.
    func attachable(_ session: SessionId, requester: ClientConnection) throws -> SessionOwner {
        guard !catalog.isDiscarding(session), !requester.isReleased(session), let owner = owner(session) else {
            throw ServiceError.unknownSession(session)
        }
        return owner
    }

    /// Ends a live session and waits until it finished.
    func endAndWait(_ session: SessionId, reason: ExitReason = .ended) throws {
        guard let owner = owner(session) else { return }
        let done = DispatchSemaphore(value: 0)
        owner.end(reason) { _ in done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else {
            throw ServiceError(.badRequest, "The session did not end in time")
        }
    }

    /// Ends the session if it runs and deletes its saved output.
    func discard(_ session: SessionId) throws {
        operations.lock()
        defer { operations.unlock() }
        try discardOwned(session)
    }

    private func discardOwned(_ session: SessionId) throws {
        try catalog.beginDiscard(session)
        try endAndWait(session)
        try archive.discardNow(session)
        try catalog.finishDiscard(session)
    }

    /// Ends and discards `sessions` on the cleanup queue. They are marked
    /// first, so a crash before they end still discards them on restart.
    func endLater(_ sessions: [SessionId]) {
        for session in sessions {
            do {
                try catalog.beginDiscard(session)
            } catch {
                ServerLog.error("session \(session) not marked for discarding: \(error)")
            }
        }
        cleanup.async { [self] in
            for session in sessions {
                do {
                    try discard(session)
                } catch {
                    ServerLog.error("session \(session) not discarded: \(error)")
                }
            }
        }
    }

    func cancelCreation(_ operation: OperationId) throws {
        operations.lock()
        defer { operations.unlock() }
        if let session = try catalog.cancelCreation(operation) {
            try discardOwned(session)
        }
    }

    /// Closing a pane: ends the session unless another client shows it.
    func closeSession(_ session: SessionId, operation: OperationId, requester: ClientConnection) throws {
        operations.lock()
        defer { operations.unlock() }
        let discard: Bool
        if let recorded = try catalog.closeReceipt(operation, session: session) {
            discard = recorded
        } else {
            let local = requester.shows(session, includeChannels: false)
            if !local { requester.detachSession(session) }
            discard = !local && !isShown(session, except: requester)
            try catalog.recordClose(operation, session: session, discard: discard)
        }
        if discard { try discardOwned(session) }
    }

    private func isShown(_ session: SessionId, except requester: ClientConnection) -> Bool {
        liveConnections().contains { $0 !== requester && $0.shows(session, includeChannels: true) }
    }

    /// Removes saved sessions that ended more than a week before `now`.
    func pruneExpiredSessions(now: UInt64 = Clock.now()) {
        for session in catalog.expiredSessions(now: now) where owner(session) == nil {
            operations.lock()
            defer { operations.unlock() }
            do {
                try archive.discardNow(session)
                try catalog.finishDiscard(session)
            } catch {
                ServerLog.error("session \(session) retention cleanup failed: \(error)")
            }
        }
    }

    /// Finishes discards and project deletions a crash interrupted.
    private func resumeCleanup() {
        do {
            for session in catalog.discarding() { try discardOwned(session) }
            try finishDeletions()
        } catch {
            ServerLog.error("cleanup failed: \(error)")
        }
    }

    private func finishDeletions() throws {
        let deleting = catalog.deleting()
        guard !deleting.isEmpty else { return }
        for project in deleting {
            agents.close(project: project)
            for session in catalog.sessions(of: project) { try discardOwned(session) }
        }
        try catalog.finishDeletions()
        try pruneTabs()
    }

    /// Drops the tabs of projects the catalog no longer has.
    private func pruneTabs() throws {
        try tabs.edit { board in
            let before = board.projects.count
            board.retainProjects { [catalog] in (try? catalog.project($0)) != nil }
            return board.projects.count != before
        }
    }

    // MARK: Tabs

    /// Applies an app's tab change, then ends the terminals and cancels the
    /// creations of the panes it closed.
    func mutateTabs(_ intent: TabIntent) throws -> UInt64 {
        let applying = try checkedSessions(intent.mutation)
        let (revision, effects) = try tabs.mutate(intent, applying: applying) { [catalog] project in
            (try? catalog.project(project)) != nil
        }
        if !effects.endedSessions.isEmpty { endLater(effects.endedSessions) }
        if !effects.cancelledCreations.isEmpty {
            cleanup.async { [self] in
                for operation in effects.cancelledCreations { try? cancelCreation(operation) }
            }
        }
        return revision
    }

    /// The change with its panes' terminals checked: a pane may show only a
    /// running terminal of its own project. Adopted tabs leave out the rest.
    private func checkedSessions(_ mutation: TabMutation) throws -> TabMutation {
        func runs(_ pane: Pane, in project: ProjectId?) -> Bool {
            guard let session = pane.content.session else { return true }
            guard let info = owner(session)?.info, !catalog.isDiscarding(session) else { return false }
            return project == nil || info.project == project
        }
        switch mutation {
        case let .createTab(project, tab, _):
            guard tab.panes.allSatisfy({ runs($0, in: project) }) else { throw ServiceError(.badRequest, "A pane can only show a running terminal of its project") }
        case let .insertPane(pane, anchor, _):
            let project = TabBoard(home: catalog.homeId, projects: tabs.snapshot().projects).locate(pane: anchor)?.project
            guard runs(pane, in: project) else { throw ServiceError(.badRequest, "A pane can only show a running terminal of its project") }
        case .replacePane(_, let pane):
            guard pane.content.session == nil else { throw ServiceError(.badRequest, "A restarted pane starts a new terminal") }
        case let .adoptTabs(project, tabs):
            return .adoptTabs(project: project, tabs: tabs.compactMap { tab in
                var tab = tab
                for pane in tab.panes where !runs(pane, in: project) {
                    tab.layout.remove(pane.id)
                    tab.panes.removeAll { $0.id == pane.id }
                    if tab.zoomed == pane.id { tab.zoomed = nil }
                }
                return tab.panes.isEmpty ? nil : tab
            })
        default:
            break
        }
        return mutation
    }

    // MARK: Catalog

    func mutateProject(_ intent: ProjectIntent) throws -> UInt64 {
        operations.lock()
        defer { operations.unlock() }
        switch intent.mutation {
        case .rename(let project, _), .pruneWorktree(let project):
            try services.worktreeGuard?.checkMutation(of: [project])
        case .delete(let project):
            try services.worktreeGuard?.checkMutation(of: [project] + catalog.children(of: project).map(\.id))
        case .create:
            break
        }
        let revision = try catalog.mutate(intent)
        switch intent.mutation {
        case .delete: try finishDeletions()
        case .pruneWorktree: try pruneTabs()
        case .create, .rename: break
        }
        return max(revision, catalog.revision)
    }

    func projectSessions(_ project: ProjectId, after: SessionId?, revision: UInt64?,
                         requester: ClientConnection) throws -> ProjectSessions {
        let current = sessionsRevision
        if let revision, revision != current {
            throw ServiceError(.catalogChanged, "Sessions changed; read them again from the start")
        }
        var page = try catalog.listProject(project, after: after, revision: nil)
        let connections = liveConnections()
        for index in page.sessions.indices {
            let id = page.sessions[index].info.id
            guard page.sessions[index].status == .live || page.sessions[index].status == .starting else { continue }
            page.sessions[index].owner = connections.compactMap { $0.position(of: id) }.min { $0.0 < $1.0 }?.1
            page.sessions[index].attached = requester.position(of: id) != nil
        }
        guard current == sessionsRevision else {
            throw ServiceError(.catalogChanged, "Sessions changed; read them again from the start")
        }
        page.revision = current
        return page
    }

    /// Records which sessions a client shows. Connections of one app share
    /// `owner`; a sync with an older revision than the latest is ignored.
    func syncReferences(requester: ClientConnection, owner: OperationId?, revision: UInt64, sessions: [SessionId]) {
        operations.lock()
        defer { operations.unlock() }
        let connections = liveConnections()
        var references = requester.lock.withLock { requester.references }
        if let owner {
            let shared: [References] = connections.map { connection in connection.lock.withLock { connection.references } }
            let newest = shared.filter { $0.owner == owner }.max { $0.revision < $1.revision }
            if let newest { references = newest }
        }
        let accepted = owner == nil || references.owner != owner || revision >= references.revision
        if accepted { references.update(owner: owner, revision: revision, sessions: sessions) }
        requester.setReferences(references, reported: sessions, acknowledgeCreation: accepted)
        guard let owner else { return }
        for connection in connections where connection !== requester
            && connection.lock.withLock({ connection.references.owner }) == owner {
            connection.setReferences(references, reported: nil, acknowledgeCreation: false)
        }
    }

    // MARK: Activity

    /// Only the first desktop app connected delivers notifications.
    func claimActivity(_ ids: [UInt64], requester: ClientConnection) -> [UInt64] {
        let first = liveConnections().first { $0.client.kind == .desktop }
        guard first?.client.id == requester.client.id else { return [] }
        return activity.claim(ids)
    }

    // MARK: Stopping

    func requestStop(force: Bool) -> ReplyBody {
        if !force {
            // Terminal creation also holds operations. Check it before reserving
            // agents, so a busy terminal does not leave agent requests refused.
            guard operations.try() else { return .serverBusy }
            defer { operations.unlock() }
            guard !hasSessions, agents.tryRefuseIfIdle() else { return .serverBusy }
            refuseNewSessions()
            scheduleStop()
            return .serverStopping
        }
        refuseNewSessions()
        scheduleStop()
        return .serverStopping
    }

    func requestStopIfIdle() -> ReplyBody {
        guard operations.try() else { return .serverBusy }
        defer { operations.unlock() }
        let idle = sessionLock.withLock { !stopping && sessions.isEmpty && starting.isEmpty }
        guard idle, agents.tryRefuseIfIdle() else { return .serverBusy }
        sessionLock.withLock { stopping = true }
        broadcast(.serverRestarting)
        scheduleStop()
        return .serverStopping
    }

    func requestRestart() -> ReplyBody {
        refuseNewSessions()
        broadcast(.serverRestarting)
        scheduleStop()
        return .serverRestarting
    }

    /// Once a stop is accepted, a session created before the server goes
    /// would only be ended with it, so creation fails instead.
    private func refuseNewSessions() {
        sessionLock.withLock { stopping = true }
        agents.refuseNewRequests()
    }

    /// Stops after the reply had a moment to go out.
    private func scheduleStop() {
        lifecycle.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.stopRequested?() }
    }

    /// Ends every session (their content is saved) and waits for them.
    func endAllSessions(timeout: TimeInterval = 10) {
        agents.shutdown()
        let owners = sessionLock.withLock { () -> [SessionOwner] in
            stopping = true
            return Array(sessions.values)
        }
        let group = DispatchGroup()
        for owner in owners {
            group.enter()
            owner.end(.serverStopped) { _ in group.leave() }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            ServerLog.error("some sessions did not end before the server stopped")
        }
        archive.flush()
    }

    // MARK: Connections

    /// Serves a client on `stream`.
    func serve(_ stream: ByteStream, origin: ConnectionOrigin) {
        let connection = connectionLock.withLock { () -> ClientConnection in
            nextConnection += 1
            let connection = ClientConnection(number: nextConnection, server: self, stream: stream, origin: origin)
            connections[nextConnection] = connection
            return connection
        }
        if case .mobile(let device) = origin {
            ServerLog.info("device connected: \(device)")
        }
        connection.start()
    }

    func connectionClosed(_ connection: ClientConnection) {
        let (others, hadPositions) = connectionLock.withLock { () -> ([ClientConnection], Bool) in
            connections[connection.number] = nil
            counters.attachmentChanges += 1
            return (Array(connections.values), true)
        }
        if hadPositions { sessionsChanged(bump: false) }
        let client = connection.client.id
        if !others.contains(where: { $0.client.id == client }) {
            services.git?.clientDisconnected(client)
            services.files?.clientDisconnected(client)
        }
    }

    func liveConnections() -> [ClientConnection] {
        connectionLock.withLock { connections.values.sorted { $0.number < $1.number } }.filter { !$0.isClosed }
    }

    /// Closes every connection after sending what they have queued.
    func closeConnections(timeout: TimeInterval = 1) {
        let all = connectionLock.withLock { Array(connections.values) }
        for connection in all { connection.finish() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, connectionLock.withLock({ !connections.isEmpty }) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        for connection in connectionLock.withLock({ Array(connections.values) }) { connection.disconnect() }
    }

    // MARK: Change events

    func sessionsChanged(bump: Bool = true) {
        if bump { connectionLock.withLock { counters.attachmentChanges += 1 } }
        let revision = sessionsRevision
        for connection in liveConnections() where connection.watchingCatalog {
            connection.outbox.push(.event(.changed(topic: .sessions, revision: revision)))
        }
    }

    private func catalogChanged(_ revision: UInt64) {
        let sessions = sessionsRevision
        for connection in liveConnections() where connection.watchingCatalog {
            connection.outbox.push(.event(.changed(topic: .catalog, revision: revision)))
            connection.outbox.push(.event(.changed(topic: .sessions, revision: sessions)))
        }
    }

    private func tabsChanged(_ revision: UInt64) {
        for connection in liveConnections() where connection.watchingTabs {
            connection.outbox.push(.event(.changed(topic: .tabs, revision: revision)))
        }
    }

    private func activityChanged(_ revision: UInt64) {
        for connection in liveConnections() where connection.watchingActivity {
            connection.outbox.push(.event(.changed(topic: .activity, revision: revision)))
        }
    }
}

// MARK: - Contracts

extension Server: WorktreeCatalog {
    public func projectPath(_ id: ProjectId) throws -> String {
        try catalog.project(id).directory.rawValue
    }

    /// The folder an agent in `project` works in, which must exist.
    func agentDirectory(_ project: ProjectId) throws -> String {
        let directory = try catalog.project(project).directory
        guard directory.isDirectory else { throw ServiceError(.badPath, "The agent's project folder is unavailable") }
        return directory.rawValue
    }

    public var homeProject: ProjectId { catalog.homeId }

    public func project(_ id: ProjectId) throws -> ProjectDescriptor {
        try catalog.project(id)
    }

    public func children(of parent: ProjectId) -> [ProjectDescriptor] {
        catalog.children(of: parent)
    }

    public func addWorktreeProject(_ project: ProjectDescriptor) throws {
        try catalog.addWorktree(project)
    }

    public func endSessions(project: ProjectId, directory: String) throws {
        agents.close(project: project, directory: directory)
        let root = Catalog.canonical(directory)
        let targets = liveSessions().filter { info in
            let folder = Catalog.canonical(info.directory.rawValue)
            return info.project == project || folder == root || folder.hasPrefix(root + "/")
        }
        for info in targets { try endAndWait(info.id) }
    }

    public func removeWorktreeProject(_ project: ProjectId) throws {
        operations.lock()
        defer { operations.unlock() }
        _ = try catalog.mutate(ProjectIntent(mutation: .delete(project)))
        try finishDeletions()
    }
}

extension Server: ServiceEvents {
    public func broadcast(_ event: EventBody) {
        for connection in liveConnections() where connection.isHandshaken {
            connection.outbox.push(.event(event))
        }
    }

    public func send(_ event: EventBody, to client: ClientId) {
        for connection in liveConnections() where connection.client.id == client {
            connection.outbox.push(.event(event))
        }
    }
}

extension Server: ConnectionAcceptor {
    public func accept(stream: ByteStream, origin: ConnectionOrigin) {
        serve(stream, origin: origin)
    }
}

extension Server: SessionOwnerDelegate {
    func sessionMetadataChanged(_ session: SessionId, _ metadata: SessionMetadata) {
        for connection in liveConnections() { connection.sessionMetadata(session, metadata) }
    }

    func sessionProgressChanged(_ session: SessionId, _ progress: SessionProgress) {
        for connection in liveConnections() { connection.sessionProgress(session, progress) }
    }

    func sessionFinished(_ owner: SessionOwner, reason: ExitReason, saved: Bool) {
        lifecycle.async { [self] in
            let id = owner.info.id
            catalog.recordExit(id, saved: saved)
            sessionLock.withLock { sessions[id] = nil }
            ServerLog.info("session ended: \(id) (\(reason))")
            for connection in liveConnections() { connection.sessionEnded(id, reason: reason) }
            owner.signalFinished()
            // A stopping server's terminals keep their panes until it starts
            // again, which removes them before any app sees them.
            if reason != .serverStopped { removePanes(showing: id) }
        }
    }

    /// The terminal `session` ended: its panes close on every app.
    private func removePanes(showing session: SessionId) {
        do {
            try tabs.edit { TabReducer.removePanes(showing: session, in: &$0) }
        } catch {
            ServerLog.error("panes of session \(session) not removed: \(error)")
        }
    }
}
