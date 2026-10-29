import Foundation

public enum ProjectKind: OpenEnum {
    /// A Git worktree of its parent project.
    case worktree
    case unknown(String)

    public static let knownCases: [ProjectKind] = [.worktree]

    public var rawValue: String {
        switch self {
        case .worktree: "worktree"
        case .unknown(let value): value
        }
    }
}

/// A project as the server keeps it.
public struct ProjectDescriptor: Hashable, Codable, Sendable {
    public var id: ProjectId
    /// The server's Home: always first, can't be deleted.
    public var home: Bool
    public var directory: ServerPath
    public var name: String
    public var kind: ProjectKind?
    /// The project a worktree belongs to.
    public var parentId: ProjectId?
    /// The project's worktrees are hidden in the sidebar.
    public var worktreesHidden: Bool

    public init(id: ProjectId = ProjectId(), home: Bool = false, directory: ServerPath, name: String,
                kind: ProjectKind? = nil, parentId: ProjectId? = nil, worktreesHidden: Bool = false) {
        self.id = id
        self.home = home
        self.directory = directory
        self.name = name
        self.kind = kind
        self.parentId = parentId
        self.worktreesHidden = worktreesHidden
    }

    /// A new project, named after its folder.
    public static func new(directory: ServerPath) -> ProjectDescriptor {
        ProjectDescriptor(directory: directory, name: directory.lastComponent)
    }

    /// A server's Home, in the user's home folder.
    public static func home(directory: ServerPath) -> ProjectDescriptor {
        ProjectDescriptor(home: true, directory: directory, name: "Home")
    }
}

/// A change to the catalog.
public enum ProjectMutation: Hashable, Codable, Sendable {
    case create(ProjectDescriptor)
    case rename(project: ProjectId, name: String)
    case delete(ProjectId)
    /// Removes a worktree project whose folder was deleted outside Tab.
    case pruneWorktree(ProjectId)
    case setWorktreesVisible(project: ProjectId, visible: Bool)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "create": self = .create(try c("project"))
        case "rename": self = .rename(project: try c("project"), name: try c("name"))
        case "delete": self = .delete(try c("project"))
        case "pruneWorktree": self = .pruneWorktree(try c("project"))
        case "setWorktreesVisible": self = .setWorktreesVisible(project: try c("project"), visible: try c("visible"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .create(let project):
            var c = try TaggedEncoding(encoder, "create")
            try c(project, "project")
        case .rename(let project, let name):
            var c = try TaggedEncoding(encoder, "rename")
            try c(project, "project")
            try c(name, "name")
        case .delete(let project):
            var c = try TaggedEncoding(encoder, "delete")
            try c(project, "project")
        case .pruneWorktree(let project):
            var c = try TaggedEncoding(encoder, "pruneWorktree")
            try c(project, "project")
        case .setWorktreesVisible(let project, let visible):
            var c = try TaggedEncoding(encoder, "setWorktreesVisible")
            try c(project, "project")
            try c(visible, "visible")
        }
    }
}

/// A catalog change with the operation id that makes retrying it safe.
public struct ProjectIntent: Hashable, Codable, Sendable {
    public var operation: OperationId
    public var mutation: ProjectMutation

    public init(operation: OperationId = OperationId(), mutation: ProjectMutation) {
        self.operation = operation
        self.mutation = mutation
    }
}

/// One page of the server's projects, ordered by id.
public struct CatalogPage: Hashable, Codable, Sendable {
    public var server: ServerId
    public var home: ProjectId
    public var revision: UInt64
    public var projects: [ProjectDescriptor]
    /// Pass as `after` to read the next page.
    public var next: ProjectId?

    public init(server: ServerId, home: ProjectId, revision: UInt64, projects: [ProjectDescriptor],
                next: ProjectId? = nil) {
        self.server = server
        self.home = home
        self.revision = revision
        self.projects = projects
        self.next = next
    }
}

public struct ProjectSession: Hashable, Codable, Sendable {
    public var info: SessionInfo
    public var status: SessionStatus
    public var owner: SessionClient?
    /// Some client is attached now.
    public var attached: Bool

    public init(info: SessionInfo, status: SessionStatus, owner: SessionClient? = nil, attached: Bool = false) {
        self.info = info
        self.status = status
        self.owner = owner
        self.attached = attached
    }
}

/// One page of a project's sessions, ordered by id.
public struct ProjectSessions: Hashable, Codable, Sendable {
    public var revision: UInt64
    public var sessions: [ProjectSession]
    public var next: SessionId?

    public init(revision: UInt64, sessions: [ProjectSession], next: SessionId? = nil) {
        self.revision = revision
        self.sessions = sessions
        self.next = next
    }
}

func unknownCase(_ type: String, _ decoder: Decoder) -> DecodingError {
    DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown type \(type)"))
}
