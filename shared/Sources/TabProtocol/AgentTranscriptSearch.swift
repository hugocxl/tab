import Foundation

/// What conversation Find searches in an item, shared by the app, which searches the
/// items it shows, and the server, which searches the archive of items a conversation
/// dropped past its size limit. Both read the same text and accept the same candidates.
public enum AgentTranscriptSearch {
    /// Find ignores case and accents.
    public static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The Markdown source of what Find searches in `item`, or nil when the item is not
    /// searchable (notices and approvals). A tool call is searched by its name, what it
    /// worked on, its command and its output, as plain text.
    public static func searchableText(_ item: AgentChatItem) -> String? {
        switch item.kind {
        case .user, .assistant: return item.text
        case .tool where item.workContext?.itemType == "proposed_plan": return item.detail
        case .tool where item.tool != nil: return toolText(item)
        default: return nil
        }
    }

    /// A tool call's searchable text, bounded.
    public static func toolText(_ item: AgentChatItem) -> String? {
        guard let tool = item.tool else { return nil }
        let parts = [tool.name ?? item.text, tool.summary, tool.input, tool.output].compactMap { $0 }.filter { !$0.isEmpty }
        let text = parts.joined(separator: "\n")
        return text.utf8.count > 64 * 1024 ? String(text.prefix(64 * 1024)) : text
    }

    /// False when `source` cannot render to text that contains `query`, because a word of
    /// the query is missing from it. Rendering removes Markdown syntax around and between
    /// words but never makes up a word, so items that cannot match are not rendered.
    public static func mayMatch(_ query: String, renderedFrom source: String) -> Bool {
        let string = source as NSString
        return query.components(separatedBy: CharacterSet.alphanumerics.inverted).allSatisfy { word in
            word.isEmpty || string.range(of: word, options: options).location != NSNotFound
        }
    }

    /// Whether `item` could hold a match for `query`: the server's archive search keeps
    /// these, and the app confirms each against the text it renders.
    public static func mayMatch(_ query: String, item: AgentChatItem) -> Bool {
        guard !query.isEmpty, let source = searchableText(item) else { return false }
        return mayMatch(query, renderedFrom: source)
    }
}

/// Archived items that may match a Find query, found scanning the archive from newest to
/// oldest. `items` are the candidates at archive positions `positions`, oldest first; the
/// scan covered positions `start..<end` of the `total` archived. A client continues from
/// `start` until it reaches zero. The app confirms each candidate against its rendering.
public struct AgentArchiveSearchPage: Codable, Hashable, Sendable {
    public var query: String
    public var items: [AgentChatItem]
    public var positions: [Int]
    public var start: Int
    public var end: Int
    public var total: Int

    public init(query: String, items: [AgentChatItem], positions: [Int], start: Int, end: Int, total: Int) {
        self.query = query; self.items = items; self.positions = positions
        self.start = start; self.end = end; self.total = total
    }

    /// A page stops at this many candidates or bytes of them, whatever was left to scan.
    public static let maxItems = 100
    public static let maxBytes = 4 * 1024 * 1024
    /// A query longer than this isn't searched.
    public static let maxQueryBytes = 1024

    public func validate() throws(ErrorCode) {
        guard query.utf8.count <= Self.maxQueryBytes, items.count == positions.count, items.count <= Self.maxItems,
              start >= 0, start <= end, end <= total, positions.allSatisfy({ (start..<max(start, end)).contains($0) }),
              zip(positions, positions.dropFirst()).allSatisfy({ $0 < $1 }),
              items.allSatisfy({ $0.id.utf8.count <= 1024 }),
              items.reduce(0, { $0 + $1.transcriptByteCount }) <= Self.maxBytes + 64 * 1024 else { throw .badRequest }
    }
}
