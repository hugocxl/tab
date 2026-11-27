import Darwin
import Foundation
import TabCore
import TabProtocol

/// The server's projects and the sessions they own, kept in
/// `sessions/catalog.json`. Every change bumps the revision and is saved
/// before it is visible.
final class Catalog: @unchecked Sendable {
    static let retentionSeconds: UInt64 = 7 * 24 * 60 * 60

    let url: URL?
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var state: CatalogState
    /// Called with the new revision after each committed change.
    var onChange: (@Sendable (UInt64) -> Void)?

    /// Opens the catalog in `directory`, or starts one with a Home in
    /// `homeDirectory`. Sessions that were live become ended (when their
    /// screen was saved) or unavailable.
    init(directory: URL?, homeDirectory: String, hasSavedScreen: (SessionId) -> Bool) throws {
        url = directory?.appendingPathComponent("catalog.json")
        var state: CatalogState
        if let url, let data = try? Data(contentsOf: url) {
            do {
                state = try JSONDecoder().decode(CatalogState.self, from: data)
            } catch {
                throw ServiceError(.persistenceFailed, "\(url.path) is damaged: \(error.localizedDescription)")
            }
            try state.validate()
        } else {
            state = CatalogState(homeDirectory: homeDirectory)
        }
        let now = Clock.now()
        for (id, var record) in state.sessions where record.status != .ended || record.endedAt == nil {
            record.status = hasSavedScreen(id) ? .ended : .unavailable
            record.endedAt = record.endedAt ?? now
            state.sessions[id] = record
        }
        self.state = state
        try update { _ in }
    }

    var serverId: ServerId { lock.withLock { state.server } }
    var homeId: ProjectId { lock.withLock { state.home } }
    var revision: UInt64 { lock.withLock { state.revision } }

    /// Applies `edit` to a copy, saves it, then makes it current.
    @discardableResult
    func update<T>(_ edit: (inout CatalogState) throws -> T) throws -> T {
        let (result, revision): (T, UInt64) = try writeLock.withLock {
            var next = lock.withLock { state }
            let result = try edit(&next)
            next.revision += 1
            try next.validate()
            if let url {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    try AtomicFile.write(try encoder.encode(next), to: url)
                } catch {
                    throw ServiceError(.persistenceFailed, "Could not save the project catalog: \(error.localizedDescription)")
                }
            }
            lock.withLock { state = next }
            return (result, next.revision)
        }
        onChange?(revision)
        return result
    }

    private func read<T>(_ body: (CatalogState) throws -> T) rethrows -> T {
        try lock.withLock { try body(state) }
    }

    // MARK: Projects

    func page(after: ProjectId?, revision: UInt64?) throws -> CatalogPage {
        try read { state in
            try Self.check(revision, state)
            let visible = state.projects.values
                .filter { project in !state.deleting.contains(project.id) && (after.map { project.id > $0 } ?? true) }
                .sorted { $0.id < $1.id }
            let projects = Array(visible.prefix(Limits.catalogPageSize))
            return CatalogPage(server: state.server, home: state.home, revision: state.revision, projects: projects,
                               next: visible.count > projects.count ? projects.last?.id : nil)
        }
    }

    func project(_ id: ProjectId) throws -> ProjectDescriptor {
        try read { state in
            guard !state.deleting.contains(id), let project = state.projects[id] else {
                throw ServiceError.unknownProject(id)
            }
            return project
        }
    }

    func projects() -> [ProjectDescriptor] {
        read { state in state.projects.values.filter { !state.deleting.contains($0.id) }.sorted { $0.id < $1.id } }
    }

    /// The project shown for `directory`, comparing resolved paths.
    func project(at directory: String) -> ProjectDescriptor? {
        let target = Self.canonical(directory)
        return projects().first { Self.canonical($0.directory.rawValue) == target }
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Applies a project mutation once per operation. Returns the revision;
    /// a delete leaves the projects in `deleting` for the caller to clean up.
    func mutate(_ intent: ProjectIntent) throws -> UInt64 {
        if let receipt = read({ $0.receipts.first { $0.operation == intent.operation } }) {
            guard receipt.mutation == intent.mutation else {
                throw ServiceError(.badRequest, "The operation was already used for another change")
            }
            if let error = receipt.error { throw ServiceError(error.code, error.message) }
            return receipt.revision
        }
        do {
            try intent.mutation.validate()
        } catch {
            throw ServiceError(.badRequest, "The project change is not valid")
        }
        return try update { state in
            var failure: ErrorReply?
            do {
                try Self.apply(intent.mutation, to: &state)
            } catch {
                failure = errorReply(error)
            }
            state.remember(ProjectReceipt(operation: intent.operation, mutation: intent.mutation, error: failure,
                                          revision: state.revision + 1), in: \.receipts)
            if let failure { throw ServiceError(failure.code, failure.message) }
            return state.revision + 1
        }
    }

    private static func apply(_ mutation: ProjectMutation, to state: inout CatalogState) throws {
        switch mutation {
        case .create(let project):
            guard state.projects[project.id] == nil, state.projects.count < Limits.maxProjects else {
                throw ServiceError(.badRequest, "The project already exists or the catalog is full")
            }
            guard project.directory.isAbsolute, project.directory.isDirectory else {
                throw ServiceError(.badPath, "\(project.directory.rawValue) is not a folder")
            }
            try state.validateParent(project)
            if let parent = project.parentId, state.deleting.contains(parent) { throw ServiceError.unknownProject(parent) }
            state.projects[project.id] = project
        case .rename(let id, let name):
            guard !state.deleting.contains(id), state.projects[id] != nil else { throw ServiceError.unknownProject(id) }
            state.projects[id]?.name = name
        case .delete(let id):
            guard id != state.home else { throw ServiceError(.badRequest, "Home can't be removed") }
            guard state.projects[id] != nil else { throw ServiceError.unknownProject(id) }
            state.deleting.insert(id)
            for child in state.projects.values where child.parentId == id {
                state.deleting.insert(child.id)
            }
        case .pruneWorktree(let id):
            if canPrune(id, state) { state.projects[id] = nil }
        }
    }

    /// A worktree whose folder is gone while its parent's remains, and that
    /// has no sessions or saved output.
    private static func canPrune(_ id: ProjectId, _ state: CatalogState) -> Bool {
        guard let project = state.projects[id], project.kind == .worktree, !state.deleting.contains(id),
              let parent = project.parentId.flatMap({ state.projects[$0] }), parent.directory.isDirectory
        else { return false }
        var info = stat()
        guard stat(project.directory.rawValue, &info) != 0, errno == ENOENT || errno == ENOTDIR else { return false }
        return !state.sessions.values.contains { $0.info.project == id }
    }

    func deleting() -> [ProjectId] {
        read { $0.deleting.sorted() }
    }

    /// Removes the projects being deleted, once they own no sessions.
    func finishDeletions() throws {
        try update { state in
            for id in state.deleting {
                guard !state.sessions.values.contains(where: { $0.info.project == id }) else {
                    throw ServiceError(.persistenceFailed, "A removed project still has sessions")
                }
                state.projects[id] = nil
            }
            state.deleting = []
        }
    }

    /// Adds a worktree project a worktree action made or registered.
    func addWorktree(_ project: ProjectDescriptor) throws {
        do {
            try project.validate()
        } catch {
            throw ServiceError(.badRequest, "The worktree project is not valid")
        }
        guard project.kind == .worktree, project.parentId != nil, !project.home else {
            throw ServiceError(.badRequest, "A worktree project needs a parent")
        }
        try update { state in
            guard state.projects[project.id] == nil else { throw ServiceError(.badRequest, "The project already exists") }
            guard state.projects.count < Limits.maxProjects else {
                throw ServiceError(.badRequest, "The project catalog is full")
            }
            if let parent = project.parentId, state.deleting.contains(parent) { throw ServiceError.unknownProject(parent) }
            try state.validateParent(project)
            state.projects[project.id] = project
        }
    }

    func children(of parent: ProjectId) -> [ProjectDescriptor] {
        projects().filter { $0.parentId == parent }
    }

    /// Worktree projects of `parent` whose folder is gone and that have no
    /// sessions or saved output.
    func prunableWorktrees(of parent: ProjectId) -> [ProjectId] {
        read { state in
            state.projects.values.filter { $0.parentId == parent && Self.canPrune($0.id, state) }.map(\.id)
        }
    }

    func prune(_ ids: [ProjectId]) throws {
        guard !ids.isEmpty else { return }
        try update { state in
            for id in ids where Self.canPrune(id, state) { state.projects[id] = nil }
        }
    }

    // MARK: Sessions

    func sessions(of project: ProjectId) -> [SessionId] {
        read { state in state.sessions.values.filter { $0.info.project == project }.map(\.info.id).sorted() }
    }

    func record(_ session: SessionId) -> SessionRecord? {
        read { state in state.discarding.contains(session) ? nil : state.sessions[session] }
    }

    /// The session an earlier `createSession` with `operation` made, if any.
    func creation(_ operation: OperationId, project: ProjectId, directory: ServerPath) throws -> SessionInfo? {
        try read { state in
            if state.cancelled.contains(operation) {
                throw ServiceError(.badRequest, "The session creation was cancelled")
            }
            guard let receipt = state.creations.first(where: { $0.operation == operation }) else { return nil }
            guard receipt.info.project == project, receipt.info.directory == directory else {
                throw ServiceError(.badRequest, "The operation was already used for another session")
            }
            if let error = receipt.error { throw ServiceError(error.code, error.message) }
            return receipt.info
        }
    }

    func reserve(_ operation: OperationId, _ info: SessionInfo) throws {
        try update { state in
            guard state.projects[info.project] != nil, !state.deleting.contains(info.project) else {
                throw ServiceError.unknownProject(info.project)
            }
            guard state.sessions[info.id] == nil else { throw ServiceError(.badRequest, "The session already exists") }
            state.sessions[info.id] = SessionRecord(info: info, status: .starting)
            state.remember(CreationReceipt(operation: operation, info: info), in: \.creations)
        }
    }

    func failCreation(_ operation: OperationId, _ error: Error) {
        _ = try? update { state in
            guard let index = state.creations.firstIndex(where: { $0.operation == operation }) else { return }
            state.creations[index].error = errorReply(error)
            state.sessions[state.creations[index].info.id] = nil
        }
    }

    func setLive(_ session: SessionId) throws {
        try update { state in
            guard state.sessions[session]?.status == .starting else { return }
            state.sessions[session]?.status = .live
        }
    }

    /// A session's program ended; its output is kept when it was saved.
    func recordExit(_ session: SessionId, saved: Bool) {
        do {
            try update { state in
                guard state.sessions[session] != nil else { return }
                state.sessions[session]?.status = saved ? .ended : .unavailable
                state.sessions[session]?.endedAt = Clock.now()
            }
        } catch {
            ServerLog.error("session \(session) exit not recorded: \(error)")
        }
    }

    /// Marks an operation cancelled; returns the session it already created.
    func cancelCreation(_ operation: OperationId) throws -> SessionId? {
        try update { state in
            if !state.cancelled.contains(operation) { state.remember(operation, in: \.cancelled) }
            return state.creations.first { $0.operation == operation && $0.error == nil }?.info.id
        }
    }

    func closeReceipt(_ operation: OperationId, session: SessionId) throws -> Bool? {
        try read { state in
            guard let receipt = state.closes.first(where: { $0.operation == operation }) else { return nil }
            guard receipt.session == session else {
                throw ServiceError(.badRequest, "The operation was already used for another session")
            }
            return receipt.discard
        }
    }

    func recordClose(_ operation: OperationId, session: SessionId, discard: Bool) throws {
        try update { state in
            state.remember(CloseReceipt(operation: operation, session: session, discard: discard), in: \.closes)
            if discard { state.discarding.insert(session) }
        }
    }

    func beginDiscard(_ session: SessionId) throws {
        try update { state in state.discarding.insert(session) }
    }

    func finishDiscard(_ session: SessionId) throws {
        try update { state in
            state.sessions[session] = nil
            state.discarding.remove(session)
        }
    }

    func discarding() -> [SessionId] {
        read { $0.discarding.sorted() }
    }

    func isDiscarding(_ session: SessionId) -> Bool {
        read { $0.discarding.contains(session) }
    }

    /// Ended sessions older than the retention period at `now`.
    func expiredSessions(now: UInt64) -> [SessionId] {
        read { state in
            state.sessions.values.filter { record in
                (record.status == .ended || record.status == .unavailable)
                    && record.endedAt.map { now >= $0 && now - $0 >= Self.retentionSeconds } == true
            }.map(\.info.id)
        }
    }

    func listProject(_ project: ProjectId, after: SessionId?, revision: UInt64?) throws -> ProjectSessions {
        try read { state in
            try Self.check(revision, state)
            guard state.projects[project] != nil, !state.deleting.contains(project) else {
                throw ServiceError.unknownProject(project)
            }
            let records = state.sessions.values
                .filter { record in record.info.project == project && !state.discarding.contains(record.info.id)
                    && (after.map { record.info.id > $0 } ?? true) }
                .sorted { $0.info.id < $1.info.id }
            let page = records.prefix(Limits.catalogPageSize).map { ProjectSession(info: $0.info, status: $0.status) }
            return ProjectSessions(revision: state.revision, sessions: Array(page),
                                   next: records.count > page.count ? page.last?.info.id : nil)
        }
    }

    private static func check(_ revision: UInt64?, _ state: CatalogState) throws {
        if let revision, revision != state.revision {
            throw ServiceError(.catalogChanged, "The catalog changed; read it again from the start")
        }
    }
}
