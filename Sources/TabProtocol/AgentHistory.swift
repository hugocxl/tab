import Foundation

/// Lists conversations Claude Code and Codex saved for a project's folder
/// outside Tab, so a pane can continue one.
public struct AgentHistoryRequest: Hashable, Codable, Sendable {
    public var project: ProjectId

    public init(project: ProjectId) {
        self.project = project
    }
}

/// One conversation a provider CLI saved on the server.
public struct AgentHistoryEntry: Hashable, Codable, Sendable, Identifiable {
    public var provider: AgentChatProvider
    /// The provider's own session ID, which resumes it.
    public var providerSession: String
    public var title: String
    public var updatedAt: Date
    /// The provider, such as `claude-work`, whose folder saved it, which continues it.
    /// Nil from servers that read only each kind's default folder.
    public var providerID: String?

    public var id: String { (providerID ?? provider.rawValue) + ":" + providerSession }

    public init(provider: AgentChatProvider, providerSession: String, title: String, updatedAt: Date, providerID: String? = nil) {
        self.provider = provider
        self.providerSession = providerSession
        self.title = title
        self.updatedAt = updatedAt
        self.providerID = providerID
    }

    /// Provider session IDs name files on the server, so only plain identifiers pass.
    public static func validate(providerSession: String) throws(ErrorCode) {
        guard !providerSession.isEmpty, providerSession.utf8.count <= 128,
              providerSession.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { throw .badRequest }
    }
}

public struct AgentHistoryReply: Hashable, Codable, Sendable {
    public static let maxEntries = 200
    public static let maxTitleBytes = 512
    public var entries: [AgentHistoryEntry]
    /// Older conversations were left out.
    public var truncated: Bool
    /// Tab's own conversations for the project that no pane shows, newest first.
    /// Absent from servers that predate reopening them.
    public var conversations: [AgentSavedConversation]?

    public init(entries: [AgentHistoryEntry], truncated: Bool = false, conversations: [AgentSavedConversation]? = nil) {
        self.entries = entries
        self.truncated = truncated
        self.conversations = conversations
    }

    public func validate() throws(ErrorCode) {
        guard entries.count <= Self.maxEntries else { throw .badRequest }
        for entry in entries {
            try AgentHistoryEntry.validate(providerSession: entry.providerSession)
            guard entry.title.utf8.count <= Self.maxTitleBytes, (entry.providerID?.utf8.count ?? 0) <= 64 else { throw .badRequest }
        }
        guard (conversations?.count ?? 0) <= Self.maxEntries else { throw .badRequest }
        for conversation in conversations ?? [] {
            guard conversation.title.utf8.count <= Self.maxTitleBytes else { throw .badRequest }
            try conversation.retention.validate()
        }
    }
}

/// Idempotent: makes `session` a Tab conversation that continues the provider's
/// `providerSession`, with its transcript so far. `session` may be an unused
/// conversation, which takes it over. When another open conversation already
/// continues it, the reply is that conversation.
public struct AgentHistoryImport: Hashable, Codable, Sendable {
    public var session: SessionId
    public var project: ProjectId
    public var provider: AgentChatProvider
    public var providerSession: String
    /// The entry's `providerID`: the provider whose folder saved it, and that continues it.
    public var providerID: String?

    public init(session: SessionId, project: ProjectId, provider: AgentChatProvider, providerSession: String,
                providerID: String? = nil) {
        self.session = session
        self.project = project
        self.provider = provider
        self.providerSession = providerSession
        self.providerID = providerID
    }

    public func validate() throws(ErrorCode) {
        try AgentHistoryEntry.validate(providerSession: providerSession)
        if let providerID, !AgentProviderConfig.isValidID(providerID) { throw .badRequest }
    }
}
