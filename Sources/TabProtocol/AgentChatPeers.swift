import Foundation

/// Another agent conversation on the same server: the coordinator that started
/// a worker, a worker a coordinator started, or the agent that sent a message.
public struct AgentPeer: Codable, Hashable, Sendable {
    public var session: SessionId
    /// The peer's project, which may be a worktree of the conversation's own.
    public var project: ProjectId?
    public var provider: AgentChatProvider
    /// The peer's name or the start of its task, as it read when this was recorded.
    public var name: String

    public init(session: SessionId, project: ProjectId? = nil, provider: AgentChatProvider, name: String) {
        self.session = session
        self.project = project
        self.provider = provider
        self.name = name
    }

    /// The longest name a peer keeps, in UTF-8 bytes.
    public static let maximumNameBytes = 160

    public func validate() throws(ErrorCode) {
        guard !name.isEmpty, name.utf8.count <= Self.maximumNameBytes, !name.contains("\0") else { throw .badRequest }
    }
}

/// Worker reports a coordinator holds until it can take them.
public struct AgentReportQueue: Codable, Hashable, Sendable {
    /// Reports waiting for the coordinator.
    public var held: Int
    /// Delivery stopped after too many agent-driven turns without the user;
    /// the user's next message, or delivering by hand, resumes it.
    public var paused: Bool

    public init(held: Int, paused: Bool = false) {
        self.held = held
        self.paused = paused
    }
}

extension AgentChatTurn {
    /// What became of a turn's report to the agent that asked for it. Unknown
    /// future states round-trip without invalidating retained history.
    public struct Report: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Waiting for the requesting agent to take it.
        public static let held = Self(rawValue: "held")
        public static let delivered = Self(rawValue: "delivered")
        /// The requesting agent read the reply itself, so it wasn't sent again.
        public static let acknowledged = Self(rawValue: "acknowledged")
        /// The requesting agent closed first.
        public static let dropped = Self(rawValue: "dropped")
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
    }
}

/// `workContext.itemType` values of conversation items between agents. Older
/// apps show these items as plain notices and messages.
public enum AgentPeerItemType {
    /// A notice in a coordinator: it started the worker `peer`; `detail` holds the task.
    public static let workerStarted = "worker_started"
    /// A user message in a coordinator: the worker `peer`'s report; `sourceStatus`
    /// holds the outcome and `detail` the changed files, one per line.
    public static let workerReport = "worker_report"
    /// A user message the agent `peer` sent. `requestKind` is `task` for the first
    /// message from the conversation's coordinator.
    public static let agentMessage = "agent_message"
    public static let taskRequest = "task"
}
