import Foundation
import TabProtocol

/// Find in a conversation: case- and diacritic-insensitive occurrences of a query in the
/// retained user and assistant messages and proposed plans, in transcript order.
///
/// The model searches each item's rendered plain text, as its text provider gives it, so
/// the count and the selection agree with what the transcript paints: a link's URL, a
/// fence's info string or a formula's source are not matches. Rendered texts are kept
/// across queries and matches are cached by item, so a streaming update renders and
/// searches only the items whose text changed.
struct AgentConversationFindModel {
    /// The rendered plain text of a searchable item; nil searches its Markdown source.
    typealias TextProvider = (AgentChatItem) -> String?

    /// One occurrence of the query in an item's rendered text.
    struct Match: Equatable {
        /// The retained item holding the occurrence.
        var itemID: String
        /// The occurrence in the item's rendered text (UTF-16).
        var range: NSRange
        /// The occurrence's position among the item's own matches, from zero.
        var ordinal: Int
    }

    /// What was searched in one item for the current query.
    struct Searched: Equatable {
        /// The Markdown source the text was rendered from.
        var source: String
        /// The rendered text, or nil when the source alone showed that it cannot match.
        var text: String?
        /// The occurrences in `text`, in order.
        var ranges: [NSRange]
    }

    static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private(set) var query = ""
    private(set) var matches: [Match] = []
    private(set) var selectedIndex: Int?
    /// How many times an item was rendered through the text provider.
    private(set) var renderCount = 0
    private let renderedText: TextProvider
    private var texts: [String: (source: String, text: String)] = [:]
    private var searched: [String: Searched] = [:]
    private var itemOrder: [String: Int] = [:]

    /// `text` renders a searchable item to the plain text the transcript shows. Without
    /// one, the model searches the Markdown source.
    init(text: @escaping TextProvider = { _ in nil }) {
        renderedText = text
    }

    /// The current match, if any.
    var selected: Match? { selectedIndex.map { matches[$0] } }

    /// "3 of 12", "No results", or empty while there is no query.
    var counter: String {
        guard !query.isEmpty else { return "" }
        guard let selectedIndex else { return "No results" }
        return "\(selectedIndex + 1) of \(matches.count)"
    }

    /// The Markdown source of what Find searches in `item`, or nil when the item is not
    /// searchable (notices and approvals). A tool call is searched by its name, what it
    /// worked on, its command and its output, as plain text.
    static func searchableText(_ item: AgentChatItem) -> String? {
        switch item.kind {
        case .user, .assistant: return item.text
        case .tool where item.workContext?.itemType == "proposed_plan": return item.detail
        case .tool where item.tool != nil: return toolText(item)
        default: return nil
        }
    }

    /// A tool call's searchable text, bounded.
    static func toolText(_ item: AgentChatItem) -> String? {
        guard let tool = item.tool else { return nil }
        let parts = [tool.name ?? item.text, tool.summary, tool.input, tool.output].compactMap { $0 }.filter { !$0.isEmpty }
        let text = parts.joined(separator: "\n")
        return text.utf8.count > 64 * 1024 ? String(text.prefix(64 * 1024)) : text
    }

    /// Whether `item` is searched as plain text rather than rendered Markdown.
    static func searchesPlainText(_ item: AgentChatItem) -> Bool {
        item.kind == .tool && item.tool != nil && item.workContext?.itemType != "proposed_plan"
    }

    /// What was searched in `itemID` for the current query; nil when it is not searchable
    /// or there is no query.
    func searched(_ itemID: String) -> Searched? { searched[itemID] }

    /// False when `source` cannot render to text that contains `query`, because a word of
    /// the query is missing from it. Rendering removes Markdown syntax around and between
    /// words but never makes up a word, so items that cannot match are not rendered.
    static func mayMatch(_ query: String, renderedFrom source: String) -> Bool {
        let string = source as NSString
        return query.components(separatedBy: CharacterSet.alphanumerics.inverted).allSatisfy { word in
            word.isEmpty || string.range(of: word, options: options).location != NSNotFound
        }
    }

    /// Every occurrence of `query` in `text`, in order.
    static func ranges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let string = text as NSString
        var result: [NSRange] = []
        var location = 0
        while location < string.length {
            let found = string.range(of: query, options: options, range: NSRange(location: location, length: string.length - location))
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found)
            location = found.location + found.length
        }
        return result
    }

    /// Searches for a new query. The selection moves to the first match at or after the
    /// previous one, so refining a query keeps the reader near where they were.
    mutating func search(_ query: String, in items: [AgentChatItem]) {
        let previous = selected
        let previousOrder = previous.flatMap { itemOrder[$0.itemID] }
        if query != self.query { searched.removeAll(keepingCapacity: true) }
        self.query = query
        rebuild(items)
        guard !matches.isEmpty else { selectedIndex = nil; return }
        guard let previous, let previousOrder else { selectedIndex = 0; return }
        selectedIndex = matches.firstIndex { match in
            let order = itemOrder[match.itemID] ?? 0
            return order > previousOrder || (order == previousOrder && match.range.location >= previous.range.location)
        } ?? 0
    }

    /// Applies a changed transcript (streaming, new turns) without moving the reader:
    /// the selection stays on the same occurrence when it still exists, else it clamps.
    mutating func update(_ items: [AgentChatItem]) {
        let previous = selected
        let previousIndex = selectedIndex
        rebuild(items)
        guard !matches.isEmpty else { selectedIndex = nil; return }
        if let previous, let same = matches.firstIndex(where: {
            $0.itemID == previous.itemID && $0.range.location == previous.range.location
        }) {
            selectedIndex = same
            return
        }
        selectedIndex = min(previousIndex ?? 0, matches.count - 1)
    }

    /// Moves to the next match, wrapping from the last to the first.
    mutating func selectNext() {
        guard !matches.isEmpty else { return }
        selectedIndex = ((selectedIndex ?? -1) + 1) % matches.count
    }

    /// Moves to the previous match, wrapping from the first to the last.
    mutating func selectPrevious() {
        guard !matches.isEmpty else { return }
        selectedIndex = ((selectedIndex ?? 0) - 1 + matches.count) % matches.count
    }

    private mutating func rebuild(_ items: [AgentChatItem]) {
        var next: [Match] = []
        var nextSearched: [String: Searched] = [:]
        var nextTexts: [String: (source: String, text: String)] = [:]
        itemOrder.removeAll(keepingCapacity: true)
        for (order, item) in items.enumerated() {
            guard let source = Self.searchableText(item) else { continue }
            itemOrder[item.id] = order
            if let kept = texts[item.id], kept.source == source { nextTexts[item.id] = kept }
            guard !query.isEmpty else { continue }
            let result: Searched
            if let cached = searched[item.id], cached.source == source {
                result = cached
            } else if !Self.mayMatch(query, renderedFrom: source) {
                result = Searched(source: source, text: nil, ranges: [])
            } else {
                let text = nextTexts[item.id]?.text ?? render(item, source: source)
                nextTexts[item.id] = (source, text)
                result = Searched(source: source, text: text, ranges: Self.ranges(of: query, in: text))
            }
            nextSearched[item.id] = result
            for (ordinal, range) in result.ranges.enumerated() {
                next.append(Match(itemID: item.id, range: range, ordinal: ordinal))
            }
        }
        searched = nextSearched
        texts = nextTexts
        matches = next
    }

    private mutating func render(_ item: AgentChatItem, source: String) -> String {
        renderCount += 1
        return renderedText(item) ?? source
    }
}
