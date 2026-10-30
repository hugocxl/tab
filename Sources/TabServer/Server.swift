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

    public init(git: GitServiceProtocol? = nil, worktreeGuard: WorktreeOperationGuard? = nil,
                files: FilesServiceProtocol? = nil, detector: AgentDetector? = nil,
                remote: RemoteAccessProtocol? = nil) {
        self.git = git
        self.worktreeGuard = worktreeGuard
        self.files = files
        self.detector = detector
        self.remote = remote
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
    let archive: ArchiveStore
    let activity = Activity()
    let uploads: Uploads
    let shellIntegration: ShellIntegration?
    let lifecycle = DispatchQueue(label: "tab.server.lifecycle", qos: .utility)

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
        catalog = try Catalog(directory: dirs.sessions, homeDirectory: configuration.homeDirectory,
                              hasSavedScreen: { archive.contains($0) })
        uploads = Uploads(directory: configuration.uploads)
        do {
            shellIntegration = try ShellIntegration.install(into: dirs.root.appendingPathComponent("shell-integration"))
        } catch {
            ServerLog.error("shell integration unavailable: \(error)")
            shellIntegration = nil
        }
        info = ServerInfo(build: BuildInfo(version: Release.version), instance: UInt64.random(in: 1...UInt64.max),
                          server: catalog.serverId)
        catalog.onChange = { [weak self] revision in self?.catalogChanged(revision) }
        activity.onChange = { [weak self] revision in self?.activityChanged(revision) }
        resumeCleanup()
        pruneExpiredSessions()
    }

    /// Hands the server its services; call before `run()` or `start()`.
    public func install(_ services: ServerServices) {
        serviceLock.withLock { installedServices = services }
    }

    var services: ServerServices { serviceLock.withLock { installedServices } }

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
        return info
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
            for session in catalog.sessions(of: project) { try discardOwned(session) }
        }
        try catalog.finishDeletions()
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
        if case .delete = intent.mutation { try finishDeletions() }
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
        if !force, hasSessions { return .serverBusy }
        refuseNewSessions()
        scheduleStop()
        return .serverStopping
    }

    func requestStopIfIdle() -> ReplyBody {
        let idle = sessionLock.withLock { () -> Bool in
            guard !stopping, sessions.isEmpty, starting.isEmpty else { return false }
            stopping = true
            return true
        }
        guard idle else { return .serverBusy }
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
    }

    /// Stops after the reply had a moment to go out.
    private func scheduleStop() {
        lifecycle.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.stopRequested?() }
    }

    /// Ends every session (their content is saved) and waits for them.
    func endAllSessions(timeout: TimeInterval = 10) {
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
        }
    }
}
