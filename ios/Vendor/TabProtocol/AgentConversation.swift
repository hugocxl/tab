import Foundation

/// Requests about one agent conversation that reply with something other than its
/// snapshot. A server that predates one of them can't decode it and replies
/// `unsupported`, so clients fall back or say the server needs an update.
public enum AgentConversationRequest: Codable, Hashable, Sendable {
    /// The steps of the agent the tool call `toolUseID` started.
    case subagentSteps(session: SessionId, toolUseID: String)
    /// Puts files a turn changed back as they were before it: `paths` of the turn's
    /// changed files, or all of them when nil. Files changed again since the turn are
    /// left alone and listed in the reply's `conflicts`, unless `force`.
    case revert(session: SessionId, checkpoint: String, paths: [String]?, force: Bool)
    /// The conversation as it is now, with only the items that changed after `revision`;
    /// see `AgentChatDelta`.
    case readSince(session: SessionId, revision: UInt64)
    /// Like `AgentChatRequest.fork`, but the new conversation `session` holds only what
    /// `from` said before its user message `at`, and its provider continues from there.
    /// Idempotent. Only providers that can resume at a message support it.
    case fork(session: SessionId, from: SessionId, project: ProjectId?, at: String)
    /// The whole output of the tool item `item`, when the transcript keeps only part.
    case toolOutput(session: SessionId, item: String)
    /// Items the conversation no longer holds because it grew past its size limit, from
    /// the server's archive of them: up to `limit` that came before archive position
    /// `before`, or the newest when nil.
    case earlier(session: SessionId, before: Int?, limit: Int)
}

public enum AgentConversationReply: Codable, Hashable, Sendable {
    case subagentSteps(AgentSubagentSteps)
    case revert(AgentRevertReply)
    case delta(AgentChatDelta)
    case forked(AgentChatSnapshot)
    case toolOutput(AgentToolOutput)
    case earlier(AgentEarlierItems)
}

/// Archived items in conversation order: `items` start at archive position `start`, of
/// `total` archived. Items dropped before the archive existed aren't in it.
public struct AgentEarlierItems: Codable, Hashable, Sendable {
    public var items: [AgentChatItem]
    public var start: Int
    public var total: Int

    public init(items: [AgentChatItem], start: Int, total: Int) {
        self.items = items; self.start = start; self.total = total
    }

    public static let maxItems = 100
    /// A page stops before this many bytes of items, whatever `limit` asked for.
    public static let maxBytes = 4 * 1024 * 1024
}

/// A tool's whole output, up to `maximumBytes`.
public struct AgentToolOutput: Codable, Hashable, Sendable {
    public var item: String
    public var text: String
    /// Even the stored output was cut at `maximumBytes`.
    public var truncated: Bool

    public init(item: String, text: String, truncated: Bool = false) {
        self.item = item; self.text = text; self.truncated = truncated
    }

    public static let maximumBytes = 4 * 1024 * 1024
}

/// A conversation read relative to a revision the client holds: every header field as
/// now, the order of every item by ID, and the items that changed after `since`. A
/// client applies it to its snapshot at `since`; an ID it holds no item for means it
/// must read the whole conversation instead.
public struct AgentChatDelta: Codable, Hashable, Sendable {
    /// The conversation now; `items` holds only the changed ones.
    public var snapshot: AgentChatSnapshot
    public var since: UInt64
    /// Every item now, in order.
    public var itemIDs: [String]

    public init(snapshot: AgentChatSnapshot, since: UInt64, itemIDs: [String]) {
        self.snapshot = snapshot
        self.since = since
        self.itemIDs = itemIDs
    }

    /// The conversation now, from `base` at `since`, or nil when `base` lacks an item the
    /// delta didn't send or doesn't match.
    public func applied(to base: AgentChatSnapshot) -> AgentChatSnapshot? {
        guard base.session == snapshot.session, base.revision == since else { return nil }
        var known: [String: AgentChatItem] = [:]
        known.reserveCapacity(base.items.count)
        for item in base.items { known[item.id] = item }
        for item in snapshot.items { known[item.id] = item }
        var items: [AgentChatItem] = []
        items.reserveCapacity(itemIDs.count)
        for id in itemIDs {
            guard let item = known[id] else { return nil }
            items.append(item)
        }
        var result = snapshot
        result.items = items
        return result
    }
}

/// What a revert did. With `conflicts`, nothing changed: those files no longer match
/// what the turn left, and reverting them needs `force`.
public struct AgentRevertReply: Codable, Hashable, Sendable {
    public var reverted: [String]
    public var conflicts: [String]

    public init(reverted: [String] = [], conflicts: [String] = []) {
        self.reverted = reverted
        self.conflicts = conflicts
    }
}

/// An agent's own tool calls and text, newest kept. The server holds them only while
/// the provider process that ran the agent lives.
public struct AgentSubagentSteps: Codable, Hashable, Sendable {
    public var toolUseID: String
    public var items: [AgentChatItem]

    public init(toolUseID: String, items: [AgentChatItem]) {
        self.toolUseID = toolUseID
        self.items = items
    }

    public static let maxItems = 200
    public static let maxBytes = 256 * 1024
}

extension AgentConversationRequest {
    public var session: SessionId {
        switch self {
        case .subagentSteps(let session, _), .revert(let session, _, _, _), .readSince(let session, _),
             .fork(let session, _, _, _), .toolOutput(let session, _), .earlier(let session, _, _): session
        }
    }

    public func validate() throws(ErrorCode) {
        switch self {
        case .subagentSteps(_, let toolUseID):
            guard !toolUseID.isEmpty, toolUseID.utf8.count <= 1024 else { throw .badRequest }
        case .revert(_, let checkpoint, let paths, _):
            guard UUID(uuidString: checkpoint) != nil, (paths?.count ?? 0) <= 4096,
                  (paths ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16 * 1024 && !$0.contains("\0") }) else { throw .badRequest }
        case .readSince: break
        case .toolOutput(_, let item):
            guard !item.isEmpty, item.utf8.count <= 1024 else { throw .badRequest }
        case .fork(let session, let from, _, let at):
            guard session != from, !at.isEmpty, at.utf8.count <= 1024 else { throw .badRequest }
        case .earlier(_, let before, let limit):
            guard (1...AgentEarlierItems.maxItems).contains(limit), (before ?? 0) >= 0 else { throw .badRequest }
        }
    }
}

extension AgentConversationReply {
    public func validate() throws(ErrorCode) {
        switch self {
        case .subagentSteps(let steps):
            guard steps.toolUseID.utf8.count <= 1024, steps.items.count <= AgentSubagentSteps.maxItems,
                  steps.items.reduce(0, { $0 + $1.transcriptByteCount }) <= AgentSubagentSteps.maxBytes + 64 * 1024,
                  steps.items.allSatisfy({ $0.id.utf8.count <= 1024 }) else { throw .badRequest }
        case .revert(let reply):
            guard reply.reverted.count + reply.conflicts.count <= 8192,
                  (try? WireJSON.encode(reply).count).map({ $0 < Limits.maxFrame - 1024 }) ?? false else { throw .badRequest }
        case .forked(let snapshot):
            try snapshot.validate()
        case .toolOutput(let output):
            guard output.item.utf8.count <= 1024, output.text.utf8.count <= AgentToolOutput.maximumBytes else { throw .badRequest }
        case .earlier(let page):
            guard page.items.count <= AgentEarlierItems.maxItems, page.start >= 0, page.start + page.items.count <= page.total,
                  page.items.allSatisfy({ $0.id.utf8.count <= 1024 }),
                  page.items.reduce(0, { $0 + $1.transcriptByteCount }) <= AgentEarlierItems.maxBytes + 64 * 1024 else { throw .badRequest }
        case .delta(let delta):
            let ids = Set(delta.itemIDs)
            guard delta.itemIDs.count <= 512, ids.count == delta.itemIDs.count, delta.itemIDs.allSatisfy({ $0.utf8.count <= 1024 }),
                  delta.snapshot.items.count <= 512, delta.snapshot.items.allSatisfy({ ids.contains($0.id) }),
                  delta.snapshot.items.reduce(0, { $0 + $1.transcriptByteCount }) <= 512 * 1024,
                  (delta.snapshot.turns?.count ?? 0) <= 512, (delta.snapshot.subagents?.count ?? 0) <= AgentSubagent.maxCount,
                  (try? WireJSON.encode(delta).count).map({ $0 < Limits.maxFrame - 1024 }) ?? false else { throw .badRequest }
        }
    }
}
