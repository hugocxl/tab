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

    public var id: String { provider.rawValue + ":" + providerSession }

    public init(provider: AgentChatProvider, providerSession: String, title: String, updatedAt: Date) {
        self.provider = provider
        self.providerSession = providerSession
        self.title = title
        self.updatedAt = updatedAt
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

    public init(entries: [AgentHistoryEntry], truncated: Bool = false) {
        self.entries = entries
        self.truncated = truncated
    }

    public func validate() throws(ErrorCode) {
        guard entries.count <= Self.maxEntries else { throw .badRequest }
        for entry in entries {
            try AgentHistoryEntry.validate(providerSession: entry.providerSession)
            guard entry.title.utf8.count <= Self.maxTitleBytes else { throw .badRequest }
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

    public init(session: SessionId, project: ProjectId, provider: AgentChatProvider, providerSession: String) {
        self.session = session
        self.project = project
        self.provider = provider
        self.providerSession = providerSession
    }

    public func validate() throws(ErrorCode) {
        try AgentHistoryEntry.validate(providerSession: providerSession)
    }
}
