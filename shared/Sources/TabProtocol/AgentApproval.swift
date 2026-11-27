import Foundation

/// One answer a provider offered for a pending request, as the provider offered it.
/// `id` is the server's handle for the provider's own decision value; clients send it
/// back unchanged in `AgentChatRequest.decide`.
public struct AgentApprovalDecision: Codable, Hashable, Sendable, Identifiable {
    /// What choosing the decision does. Unknown future kinds round-trip; a client that
    /// doesn't know one still shows its title and consequence.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
        /// Allows this one request.
        public static let allowOnce = Kind(rawValue: "allowOnce")
        /// Allows this request and matching ones for the rest of the provider session.
        public static let allowForSession = Kind(rawValue: "allowForSession")
        /// Allows the same tool for the rest of the Tab conversation.
        public static let allowAlways = Kind(rawValue: "allowAlways")
        /// Refuses this request; the agent carries on without it.
        public static let decline = Kind(rawValue: "decline")
        /// Refuses this request and stops the response.
        public static let cancel = Kind(rawValue: "cancel")
        /// Sends the answers of a form.
        public static let submit = Kind(rawValue: "submit")

        public var allows: Bool { self == .allowOnce || self == .allowForSession || self == .allowAlways || self == .submit }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// What happens next, in a sentence.
    public var consequence: String?

    public init(id: String, kind: Kind, title: String, consequence: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.consequence = consequence
    }
}

/// Where a pending request came from: the provider's own request ID, the provider
/// thread that asked, and the child agent it belongs to when not the conversation's own.
public struct AgentRequestOrigin: Codable, Hashable, Sendable {
    /// The provider's request ID as text.
    public var providerRequestID: String
    /// The provider sent the ID as a JSON number rather than a string.
    public var numericID: Bool?
    /// The provider thread or session the request arrived on.
    public var threadID: String?
    /// The child agent that asked: Claude's `agent_id`, or a Codex agent's thread.
    public var childAgentID: String?
    /// The conversation's tool row that started that child agent.
    public var childToolUseID: String?
    /// The child agent's description, for the card.
    public var childTitle: String?

    public init(providerRequestID: String, numericID: Bool? = nil, threadID: String? = nil, childAgentID: String? = nil,
                childToolUseID: String? = nil, childTitle: String? = nil) {
        self.providerRequestID = providerRequestID; self.numericID = numericID; self.threadID = threadID
        self.childAgentID = childAgentID; self.childToolUseID = childToolUseID; self.childTitle = childTitle
    }

    /// The request came from an agent the conversation's agent started.
    public var isChild: Bool { childAgentID != nil || childToolUseID != nil }
}

/// What a pending approval asks for and the decisions the provider offered. It stays on
/// the transcript row once answered, with `outcome`, so history shows what was chosen.
/// Absent from servers that predate it; clients then offer Allow and Deny.
public struct AgentApprovalRequest: Codable, Hashable, Sendable {
    public struct Field: Codable, Hashable, Sendable {
        public var label: String
        public var value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    /// How the request was settled.
    public struct Outcome: Codable, Hashable, Sendable {
        public struct Source: RawRepresentable, Codable, Hashable, Sendable {
            public var rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
            /// Someone chose `decision` here.
            public static let user = Source(rawValue: "user")
            /// The conversation's access mode or an earlier "always" answered it.
            public static let automatic = Source(rawValue: "automatic")
            /// The provider settled it, from another client or by cancelling it.
            public static let provider = Source(rawValue: "provider")
            /// It can no longer be answered: its turn or the agent that asked ended.
            public static let expired = Source(rawValue: "expired")
        }
        /// The decision sent, when one was.
        public var decision: String?
        public var kind: AgentApprovalDecision.Kind?
        public var title: String
        public var source: Source

        public init(decision: String? = nil, kind: AgentApprovalDecision.Kind? = nil, title: String, source: Source) {
            self.decision = decision; self.kind = kind; self.title = title; self.source = source
        }
    }

    /// `command`, `file-change`, `permissions`, `elicitation` or `tool`.
    public var kind: String
    /// A sentence saying what the agent asks, such as the provider's reason.
    public var summary: String?
    /// What exactly it asks for: the command, paths, hosts or server, in order.
    public var requested: [Field]
    /// Ordered as the provider offered them.
    public var decisions: [AgentApprovalDecision]
    public var origin: AgentRequestOrigin?
    public var outcome: Outcome?

    public init(kind: String, summary: String? = nil, requested: [Field] = [], decisions: [AgentApprovalDecision],
                origin: AgentRequestOrigin? = nil, outcome: Outcome? = nil) {
        self.kind = kind; self.summary = summary; self.requested = requested; self.decisions = decisions
        self.origin = origin; self.outcome = outcome
    }

    public func decision(_ id: String) -> AgentApprovalDecision? { decisions.first { $0.id == id } }
    public func first(_ kind: AgentApprovalDecision.Kind) -> AgentApprovalDecision? { decisions.first { $0.kind == kind } }

    public var transcriptByteCount: Int {
        256 + kind.utf8.count + (summary?.utf8.count ?? 0)
            + requested.reduce(0) { $0 + 32 + $1.label.utf8.count + $1.value.utf8.count }
            + decisions.reduce(0) { $0 + 64 + $1.id.utf8.count + $1.kind.rawValue.utf8.count + $1.title.utf8.count + ($1.consequence?.utf8.count ?? 0) }
            + (origin.map { 128 + $0.providerRequestID.utf8.count + ($0.threadID?.utf8.count ?? 0) + ($0.childAgentID?.utf8.count ?? 0)
                + ($0.childToolUseID?.utf8.count ?? 0) + ($0.childTitle?.utf8.count ?? 0) } ?? 0)
            + (outcome.map { 64 + ($0.decision?.utf8.count ?? 0) + $0.title.utf8.count } ?? 0)
    }

    public func validate() throws(ErrorCode) {
        guard transcriptByteCount <= 64 * 1024, decisions.count <= 16, requested.count <= 64,
              Set(decisions.map(\.id)).count == decisions.count else { throw .badRequest }
        for decision in decisions {
            try Validation.message(decision.id, limit: 256)
            try Validation.message(decision.title, limit: 256)
        }
    }
}

/// Why a turn stopped at a usage or rate limit, kept on the turn so its reset time and
/// retry survive reconnects and restarts.
public struct AgentRateLimitStop: Codable, Hashable, Sendable {
    /// When the provider said the limit resets, if it did.
    public var resetsAt: Date?
    public var message: String?

    public init(resetsAt: Date? = nil, message: String? = nil) {
        self.resetsAt = resetsAt; self.message = message
    }
}

/// How long the server keeps a closed conversation. Nil `deleteAfterDays` keeps it until
/// someone deletes it, which is what closing a pane does unless the user chose otherwise.
public struct AgentConversationRetention: Codable, Hashable, Sendable {
    public var deleteAfterDays: Int?

    public init(deleteAfterDays: Int? = nil) { self.deleteAfterDays = deleteAfterDays }

    public static let keep = AgentConversationRetention()
    /// The choices clients offer.
    public static let choices: [Int?] = [nil, 7, 30, 90]

    public var title: String {
        guard let days = deleteAfterDays else { return "Keep until deleted" }
        return "Delete \(days) days after closing"
    }

    public func validate() throws(ErrorCode) {
        guard deleteAfterDays.map({ (1...3650).contains($0) }) ?? true else { throw .badRequest }
    }
}

/// A Tab conversation on the server that no pane shows: closed, or archived by Clear.
public struct AgentSavedConversation: Codable, Hashable, Sendable, Identifiable {
    public var session: SessionId
    public var project: ProjectId
    public var provider: AgentChatProvider
    public var title: String
    public var updatedAt: Date?
    public var closedAt: Date?
    /// Clear archived it, rather than a pane closing.
    public var archived: Bool
    public var retention: AgentConversationRetention
    /// When the server deletes it under `retention`.
    public var expiresAt: Date?
    /// Prompts that may have reached the agent wait for review in it.
    public var needsReview: Bool?

    public var id: SessionId { session }

    public init(session: SessionId, project: ProjectId, provider: AgentChatProvider, title: String, updatedAt: Date?,
                closedAt: Date?, archived: Bool, retention: AgentConversationRetention, expiresAt: Date?, needsReview: Bool? = nil) {
        self.session = session; self.project = project; self.provider = provider; self.title = title
        self.updatedAt = updatedAt; self.closedAt = closedAt; self.archived = archived
        self.retention = retention; self.expiresAt = expiresAt; self.needsReview = needsReview
    }
}

/// What a permanent delete removed. Checkpoint snapshots another conversation still
/// uses stay, counted in `sharedCheckpoints`.
public struct AgentConversationDeletion: Codable, Hashable, Sendable {
    public var session: SessionId
    public var removedCheckpoints: Int
    public var sharedCheckpoints: Int

    public init(session: SessionId, removedCheckpoints: Int = 0, sharedCheckpoints: Int = 0) {
        self.session = session; self.removedCheckpoints = removedCheckpoints; self.sharedCheckpoints = sharedCheckpoints
    }
}
