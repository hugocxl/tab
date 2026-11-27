import Foundation

/// Headless coding agents an agent pane runs. Builds that predate a kind can't read
/// conversations or panes of it; see `AgentProvidersState.kinds`.
public enum AgentChatProvider: String, Codable, Hashable, Sendable, CaseIterable {
    case claude, codex
    /// Google's Antigravity CLI, `agy`: Google's coding agent for personal and Google AI accounts.
    case antigravity
    /// Google's Gemini CLI, now for Gemini Code Assist Standard and Enterprise licenses and
    /// paid API or Vertex keys; personal accounts moved to Antigravity on June 18, 2026.
    case gemini
    case openCode = "opencode"
    /// xAI's Grok CLI.
    case grok
    /// Amazon's Kiro CLI.
    case kiro
    /// Any other agent that speaks the Agent Client Protocol, set up by hand.
    case acp

    /// The kinds every server knows, including those that predate the others.
    public static let original: [AgentChatProvider] = [.claude, .codex]

    public var name: String { spec.name }
}

public enum AgentChatStatus: String, Codable, Hashable, Sendable {
    case idle, working, waiting, failed, closed
}

/// Host-side permission handling, retained for compatibility with existing conversations.
public enum AgentAccessMode: String, Codable, Hashable, Sendable, CaseIterable {
    case standard, ask, fullAccess

    public var title: String {
        switch self {
        case .standard: "Auto"
        case .ask: "Ask every time"
        case .fullAccess: "Full access"
        }
    }

    /// How much a conversation may do without asking: Ask, then Auto, then Full access.
    public var rank: Int {
        switch self {
        case .ask: 0
        case .standard: 1
        case .fullAccess: 2
        }
    }

    /// Whether this lets a conversation do more without asking than `other` does.
    public func exceeds(_ other: AgentAccessMode) -> Bool { rank > other.rank }

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
public struct AgentReasoningEffort: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let low = Self(rawValue: "low")
    public static let medium = Self(rawValue: "medium")
    public static let high = Self(rawValue: "high")
    public static let xhigh = Self(rawValue: "xhigh")
    public static let max = Self(rawValue: "max")
    public static let ultra = Self(rawValue: "ultra")

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func validate() throws(ErrorCode) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 64,
              rawValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw .badRequest
        }
    }

    public var title: String { self == .xhigh ? "Extra high" : rawValue.capitalized }

    /// Installed provider capabilities are authoritative; only wire safety is checked here.
    public func isAccepted(provider: AgentChatProvider, model: String?) -> Bool {
        (try? validate()) != nil
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
    public var questionnaire: AgentQuestionnaire?
    public var tool: AgentToolActivity?
    public var attachments: [AgentChatAttachmentDescriptor]?
    /// First/last server observation. Absent on older persisted transcripts.
    public var createdAt: Date?
    public var updatedAt: Date?
    public var workContext: AgentChatWorkContext?
    /// An approval's request and the decisions offered; see `AgentApprovalRequest`.
    public var approval: AgentApprovalRequest?

    public init(id: String = UUID().uuidString, kind: Kind, text: String,
                detail: String? = nil, isComplete: Bool = true, tool: AgentToolActivity? = nil,
                attachments: [AgentChatAttachmentDescriptor]? = nil, createdAt: Date? = nil,
                updatedAt: Date? = nil, workContext: AgentChatWorkContext? = nil, questionnaire: AgentQuestionnaire? = nil,
                approval: AgentApprovalRequest? = nil) {
        self.questionnaire = questionnaire
        self.approval = approval
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.isComplete = isComplete
        self.tool = tool
        self.attachments = attachments
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.workContext = workContext
    }
}

extension AgentChatItem {
    /// `workContext.itemType` of the user-kind row that opens a turn the provider began
    /// itself, such as Claude answering a background agent that finished. Its text says
    /// why; nobody typed it. Builds that predate it show it as a user message.
    public static let providerTurnType = "provider_turn"

    public var isProviderTurn: Bool { kind == .user && workContext?.itemType == Self.providerTurnType }

    /// `workContext.itemType` of the user-kind row that opens a turn on a report from an
    /// agent this conversation started: it finished, failed, or waits for the user. The
    /// server wrote it; nobody typed it. Builds that predate it show it as a user message.
    public static let agentReportType = "agent_report"

    public var isAgentReport: Bool { kind == .user && workContext?.itemType == Self.agentReportType }

    /// `workContext.itemType` of the user-kind row that opens the turn carrying on work the
    /// server stopping cut short. The server wrote it; nobody typed it. Builds that predate
    /// it show it as a user message.
    public static let restartResumeType = "restart_resume"

    public var isRestartResume: Bool { kind == .user && workContext?.itemType == Self.restartResumeType }

    /// A user-kind row that opens a turn nobody typed: one the provider began, a report
    /// from an agent this conversation started, or work carried on after a server restart.
    /// It is shown as a note, not as the user's.
    public var isAutomaticTurn: Bool { isProviderTurn || isAgentReport || isRestartResume }
}

/// What a new conversation starts with instead of its provider's defaults. A conversation
/// another agent starts never gets more access than that agent has.
public struct AgentStartOptions: Codable, Hashable, Sendable {
    public var model: String?
    public var reasoningEffort: AgentReasoningEffort?
    /// Nil gives the conversation the access of the agent that starts it, or Full access
    /// when the user starts it.
    public var accessMode: AgentAccessMode?

    public init(model: String? = nil, reasoningEffort: AgentReasoningEffort? = nil, accessMode: AgentAccessMode? = nil) {
        self.model = model; self.reasoningEffort = reasoningEffort; self.accessMode = accessMode
    }

    public func validate() throws(ErrorCode) {
        if let model { try Validation.message(model, limit: 256) }
        try reasoningEffort?.validate()
    }
}

/// Something holding up the provider that the transcript doesn't show, such as a retry
/// after an error or a rate limit. Clients that don't know a kind ignore it.
public struct AgentChatActivity: Codable, Hashable, Sendable {
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
        /// The provider hit an error and tries again by itself.
        public static let retrying = Kind(rawValue: "retrying")
        /// The account's usage limit stops the provider until `resumesAt`.
        public static let rateLimited = Kind(rawValue: "rateLimited")
        /// Close to the usage limit; work continues.
        public static let rateLimitWarning = Kind(rawValue: "rateLimitWarning")
    }

    public var kind: Kind
    public var attempt: Int?
    public var resumesAt: Date?
    /// What the provider said, one line.
    public var message: String?

    public init(kind: Kind, attempt: Int? = nil, resumesAt: Date? = nil, message: String? = nil) {
        self.kind = kind; self.attempt = attempt; self.resumesAt = resumesAt; self.message = message
    }
}

/// Server-owned conversation state, including its transcript.
public struct AgentChatSnapshot: Codable, Hashable, Sendable {
    public var session: SessionId
    public var project: ProjectId
    public var provider: AgentChatProvider
    /// The server's `AgentProviderConfig` the conversation runs, when not `provider`'s built-in one.
    public var providerID: String?
    public var providerSession: String?
    public var model: String?
    /// Actual provider model, independent of the user's optional model override.
    public var commands: [String]?
    public var commandDescriptors: [AgentCommandDescriptor]?
    /// Last successful in-place reset, also used to fence client caches.
    public var resetID: SessionId?
    public var resolvedModel: String?
    public var contextUsage: AgentContextUsage?
    /// Agents the provider's agent started that are still running, oldest first.
    public var subagents: [AgentSubagent]?
    public var reasoningEffort: AgentReasoningEffort?
    public var queuedPrompts: [AgentQueuedPrompt]?
    public var queuePaused: Bool?
    public var planMode: Bool?
    public var accessMode: AgentAccessMode?
    public var turns: [AgentChatTurn]?
    public var status: AgentChatStatus
    public var revision: UInt64
    public var items: [AgentChatItem]
    /// Items the server removed from the start of the transcript to keep it within its
    /// bounds, over the conversation's life. Absent from servers that predate it.
    public var omittedItems: Int?
    /// What holds the provider up now, if anything the transcript doesn't show.
    public var activity: AgentChatActivity?
    /// The agent conversation that started this one, as the server saw the caller; nil
    /// when the user started it. Stopping the parent with `stop` stops this one too, and
    /// this one reports back to it. Absent from servers without `Feature.agentLineage`.
    public var parent: SessionId?

    public init(session: SessionId, project: ProjectId, provider: AgentChatProvider,
                providerSession: String? = nil, model: String? = nil,
                reasoningEffort: AgentReasoningEffort? = nil,
                accessMode: AgentAccessMode? = .standard,
                contextUsage: AgentContextUsage? = nil,
                resolvedModel: String? = nil,
                turns: [AgentChatTurn]? = nil,
                status: AgentChatStatus = .idle, revision: UInt64 = 0, items: [AgentChatItem] = []) {
        self.session = session
        self.project = project
        self.provider = provider
        self.providerSession = providerSession
        self.model = model
        self.resolvedModel = resolvedModel
        self.contextUsage = contextUsage
        self.reasoningEffort = reasoningEffort
        self.accessMode = accessMode ?? .standard
        self.turns = turns
        self.status = status
        self.revision = revision
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case commandDescriptors, resetID, session, project, provider, providerID, providerSession, model, commands, resolvedModel, contextUsage, subagents, reasoningEffort, accessMode, planMode, queuedPrompts, queuePaused, turns, status, revision, items, omittedItems, activity, parent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queuedPrompts = try c.decodeIfPresent([AgentQueuedPrompt].self, forKey: .queuedPrompts)
        queuePaused = try c.decodeIfPresent(Bool.self, forKey: .queuePaused)
        planMode = try c.decodeIfPresent(Bool.self, forKey: .planMode)
        session = try c.decode(SessionId.self, forKey: .session)
        project = try c.decode(ProjectId.self, forKey: .project)
        provider = try c.decode(AgentChatProvider.self, forKey: .provider)
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        providerSession = try c.decodeIfPresent(String.self, forKey: .providerSession)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        commands = try c.decodeIfPresent([String].self, forKey: .commands)
        commandDescriptors = try c.decodeIfPresent([AgentCommandDescriptor].self, forKey: .commandDescriptors)
        resetID = try c.decodeIfPresent(SessionId.self, forKey: .resetID)
        resolvedModel = try c.decodeIfPresent(String.self, forKey: .resolvedModel)
        contextUsage = try c.decodeIfPresent(AgentContextUsage.self, forKey: .contextUsage)
        subagents = try c.decodeIfPresent([AgentSubagent].self, forKey: .subagents)
        reasoningEffort = try c.decodeIfPresent(AgentReasoningEffort.self, forKey: .reasoningEffort)
        accessMode = try c.decodeIfPresent(AgentAccessMode.self, forKey: .accessMode) ?? .standard
        turns = try c.decodeIfPresent([AgentChatTurn].self, forKey: .turns)
        status = try c.decode(AgentChatStatus.self, forKey: .status)
        revision = try c.decode(UInt64.self, forKey: .revision)
        items = try c.decode([AgentChatItem].self, forKey: .items)
        omittedItems = try c.decodeIfPresent(Int.self, forKey: .omittedItems)
        activity = try? c.decodeIfPresent(AgentChatActivity.self, forKey: .activity)
        parent = try c.decodeIfPresent(SessionId.self, forKey: .parent)
    }
}

/// Agent requests are separate from terminal sessions and PTY input.
public enum AgentChatRequest: Codable, Hashable, Sendable {
    /// Idempotent: a pane chooses and persists its session ID before connecting.
    /// Provider and `options` seed new conversations only; reconnect returns the server's
    /// selected provider. A server without `Feature.agentLineage` ignores `options`.
    case create(session: SessionId, project: ProjectId, provider: AgentChatProvider, options: AgentStartOptions? = nil)
    case read(session: SessionId)
    /// Archives the previous conversation and resets this pane in place, while idle.
    case clear(session: SessionId, archive: SessionId, expectedRevision: UInt64)
    case submit(session: SessionId, prompt: AgentPrompt)
    case editQueued(session: SessionId, id: String, text: String, expectedRevision: UInt64, settings: AgentQueuedSettings? = nil)
    case removeQueued(session: SessionId, id: String, expectedRevision: UInt64)
    case deliverQueued(session: SessionId, id: String, expectedRevision: UInt64)
    case moveQueued(session: SessionId, id: String, beforeID: String, expectedRevision: UInt64)
    case resumeQueue(session: SessionId)
    /// Replaces a queued prompt's text, settings and attachments together, against
    /// `expectedRevision`. Older servers reply `unsupported` and keep the prompt as it was.
    case editQueuedPrompt(session: SessionId, id: String, expectedRevision: UInt64, edit: AgentQueuedEdit)
    case answer(session: SessionId, request: String, answers: [String: [String]], cancelled: Bool)
    /// Answers a pending request with one of the decisions its `AgentApprovalRequest`
    /// offered, and a form's answers for a submit decision. Servers that predate it
    /// reply `unsupported`; they never offer decisions, so clients use `approve`.
    case decide(session: SessionId, request: String, decision: String, answers: [String: [String]]? = nil)
    /// Accepts `prompt` like `submit`, but the server delivers it no earlier than `at`,
    /// such as when a usage limit resets. Remove or deliver it like a queued prompt.
    /// Idempotent by prompt ID. Servers that predate it reply `unsupported`.
    case schedule(session: SessionId, prompt: AgentPrompt, at: Date)

    /// Nil model/effort explicitly restore provider defaults; nil provider keeps the current provider.
    /// `providerID` names one of the server's `AgentProviderConfig`s of `provider`'s kind;
    /// nil keeps the conversation's, or the kind's built-in one. Older servers ignore it.
    case send(session: SessionId, text: String, model: String?, reasoningEffort: AgentReasoningEffort? = nil,
              provider: AgentChatProvider? = nil, attachments: [AgentChatAttachment]? = nil, providerID: String? = nil)
    /// `always` also lets the same tool run without asking for the rest of the
    /// conversation; `reason` tells the agent why it was denied. A server that predates
    /// them ignores both and answers this request once.
    case approve(session: SessionId, request: String, allow: Bool, always: Bool? = nil, reason: String? = nil)
    /// Updates host approvals immediately; native provider sandbox policy changes on the next turn.
    case setAccess(session: SessionId, mode: AgentAccessMode)
    /// Selects collaboration mode for the next turn; active turns cannot change mode.
    case setPlan(session: SessionId, enabled: Bool)
    case interrupt(session: SessionId)
    case close(session: SessionId)
    /// Idempotent: a new conversation `session` that starts with everything `from`
    /// said so far, with its provider, model, effort and access, and continues on its
    /// own from the next message. It works in `project`, such as a worktree of
    /// `from`'s, or else in `from`'s project; a server that predates `project`
    /// ignores it.
    case fork(session: SessionId, from: SessionId, project: ProjectId? = nil)
    /// Interrupts `session`'s turn and holds its queue, as Stop does, and with
    /// `descendants` also every open conversation it started, those started, and so on.
    /// Replies with `session`'s snapshot. Only servers with `Feature.agentLineage` know it.
    case stop(session: SessionId, descendants: Bool)
    /// `read`, by the agent that started `session`, to take in what it did: a report on it
    /// still queued to that agent is withdrawn, as this reply carries the news. Only servers
    /// with `Feature.agentLineage` know it.
    case collect(session: SessionId)
}

/// Which Claude tool approvals the user may grant for the rest of a conversation.
public enum AgentApprovalScope {
    /// Questions and plan approvals stay the user's to answer each time.
    public static func canAlwaysAllow(_ tool: String) -> Bool {
        !tool.isEmpty && tool.utf8.count <= 256 && !["AskUserQuestion", "ExitPlanMode", "Tool approval"].contains(tool)
    }
}
