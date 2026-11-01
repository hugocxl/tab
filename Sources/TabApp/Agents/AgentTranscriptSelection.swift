import AppKit
import TabProtocol

/// What a transcript text view asks of the surface that owns it: selection actions
/// (Cite, Copy, Copy as Markdown) and the floating selection toolbar.
@MainActor
protocol AgentTextSelectionHost: AnyObject {
    /// A mouse-down starts a new selection; without `extending`, other selections are cleared.
    func textSelectionWillBegin(in view: AgentRichTextView, extending: Bool)
    /// The mouse went up after selecting (or clicking) in `view`.
    func textSelectionDidEnd(in view: AgentRichTextView)
    /// `view` lost its selection or its focus.
    func textSelectionDidCollapse(in view: AgentRichTextView)
    /// Context menu items for a selection inside an assistant message; empty elsewhere.
    func textSelectionMenuItems(for view: AgentRichTextView) -> [NSMenuItem]
    /// Copies the transcript selection; false lets the text view copy normally.
    func copyTextSelection(from view: AgentRichTextView) -> Bool
    /// Escape in the transcript: hides the selection toolbar, or else closes the find bar
    /// and returns the keyboard to the composer. False when neither was shown.
    func transcriptDidPressEscape() -> Bool
}

/// The rendered plain text of one message: its text views in reading order, joined by a
/// blank line (`"\n\n"`). Citations, citation highlights and Copy as Markdown address this
/// string, which is what the user sees and what the composer chip shows, rather than the
/// Markdown source. Offsets are UTF-16, like `NSString` and the selector.
@MainActor
struct AgentMessageTextMap {
    struct Segment {
        let view: AgentRichTextView
        /// The view's first character in `plainText`.
        let offset: Int
        let length: Int
    }

    nonisolated static let separator = "\n\n"
    let plainText: String
    let segments: [Segment]

    /// Empty views (such as a table not yet measured) are left out so they add no separator.
    init(views: [AgentRichTextView]) {
        var text = "", segments: [Segment] = [], offset = 0
        for view in views {
            let length = (view.string as NSString).length
            guard length > 0 else { continue }
            if !segments.isEmpty {
                text += Self.separator
                offset += (Self.separator as NSString).length
            }
            segments.append(Segment(view: view, offset: offset, length: length))
            text += view.string
            offset += length
        }
        plainText = text
        self.segments = segments
    }

    /// Renders `markdown` off screen the way the transcript renders an assistant message;
    /// user messages render without raw HTML and with hard line breaks.
    static func render(_ markdown: String, theme: AppTheme, parseRawHTML: Bool = true,
                       lineBreaks: Bool = false) -> AgentMessageTextMap {
        let response = AgentResponseView(frame: .zero)
        response.parseRawHTML = parseRawHTML
        response.lineBreaks = lineBreaks
        response.setContent(markdown, theme: theme)
        // Tables build their text when first measured.
        _ = response.height(for: AgentPaneView.readableWidth)
        return AgentMessageTextMap(views: response.textViews)
    }

    /// Maps a range of one text view to the message's plain text.
    func plainRange(of range: NSRange, in view: AgentRichTextView) -> NSRange? {
        guard range.location >= 0, let segment = segments.first(where: { $0.view === view }),
              NSMaxRange(range) <= segment.length else { return nil }
        return NSRange(location: segment.offset + range.location, length: range.length)
    }

    /// Splits a plain-text range into the part shown by each text view.
    func viewRanges(for range: NSRange) -> [(view: AgentRichTextView, range: NSRange)] {
        segments.compactMap { segment in
            let overlap = NSIntersectionRange(range, NSRange(location: segment.offset, length: segment.length))
            guard overlap.length > 0 else { return nil }
            return (segment.view, NSRange(location: overlap.location - segment.offset, length: overlap.length))
        }
    }

    /// Every non-empty selection of every text view, in reading order.
    var selectedRanges: [NSRange] {
        segments.flatMap { segment in
            segment.view.selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= segment.length }
                .map { NSRange(location: segment.offset + $0.location, length: $0.length) }
        }
    }

    /// The selected attributed text of each text view, joined like `plainText`.
    var selectedAttributedText: NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            guard let storage = segment.view.textStorage else { continue }
            for range in segment.view.selectedRanges.map(\.rangeValue) where range.length > 0 && NSMaxRange(range) <= storage.length {
                if result.length > 0 { result.append(NSAttributedString(string: Self.separator)) }
                result.append(storage.attributedSubstring(from: range))
            }
        }
        return result
    }
}

/// The current selection in the transcript, grouped by assistant message.
@MainActor
struct AgentTranscriptSelection {
    struct Message {
        let item: AgentChatItem
        let map: AgentMessageTextMap
        /// Selected ranges of `map.plainText`, in reading order.
        let ranges: [NSRange]

        /// From the first selected character to the last, across sections.
        var span: NSRange {
            let start = ranges.map(\.location).min() ?? 0
            let end = ranges.map(NSMaxRange).max() ?? start
            return NSRange(location: start, length: end - start)
        }

        var selectedText: String {
            let text = map.plainText as NSString
            return ranges.map { text.substring(with: $0) }.joined(separator: AgentMessageTextMap.separator)
        }
    }

    let messages: [Message]

    var isEmpty: Bool { messages.isEmpty }

    /// A selection can be cited only when it lies within one assistant message.
    var citable: Message? { messages.count == 1 ? messages.first : nil }

    var plainText: String { messages.map(\.selectedText).joined(separator: AgentMessageTextMap.separator) }

    var attributedText: NSAttributedString {
        let result = NSMutableAttributedString()
        for message in messages {
            if result.length > 0 { result.append(NSAttributedString(string: AgentMessageTextMap.separator)) }
            result.append(message.map.selectedAttributedText)
        }
        return result
    }

    /// HTML for the selected attributed text; attachments are left out.
    var html: String? { Self.html(attributedText) }

    /// The original Markdown of each message's selected span, joined by a blank line.
    var markdown: String {
        messages.map { message in
            AgentMarkdownSelectionSlice.slice(markdown: message.item.text, plainText: message.map.plainText, range: message.span)
                ?? message.selectedText
        }.joined(separator: AgentMessageTextMap.separator)
    }

    /// The selection of every mounted assistant message under `root`, in transcript order.
    static func collect(in root: NSView) -> AgentTranscriptSelection {
        var rows: [AgentMessageRow] = []
        func visit(_ view: NSView) {
            if let row = view as? AgentMessageRow {
                if row.assistantItem != nil { rows.append(row) }
                return
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        let ordered = rows.sorted { root.convert($0.bounds, from: $0).minY < root.convert($1.bounds, from: $1).minY }
        let messages = ordered.compactMap { row -> Message? in
            guard let item = row.assistantItem else { return nil }
            let map = row.textMap
            let ranges = map.selectedRanges
            return ranges.isEmpty ? nil : Message(item: item, map: map, ranges: ranges)
        }
        return AgentTranscriptSelection(messages: messages)
    }

    /// Every rich text view under `root`, for clearing stale selections.
    static func textViews(in root: NSView) -> [AgentRichTextView] {
        if let text = root as? AgentRichTextView { return [text] }
        return root.subviews.flatMap { textViews(in: $0) }
    }

    static func html(_ text: NSAttributedString) -> String? {
        guard text.length > 0 else { return nil }
        let content = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: content.length)
        content.removeAttribute(.attachment, range: whole)
        content.mutableString.replaceOccurrences(of: "\u{FFFC}", with: "", options: [], range: whole)
        guard content.length > 0,
              let data = try? content.data(from: NSRange(location: 0, length: content.length), documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
              ]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The JSON clipboard flavor that identifies copied assistant text, so a paste into the
/// composer of the same conversation can become a quotation. Unknown keys are ignored.
struct AgentContextFragment: Codable, Equatable {
    static let mime = "web application/x-tab-context-fragment+json"
    var version = 1
    var environmentId: String
    var threadId: String
    var messageId: String
    var text: String

    init(environmentId: String, threadId: String, messageId: String, text: String) {
        self.environmentId = environmentId
        self.threadId = threadId
        self.messageId = messageId
        self.text = text
    }

    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ json: String) -> AgentContextFragment? {
        guard let fragment = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)), fragment.version == 1,
              ![fragment.environmentId, fragment.threadId, fragment.messageId].contains(where: \.isEmpty),
              !fragment.text.isEmpty else { return nil }
        return fragment
    }

    @MainActor
    static func read(from pasteboard: NSPasteboard) -> AgentContextFragment? {
        guard let type = try? AgentConversationClipboard.pasteboardType(forMIME: mime),
              let json = pasteboard.string(forType: type) else { return nil }
        return decode(json)
    }
}

/// Recovers the Markdown source of a rendered selection. Visible characters are matched in
/// order while Markdown syntax (emphasis, code ticks, link brackets and destinations, table
/// pipes, escapes) and whitespace are skipped; the slice then grows to include the
/// delimiters that open and close the selected spans when that keeps them balanced.
enum AgentMarkdownSelectionSlice {
    private static let syntax: Set<Character> = ["*", "_", "~", "`", "[", "]", "#", ">", "|", "\\", "!", "<"]
    private static let openers: Set<Character> = ["*", "_", "~", "`", "["]
    private static let closers: Set<Character> = ["*", "_", "~", "`"]
    /// Characters a renderer may draw that have no Markdown counterpart.
    private static let decorations: Set<Character> = ["\u{FFFC}", "•", "◦", "▪"]

    /// The Markdown for `range` of `plainText`, or nil when it cannot be located.
    static func slice(markdown: String, plainText: String, range: NSRange) -> String? {
        let plain = plainText as NSString
        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= plain.length else { return nil }
        let selected = plain.substring(with: range)
        let needle = selected.filter { !$0.isWhitespace && !decorations.contains($0) }
        guard !needle.isEmpty else { return nil }
        let source = Array(markdown)
        let target = Array(needle)
        // One backward pass finds every `)` so destination scans never walk to the end of the message.
        var nextClose = [Int](repeating: -1, count: source.count + 1)
        for index in source.indices.reversed() { nextClose[index] = source[index] == ")" ? index : nextClose[index + 1] }
        // Link destinations are not visible text, so a quote cannot start inside one.
        var destination = [Bool](repeating: false, count: source.count)
        var cursor = 0
        while cursor + 1 < source.count {
            if source[cursor] == "]", source[cursor + 1] == "(", cursor + 2 <= source.count, nextClose[cursor + 2] >= 0 {
                let close = nextClose[cursor + 2]
                for index in (cursor + 2)..<close { destination[index] = true }
                cursor = close
            }
            cursor += 1
        }
        var candidates: [(start: Int, end: Int)] = []
        var budget = matchBudget
        for start in source.indices where source[start] == target[0] && !destination[start] {
            guard budget > 0 else { break }
            if let end = match(source, nextClose, from: start, target, budget: &budget) { candidates.append((start, end)) }
        }
        if budget <= 0 { candidates.removeAll() }
        let chosen: (start: Int, end: Int)
        if candidates.count == 1, let only = candidates.first {
            chosen = only
        } else if !candidates.isEmpty, let ordinal = occurrence(of: selected, in: plain, at: range.location, total: candidates.count) {
            chosen = candidates[ordinal]
        } else {
            // Ambiguous or unmatched: fall back to the citation selector's quote search.
            guard let citation = AgentConversationSelectionSelector.citation(in: plainText, range: range, environmentId: "slice", threadId: "slice", messageId: "slice"),
                  let found = AgentConversationSelectionSelector.findInSource(citation, in: markdown) else { return nil }
            return (markdown as NSString).substring(with: found)
        }
        return String(expand(source, nextClose, chosen))
    }

    /// The most characters candidate matching may step over; a pathological message falls back to the quote search.
    private static let matchBudget = 4_000_000

    /// The end of the Markdown span whose visible characters are exactly `target`.
    private static func match(_ source: [Character], _ nextClose: [Int], from start: Int, _ target: [Character], budget: inout Int) -> Int? {
        var index = start, matched = 0
        while matched < target.count {
            budget -= 1
            guard budget > 0, index < source.count else { return nil }
            let character = source[index]
            if character == target[matched] {
                index += 1
                matched += 1
            } else if character.isWhitespace {
                index += 1
            } else if character == "]", index + 1 < source.count, source[index + 1] == "(" {
                guard nextClose[index + 2] >= 0 else { return nil }
                index = nextClose[index + 2] + 1
            } else if syntax.contains(character) {
                index += 1
            } else {
                return nil
            }
        }
        return index
    }

    /// Which of `total` equal rendered occurrences the selection is, when they can be counted.
    private static func occurrence(of selected: String, in plain: NSString, at location: Int, total: Int) -> Int? {
        var ordinal = 0, count = 0, offset = 0
        while offset < plain.length {
            let found = plain.range(of: selected, options: [], range: NSRange(location: offset, length: plain.length - offset))
            if found.location == NSNotFound { break }
            if found.location < location { ordinal += 1 }
            count += 1
            offset = found.location + 1
        }
        return count == total && ordinal < total ? ordinal : nil
    }

    private static func expand(_ source: [Character], _ nextClose: [Int], _ span: (start: Int, end: Int)) -> ArraySlice<Character> {
        var lower = span.start
        while lower > 0, openers.contains(source[lower - 1]) { lower -= 1 }
        var upper = span.end
        while upper < source.count {
            if closers.contains(source[upper]) {
                upper += 1
            } else if source[upper] == "]", upper + 1 < source.count, source[upper + 1] == "(", nextClose[upper + 2] >= 0 {
                upper = nextClose[upper + 2] + 1
            } else { break }
        }
        for (start, end) in [(lower, upper), (span.start, upper), (lower, span.end)] where balanced(source[start..<end]) {
            return source[start..<end]
        }
        return source[span.start..<span.end]
    }

    private static func balanced(_ text: ArraySlice<Character>) -> Bool {
        for delimiter: Character in ["*", "~", "`"] where text.filter({ $0 == delimiter }).count % 2 != 0 { return false }
        return text.filter { $0 == "[" }.count == text.filter { $0 == "]" }.count
    }
}
