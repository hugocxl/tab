import Foundation

/// An AI coding agent the server recognizes in a terminal.
public enum AgentProvider: OpenEnum {
    case claude
    case codex
    case openCode
    case cursor
    case copilot
    case droid
    case pi
    case grok
    case kiro
    case xal
    case antigravity
    case gemini
    case ohMyPi
    case unknown(String)

    public static let knownCases: [AgentProvider] = [
        .claude, .codex, .openCode, .cursor, .copilot, .droid, .pi, .grok, .kiro, .xal, .antigravity, .gemini, .ohMyPi,
    ]

    /// Stable: stored in detection manifests and sent on the wire.
    public var rawValue: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .openCode: "opencode"
        case .cursor: "cursor"
        case .copilot: "copilot"
        case .droid: "droid"
        case .pi: "pi"
        case .grok: "grok"
        case .kiro: "kiro"
        case .xal: "xal"
        case .antigravity: "antigravity"
        case .gemini: "gemini"
        case .ohMyPi: "omp"
        case .unknown(let value): value
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        case .droid: "Droid"
        case .pi: "Pi"
        case .grok: "Grok"
        case .kiro: "Kiro"
        case .xal: "Xal"
        case .antigravity: "Antigravity"
        case .gemini: "Gemini CLI"
        case .ohMyPi: "Oh My Pi"
        case .unknown: "Agent"
        }
    }
}

/// What an agent is doing. States from newer builds read as `unknown`.
public enum AgentState: String, Hashable, Codable, Sendable, CaseIterable {
    case unknown
    case idle
    case working
    /// Waiting for you.
    case blocked

    public init(from decoder: Decoder) throws {
        self = AgentState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// What qualifies an agent's state, when the state alone doesn't say it.
/// Conditions from newer builds are kept as they are, and clients that don't
/// know one show the state alone.
public struct AgentCondition: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Blocked because its turn failed, rather than waiting for an answer.
    public static let failed = AgentCondition(rawValue: "failed")
    /// Held up: a usage limit stops it until it resets, or its queued
    /// messages wait for you to resume them.
    public static let paused = AgentCondition(rawValue: "paused")
    /// Idle, with shells it started still running in the background.
    public static let background = AgentCondition(rawValue: "background")
}

/// An agent running in a session now.
public struct AgentActivity: Hashable, Codable, Sendable {
    public var session: SessionId
    public var project: ProjectId
    public var provider: AgentProvider
    public var title: String?
    public var state: AgentState
    /// Unix milliseconds when the agent started its current turn: set when it
    /// starts working and kept while it works or waits for you. Older servers
    /// leave it out.
    public var workingSince: UInt64?
    /// Older servers leave it out.
    public var condition: AgentCondition?
    /// The agents and shells it started that still run, oldest first. Older
    /// servers and terminal agents leave it out.
    public var subtasks: [AgentSubtask]?

    public init(session: SessionId, project: ProjectId, provider: AgentProvider, state: AgentState, title: String? = nil,
                workingSince: UInt64? = nil, condition: AgentCondition? = nil, subtasks: [AgentSubtask]? = nil) {
        self.session = session
        self.project = project
        self.provider = provider
        self.state = state
        self.title = title
        self.workingSince = workingSince
        self.condition = condition
        self.subtasks = subtasks
    }
}

/// An agent or shell an agent started that still runs, as the sidebar lists it.
public struct AgentSubtask: Hashable, Codable, Sendable, Identifiable {
    /// The provider's task ID.
    public var id: String
    public var title: String
    /// Whether it is a shell, such as a build or a server, rather than an agent.
    public var shell: Bool
    /// Unix milliseconds when it started, when the provider says.
    public var startedAt: UInt64?

    public init(id: String, title: String, shell: Bool = false, startedAt: UInt64? = nil) {
        self.id = id
        self.title = title
        self.shell = shell
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey { case id, title, shell, startedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        shell = try c.decodeIfPresent(Bool.self, forKey: .shell) ?? false
        startedAt = try c.decodeIfPresent(UInt64.self, forKey: .startedAt)
    }

    /// How many a chat's activity lists; the sidebar shows fewer.
    public static let maxCount = 8
}

public enum EventKind: OpenEnum {
    /// The agent needs your attention.
    case attention
    /// The agent finished working.
    case completed
    /// A program asked for a desktop notification (OSC 9 or OSC 777);
    /// the event's `title` and `body` hold it.
    case notification
    /// The agent's turn failed.
    case failed
    case unknown(String)

    public static let knownCases: [EventKind] = [.attention, .completed, .notification, .failed]

    public var rawValue: String {
        switch self {
        case .attention: "attention"
        case .completed: "completed"
        case .notification: "notification"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }

    public var displayDescription: String {
        switch self {
        case .attention: "Needs your attention"
        case .completed: "Finished working"
        case .notification: "Sent a notification"
        case .failed: "Stopped with an error"
        case .unknown: "Has an update"
        }
    }
}

/// Something an agent did that may deserve a notification. At most one
/// unread event per session.
public struct AgentEvent: Hashable, Codable, Sendable {
    public var id: UInt64
    public var session: SessionId
    public var project: ProjectId
    public var provider: AgentProvider
    /// Unix milliseconds.
    public var timestamp: UInt64
    public var kind: EventKind
    public var read: Bool
    /// A notification's title and text, as the program sent them.
    public var title: String?
    public var body: String?

    public init(id: UInt64, session: SessionId, project: ProjectId, provider: AgentProvider, timestamp: UInt64,
                kind: EventKind, read: Bool = false, title: String? = nil, body: String? = nil) {
        self.id = id
        self.session = session
        self.project = project
        self.provider = provider
        self.timestamp = timestamp
        self.kind = kind
        self.read = read
        self.title = title
        self.body = body
    }
}

/// What an agent's hook reports about the agent in a session: its state, or
/// `nil` once its session ended.
public struct AgentStateReport: Hashable, Codable, Sendable {
    public var session: SessionId
    public var provider: AgentProvider
    public var state: AgentState?

    public init(session: SessionId, provider: AgentProvider, state: AgentState?) {
        self.session = session
        self.provider = provider
        self.state = state
    }
}

public struct ActivitySnapshot: Hashable, Codable, Sendable {
    public var revision: UInt64
    public var agents: [AgentActivity]
    public var events: [AgentEvent]

    public init(revision: UInt64 = 0, agents: [AgentActivity] = [], events: [AgentEvent] = []) {
        self.revision = revision
        self.agents = agents
        self.events = events
    }
}
