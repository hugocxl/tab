import Foundation

/// Headless coding agents supported by an Agent Tab.
public enum AgentChatProvider: String, Codable, Hashable, Sendable, CaseIterable {
    case claude, codex

    public var name: String { self == .claude ? "Claude Code" : "Codex" }
}

public enum AgentChatStatus: String, Codable, Hashable, Sendable {
    case idle, working, waiting, failed, closed
}

/// Host-side permission handling. Full access is always an explicit user choice.
public enum AgentAccessMode: String, Codable, Hashable, Sendable, CaseIterable {
    case standard, ask, fullAccess

    public var title: String {
        switch self {
        case .standard: "Auto"
        case .ask: "Ask every time"
        case .fullAccess: "Full access"
        }
    }

    public var tooltip: String {
        switch self {
        case .standard:
            "Automatically allow Read, Glob, Grep, WebSearch and WebFetch permission requests. Other permission requests still ask. Codex uses workspace-write on the next turn; active turns keep their existing sandbox and prompting policy."
        case .ask:
            "Ask for every tool permission request received from the provider. Codex uses a read-only sandbox on the next turn; active turns keep their existing policy. Providers may run tools that do not request permission."
        case .fullAccess:
            "Automatically approve tool permission requests, including commands and file changes. Codex disables its sandbox and native prompts on the next turn. Structured questions are not auto-answered."
        }
    }
}

/// Optional reasoning control; nil lets the installed provider use its defaults.
public enum AgentReasoningEffort: String, Codable, Hashable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max

    public var title: String { self == .xhigh ? "Extra high" : rawValue.capitalized }

    /// T3's Claude model profiles; Codex advertises these four reasoning levels.
    /// Unknown/default Claude models expose only the conservative common levels.
    public static func supported(provider: AgentChatProvider, model: String?) -> [Self] {
        if provider == .codex { return [.low, .medium, .high, .xhigh] }
        let model = (model ?? "").lowercased().replacingOccurrences(of: ".", with: "-")
        if model.contains("haiku-4-5") { return [] }
        if ["opus-5", "opus-4-8", "opus-4-7", "fable-5", "sonnet-5", "haiku-5"].contains(where: { model.contains($0) }) {
            return [.low, .medium, .high, .xhigh, .max]
        }
        if ["opus-4-6", "opus-4-5", "sonnet-4-6"].contains(where: { model.contains($0) }) {
            return [.low, .medium, .high, .max]
        }
        return [.low, .medium, .high]
    }
}

/// A stable transcript row; streaming updates retain its identity.
public struct AgentChatItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case user, assistant, tool, approval, notice
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var detail: String?
    public var isComplete: Bool
    public var tool: AgentToolActivity?

    public init(id: String = UUID().uuidString, kind: Kind, text: String,
                detail: String? = nil, isComplete: Bool = true, tool: AgentToolActivity? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.isComplete = isComplete
        self.tool = tool
    }
}

/// Server-owned conversation state, including its transcript.
public struct AgentChatSnapshot: Codable, Hashable, Sendable {
    public var session: SessionId
    public var project: ProjectId
    public var provider: AgentChatProvider
    public var providerSession: String?
    public var model: String?
    public var reasoningEffort: AgentReasoningEffort?
    public var accessMode: AgentAccessMode?
    public var turns: [AgentChatTurn]?
    public var status: AgentChatStatus
    public var revision: UInt64
    public var items: [AgentChatItem]

    public init(session: SessionId, project: ProjectId, provider: AgentChatProvider,
                providerSession: String? = nil, model: String? = nil,
                reasoningEffort: AgentReasoningEffort? = nil,
                accessMode: AgentAccessMode? = .standard,
                turns: [AgentChatTurn]? = nil,
                status: AgentChatStatus = .idle, revision: UInt64 = 0, items: [AgentChatItem] = []) {
        self.session = session
        self.project = project
        self.provider = provider
        self.providerSession = providerSession
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.accessMode = accessMode ?? .standard
        self.turns = turns
        self.status = status
        self.revision = revision
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case session, project, provider, providerSession, model, reasoningEffort, accessMode, turns, status, revision, items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(SessionId.self, forKey: .session)
        project = try c.decode(ProjectId.self, forKey: .project)
        provider = try c.decode(AgentChatProvider.self, forKey: .provider)
        providerSession = try c.decodeIfPresent(String.self, forKey: .providerSession)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try c.decodeIfPresent(AgentReasoningEffort.self, forKey: .reasoningEffort)
        accessMode = try c.decodeIfPresent(AgentAccessMode.self, forKey: .accessMode) ?? .standard
        turns = try c.decodeIfPresent([AgentChatTurn].self, forKey: .turns)
        status = try c.decode(AgentChatStatus.self, forKey: .status)
        revision = try c.decode(UInt64.self, forKey: .revision)
        items = try c.decode([AgentChatItem].self, forKey: .items)
    }
}

/// Agent requests are separate from terminal sessions and PTY input.
public enum AgentChatRequest: Codable, Hashable, Sendable {
    /// Idempotent: a pane chooses and persists its session ID before connecting.
    /// Provider seeds new conversations only; reconnect returns the server's selected provider.
    case create(session: SessionId, project: ProjectId, provider: AgentChatProvider)
    case read(session: SessionId)
    /// Nil model/effort explicitly restore provider defaults; nil provider keeps the current provider.
    case send(session: SessionId, text: String, model: String?, reasoningEffort: AgentReasoningEffort? = nil,
              provider: AgentChatProvider? = nil)
    case approve(session: SessionId, request: String, allow: Bool)
    /// Updates host approvals immediately; native provider sandbox policy changes on the next turn.
    case setAccess(session: SessionId, mode: AgentAccessMode)
    case interrupt(session: SessionId)
    case close(session: SessionId)
}
