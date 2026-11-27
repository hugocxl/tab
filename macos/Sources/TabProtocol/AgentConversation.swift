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
    /// Edit from Here: the conversation goes back to before its user message `at`, and its
    /// provider continues from there. What it held before is kept whole as the archived
    /// conversation `archive`, as a clear keeps it. With `restoreFiles`, the files the
    /// removed turns changed are first put back as they were before `at`'s turn; files
    /// changed since are listed in the reply's conflicts and nothing changes, unless `force`.
    /// Refused unless the conversation is still at `revision`. Only turns marked
    /// `rewindable` can be rewound to.
    case rewind(session: SessionId, at: String, archive: SessionId, revision: UInt64, restoreFiles: Bool, force: Bool)
    /// Records the file changes of the turn begun by user message `turn` again, from its
    /// original baseline, after recording them failed.
    case retryCheckpoint(session: SessionId, turn: String)
    /// Opens a closed or archived conversation again, as it was, with its prompts that
    /// need review still held. Replies `conversation`. Idempotent.
    case reopen(session: SessionId)
    /// Chooses how long the server keeps the conversation once it is closed. Replies
    /// `conversation`.
    case setRetention(session: SessionId, retention: AgentConversationRetention)
    /// Deletes a closed or archived conversation and everything kept only for it.
    /// Replies `deleted`. Refused while a pane holds it open.
    case delete(session: SessionId)
    /// Steps of the agent the tool call `toolUseID` started that its newest steps no
    /// longer hold, from the server's saved transcript of it: up to `limit` that came
    /// before position `before`, or the newest when nil. Replies `earlier`.
    case subagentEarlier(session: SessionId, toolUseID: String, before: Int?, limit: Int)
    /// Archived items that may match the Find query `query`, scanning back from archive
    /// position `before`, or from the newest when nil. Replies `archiveSearch`.
    case searchEarlier(session: SessionId, query: String, before: Int?)
}

public enum AgentConversationReply: Codable, Hashable, Sendable {
    case subagentSteps(AgentSubagentSteps)
    case revert(AgentRevertReply)
    case delta(AgentChatDelta)
    case forked(AgentChatSnapshot)
    case toolOutput(AgentToolOutput)
    case earlier(AgentEarlierItems)
    case archiveSearch(AgentArchiveSearchPage)
    case conversation(AgentChatSnapshot)
    case deleted(AgentConversationDeletion)
    case rewound(AgentRewindReply)
    /// The conversation as it is after the request.
    case snapshot(AgentChatSnapshot)
}

/// What Edit from Here did. With `files.conflicts`, nothing changed and `snapshot` is nil.
public struct AgentRewindReply: Codable, Hashable, Sendable {
    /// The rewound conversation.
    public var snapshot: AgentChatSnapshot?
    /// The files put back, or those changed since that stopped it.
    public var files: AgentRevertReply

    public init(snapshot: AgentChatSnapshot?, files: AgentRevertReply = AgentRevertReply()) {
        self.snapshot = snapshot
        self.files = files
    }
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
    /// Files already as they were before the turn, as after another client's revert; they
    /// needed no change. Nil from servers that predate it.
    public var unchanged: [String]?

    public init(reverted: [String] = [], conflicts: [String] = [], unchanged: [String]? = nil) {
        self.reverted = reverted
        self.conflicts = conflicts
        self.unchanged = unchanged
    }
}

/// An agent's own tool calls and text, newest kept. A server that predates saved steps
/// holds them only while the provider process that ran the agent lives, and sends none of
/// the optional fields.
public struct AgentSubagentSteps: Codable, Hashable, Sendable {
    public var toolUseID: String
    public var items: [AgentChatItem]
    /// The content revision these steps were read at; see `AgentSubagent.stepsRevision`.
    public var revision: UInt64?
    /// Saved steps before `items`, read with `subagentEarlier`.
    public var earlierSteps: Int?
    /// Steps before those that weren't kept, past the agent's retention limit.
    public var omittedSteps: Int?
    /// True when the server has no steps saved for this agent, such as one that ran before
    /// steps were saved: an empty `items` then means unknown, not that it did nothing.
    public var unavailable: Bool?

    public init(toolUseID: String, items: [AgentChatItem], revision: UInt64? = nil, earlierSteps: Int? = nil,
                omittedSteps: Int? = nil, unavailable: Bool? = nil) {
        self.toolUseID = toolUseID
        self.items = items
        self.revision = revision
        self.earlierSteps = earlierSteps
        self.omittedSteps = omittedSteps
        self.unavailable = unavailable
    }

    public static let maxItems = 200
    public static let maxBytes = 256 * 1024
}

extension AgentConversationRequest {
    public var session: SessionId {
        switch self {
        case .subagentSteps(let session, _), .revert(let session, _, _, _), .readSince(let session, _),
             .fork(let session, _, _, _), .toolOutput(let session, _), .earlier(let session, _, _),
             .rewind(let session, _, _, _, _, _), .retryCheckpoint(let session, _),
             .reopen(let session), .setRetention(let session, _), .delete(let session),
             .subagentEarlier(let session, _, _, _), .searchEarlier(let session, _, _): session
        }
    }

    public func validate() throws(ErrorCode) {
        switch self {
        case .subagentSteps(_, let toolUseID):
            guard !toolUseID.isEmpty, toolUseID.utf8.count <= 1024 else { throw .badRequest }
        case .revert(_, let checkpoint, let paths, _):
            guard UUID(uuidString: checkpoint) != nil, (paths?.count ?? 0) <= 4096,
                  (paths ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16 * 1024 && !$0.contains("\0") }) else { throw .badRequest }
        case .readSince, .reopen, .delete: break
        case .setRetention(_, let retention): try retention.validate()
        case .toolOutput(_, let item):
            guard !item.isEmpty, item.utf8.count <= 1024 else { throw .badRequest }
        case .fork(let session, let from, _, let at):
            guard session != from, !at.isEmpty, at.utf8.count <= 1024 else { throw .badRequest }
        case .earlier(_, let before, let limit):
            guard (1...AgentEarlierItems.maxItems).contains(limit), (before ?? 0) >= 0 else { throw .badRequest }
        case .rewind(let session, let at, let archive, _, _, _):
            guard session != archive, !at.isEmpty, at.utf8.count <= 1024 else { throw .badRequest }
        case .retryCheckpoint(_, let turn):
            guard UUID(uuidString: turn) != nil else { throw .badRequest }
        case .subagentEarlier(_, let toolUseID, let before, let limit):
            guard !toolUseID.isEmpty, toolUseID.utf8.count <= 1024, (1...AgentEarlierItems.maxItems).contains(limit),
                  (before ?? 0) >= 0 else { throw .badRequest }
        case .searchEarlier(_, let query, let before):
            guard !query.isEmpty, query.utf8.count <= AgentArchiveSearchPage.maxQueryBytes, (before ?? 0) >= 0 else { throw .badRequest }
        }
    }
}

extension AgentConversationReply {
    public func validate() throws(ErrorCode) {
        switch self {
        case .subagentSteps(let steps):
            guard steps.toolUseID.utf8.count <= 1024, steps.items.count <= AgentSubagentSteps.maxItems,
                  steps.items.reduce(0, { $0 + $1.transcriptByteCount }) <= AgentSubagentSteps.maxBytes + 64 * 1024,
                  steps.items.allSatisfy({ $0.id.utf8.count <= 1024 }),
                  (steps.earlierSteps ?? 0) >= 0, (steps.omittedSteps ?? 0) >= 0 else { throw .badRequest }
        case .archiveSearch(let page):
            try page.validate()
        case .revert(let reply):
            guard reply.reverted.count + reply.conflicts.count + (reply.unchanged?.count ?? 0) <= 8192,
                  (try? WireJSON.encode(reply).count).map({ $0 < Limits.maxFrame - 1024 }) ?? false else { throw .badRequest }
        case .rewound(let reply):
            try reply.snapshot?.validate()
            guard reply.files.reverted.count + reply.files.conflicts.count + (reply.files.unchanged?.count ?? 0) <= 8192,
                  (try? WireJSON.encode(reply).count).map({ $0 < Limits.maxFrame - 1024 }) ?? false else { throw .badRequest }
        case .snapshot(let snapshot):
            try snapshot.validate()
        case .forked(let snapshot), .conversation(let snapshot):
            try snapshot.validate()
        case .deleted: break
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
