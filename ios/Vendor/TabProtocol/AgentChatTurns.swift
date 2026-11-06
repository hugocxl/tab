import Foundation

/// Server-observed timing and outcome for one accepted user message.
public struct AgentChatTurn: Codable, Hashable, Sendable {
    /// A terminal observation, independent of the conversation's reusable idle state.
    /// Unknown future outcomes round-trip without invalidating retained history.
    public struct Outcome: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let completed = Self(rawValue: "completed")
        public static let interrupted = Self(rawValue: "interrupted")
        public static let failed = Self(rawValue: "failed")
        public static let cancelled = Self(rawValue: "cancelled")
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
    }

    public var userItemID: String
    public var startedAt: Date
    public var completedAt: Date?
    public var status: AgentChatStatus
    public var checkpoint: AgentTurnCheckpoint?
    public var outcome: Outcome?

    public init(userItemID: String, startedAt: Date, completedAt: Date? = nil, status: AgentChatStatus = .working, checkpoint: AgentTurnCheckpoint? = nil, outcome: Outcome? = nil) {
        self.userItemID = userItemID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.checkpoint = checkpoint
        self.outcome = outcome
    }
}

/// Immutable per-turn worktree comparison. Missing counts mean binary, not zero.
public struct AgentTurnCheckpoint: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var path: String
        public var additions: UInt64?
        public var deletions: UInt64?
        public init(path: String, additions: UInt64?, deletions: UInt64?) {
            self.path = path; self.additions = additions; self.deletions = deletions
        }
    }
    public var id: String
    public var files: [File]
    public var totalFiles: Int
    public var additions: UInt64
    public var deletions: UInt64
    public var truncated: Bool

    public init(id: String, files: [File], totalFiles: Int, additions: UInt64, deletions: UInt64, truncated: Bool = false) {
        self.id = id; self.files = files; self.totalFiles = totalFiles
        self.additions = additions; self.deletions = deletions; self.truncated = truncated
    }
}

extension AgentTurnCheckpoint {
    public func validate() throws(ErrorCode) {
        guard UUID(uuidString: id) != nil, files.count <= 64, totalFiles >= files.count,
              files.allSatisfy({ !$0.path.isEmpty && $0.path.utf8.count <= 1024 && !$0.path.contains("\0") }) else {
            throw .badRequest
        }
    }
}
