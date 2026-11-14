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
    /// When the agent began waiting for the user to answer an approval or question.
    public var waitingSince: Date?
    /// Seconds the turn spent waiting for the user before `waitingSince`.
    public var waited: TimeInterval?
    /// What the turn used and why it stopped, when the provider reports it.
    public var usage: AgentTurnUsage?

    public init(userItemID: String, startedAt: Date, completedAt: Date? = nil, status: AgentChatStatus = .working, checkpoint: AgentTurnCheckpoint? = nil, outcome: Outcome? = nil,
                waitingSince: Date? = nil, waited: TimeInterval? = nil) {
        self.userItemID = userItemID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.checkpoint = checkpoint
        self.outcome = outcome
        self.waitingSince = waitingSince
        self.waited = waited
    }

    /// Seconds the agent has worked on the turn by `now`, leaving out time spent
    /// waiting for the user. It stops while the turn waits and once it completes.
    public func workingTime(at now: Date) -> TimeInterval {
        let end = completedAt ?? waitingSince ?? now
        return max(0, end.timeIntervalSince(startedAt) - (waited ?? 0))
    }

    /// Records a status change: waiting starts the pause, anything else ends it.
    public mutating func observe(_ status: AgentChatStatus, at now: Date) {
        self.status = status
        if status == .waiting {
            if waitingSince == nil { waitingSince = now }
        } else if let since = waitingSince {
            waited = (waited ?? 0) + max(0, now.timeIntervalSince(since))
            waitingSince = nil
        }
    }
}

/// A turn's tokens, cost, model and stop reason, as the provider reported them.
public struct AgentTurnUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?
    public var model: String?
    /// The provider's own reason, such as `end_turn` or `max_tokens`.
    public var stopReason: String?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil, model: String? = nil, stopReason: String? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.costUSD = costUSD
        self.model = model; self.stopReason = stopReason
    }

    /// The turn ended because it hit a limit rather than because it was done.
    public var stoppedAtLimit: Bool {
        guard let stopReason else { return false }
        return ["max_tokens", "model_context_window_exceeded", "max_turns", "error_max_turns", "error_max_budget_usd"].contains(stopReason)
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
