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
    case ohMyPi
    case unknown(String)

    public static let knownCases: [AgentProvider] = [
        .claude, .codex, .openCode, .cursor, .copilot, .droid, .pi, .grok, .kiro, .xal, .antigravity, .ohMyPi,
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
    /// A Tab agent's name, such as a worker's `tax-rules`; older servers leave it out.
    public var name: String?

    public init(session: SessionId, project: ProjectId, provider: AgentProvider, state: AgentState, title: String? = nil,
                workingSince: UInt64? = nil, name: String? = nil) {
        self.session = session
        self.project = project
        self.provider = provider
        self.state = state
        self.title = title
        self.workingSince = workingSince
        self.name = name
    }
}

public enum EventKind: OpenEnum {
    /// The agent needs your attention.
    case attention
    /// The agent finished working.
    case completed
    /// A program asked for a desktop notification (OSC 9 or OSC 777);
    /// the event's `title` and `body` hold it.
    case notification
    case unknown(String)

    public static let knownCases: [EventKind] = [.attention, .completed, .notification]

    public var rawValue: String {
        switch self {
        case .attention: "attention"
        case .completed: "completed"
        case .notification: "notification"
        case .unknown(let value): value
        }
    }

    public var displayDescription: String {
        switch self {
        case .attention: "Needs your attention"
        case .completed: "Finished working"
        case .notification: "Sent a notification"
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
