import Foundation
import TabProtocol

/// A session the catalog keeps: live, starting, or ended with saved output.
struct SessionRecord: Codable, Equatable {
    var info: SessionInfo
    var status: SessionStatus
    /// Unix seconds; ended sessions are removed a week after.
    var endedAt: UInt64?
}

/// The outcome of a project mutation, so a retry gets the same answer.
struct ProjectReceipt: Codable, Equatable {
    var operation: OperationId
    var mutation: ProjectMutation
    var error: ErrorReply?
    var revision: UInt64
}

/// A session creation, so a retry returns the same session.
struct CreationReceipt: Codable, Equatable {
    var operation: OperationId
    var info: SessionInfo
    var error: ErrorReply?
}

/// A close request, so a retry neither ends nor keeps a session by mistake.
struct CloseReceipt: Codable, Equatable {
    var operation: OperationId
    var session: SessionId
    var discard: Bool
}

/// Everything in `sessions/catalog.json`. Decoding tolerates missing keys.
struct CatalogState: Codable {
    static let receiptLimit = 256

    var version = 1
    var server: ServerId
    var home: ProjectId
    var revision: UInt64 = 0
    var projects: [ProjectId: ProjectDescriptor] = [:]
    var sessions: [SessionId: SessionRecord] = [:]
    /// Projects being deleted: their sessions are discarded first.
    var deleting: Set<ProjectId> = []
    /// Sessions whose saved output is being removed.
    var discarding: Set<SessionId> = []
    var cancelled: [OperationId] = []
    var receipts: [ProjectReceipt] = []
    var creations: [CreationReceipt] = []
    var closes: [CloseReceipt] = []

    init(homeDirectory: String) {
        let home = ProjectDescriptor.home(directory: ServerPath(homeDirectory))
        server = ServerId()
        self.home = home.id
        projects = [home.id: home]
    }

    private enum CodingKeys: String, CodingKey {
        case version, server, home, revision, projects, sessions, deleting, discarding, cancelled, receipts,
             creations, closes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        server = try c.decode(ServerId.self, forKey: .server)
        home = try c.decode(ProjectId.self, forKey: .home)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        let projects = try c.decodeIfPresent([ProjectDescriptor].self, forKey: .projects) ?? []
        self.projects = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessions = try c.decodeIfPresent([SessionRecord].self, forKey: .sessions) ?? []
        self.sessions = Dictionary(sessions.map { ($0.info.id, $0) }, uniquingKeysWith: { first, _ in first })
        deleting = Set(try c.decodeIfPresent([ProjectId].self, forKey: .deleting) ?? [])
        discarding = Set(try c.decodeIfPresent([SessionId].self, forKey: .discarding) ?? [])
        cancelled = try c.decodeIfPresent([OperationId].self, forKey: .cancelled) ?? []
        receipts = try c.decodeIfPresent([ProjectReceipt].self, forKey: .receipts) ?? []
        creations = try c.decodeIfPresent([CreationReceipt].self, forKey: .creations) ?? []
        closes = try c.decodeIfPresent([CloseReceipt].self, forKey: .closes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(server, forKey: .server)
        try c.encode(home, forKey: .home)
        try c.encode(revision, forKey: .revision)
        try c.encode(projects.values.sorted { $0.id < $1.id }, forKey: .projects)
        try c.encode(sessions.values.sorted { $0.info.id < $1.info.id }, forKey: .sessions)
        try c.encode(deleting.sorted(), forKey: .deleting)
        try c.encode(discarding.sorted(), forKey: .discarding)
        try c.encode(cancelled, forKey: .cancelled)
        try c.encode(receipts, forKey: .receipts)
        try c.encode(creations, forKey: .creations)
        try c.encode(closes, forKey: .closes)
    }

    /// Home exists exactly once, every project is valid, worktrees have a
    /// valid parent, and every session belongs to a project.
    func validate() throws {
        guard version == 1, projects.count <= Limits.maxProjects, projects.values.filter(\.home).count == 1,
              projects[home]?.home == true, !deleting.contains(home)
        else { throw ServiceError(.persistenceFailed, "The project catalog is damaged") }
        for project in projects.values {
            do {
                try project.validate()
                try validateParent(project)
            } catch {
                throw ServiceError(.persistenceFailed, "The project catalog has an invalid project \(project.id)")
            }
        }
        for record in sessions.values where projects[record.info.project] == nil {
            throw ServiceError(.persistenceFailed, "Session \(record.info.id) has no project")
        }
    }

    func validateParent(_ project: ProjectDescriptor) throws {
        guard let parentId = project.parentId else { return }
        guard let parent = projects[parentId], !parent.home, parent.parentId == nil, parent.kind == nil else {
            throw ServiceError(.badRequest, "A worktree's parent must be a project that is not Home or a worktree")
        }
    }

    mutating func remember<T>(_ item: T, in list: WritableKeyPath<CatalogState, [T]>) {
        self[keyPath: list].append(item)
        if self[keyPath: list].count > Self.receiptLimit {
            self[keyPath: list].removeFirst(self[keyPath: list].count - Self.receiptLimit)
        }
    }
}
