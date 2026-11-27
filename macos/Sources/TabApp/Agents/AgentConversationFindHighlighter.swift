import AppKit

/// Paints Find matches into mounted transcript rows as a layout-manager temporary attribute
/// of their own, `.agentFindHighlight`, so the rendered text keeps its colors and other
/// temporary backgrounds, such as a followed citation, never erase or are erased by Find.
///
/// The matches come from the model, which searched the same rendered text; a row is
/// searched here only when it shows text the model did not see. A row is repainted only
/// when its text, the query or its current match changed, so scrolling with the bar open
/// does no work for rows already painted.
@MainActor
final class AgentConversationFindHighlighter {
    private struct RowKey: Equatable {
        let generation: Int
        let query: String
        /// The model's matches; a streaming update changes them for the same row text.
        let searched: AgentConversationFindModel.Searched?
        let current: Int?
        let epoch: Int
    }

    private final class RowPainted {
        let key: RowKey
        weak var firstView: NSTextView?
        let firstLocation: Int?
        init(key: RowKey, firstView: NSTextView?, firstLocation: Int?) {
            self.key = key; self.firstView = firstView; self.firstLocation = firstLocation
        }
    }

    private final class ViewPainted {
        let ranges: [NSRange]
        let current: Int?
        let epoch: Int
        init(ranges: [NSRange], current: Int?, epoch: Int) { self.ranges = ranges; self.current = current; self.epoch = epoch }
    }

    /// Finds `query` in a row's text. Replaceable so tests can count searches.
    var search: (_ query: String, _ text: String) -> [NSRange] = { AgentConversationFindModel.ranges(of: $0, in: $1) }
    /// How many row texts were searched here rather than taken from the model.
    private(set) var searchCount = 0
    /// How many times a row was painted rather than found already painted.
    private(set) var rowPaintCount = 0

    private var rows = NSMapTable<AgentTimelineRow, RowPainted>.weakToStrongObjects()
    private var painted = NSMapTable<NSTextView, ViewPainted>.weakToStrongObjects()
    private var colorEpoch = 0
    private(set) var matchColor: NSColor = .clear
    private(set) var currentColor: NSColor = .clear

    /// Theme colors: other matches get a quiet selection tint, the current one the accent.
    func setTheme(_ theme: AppTheme) {
        matchColor = theme.fg.withAlphaComponent(0.16)
        currentColor = theme.accent.withAlphaComponent(0.45)
        colorEpoch += 1
    }

    /// Paints `query` in a row's text views. `searched` is what the model searched in the
    /// row's item; `current` is the ordinal of the current match among the row's matches,
    /// when the row holds it.
    func paint(_ row: AgentTimelineRow, query: String, searched: AgentConversationFindModel.Searched?, current: Int?) {
        let key = RowKey(generation: row.findTextGeneration, query: query, searched: searched, current: current,
                     epoch: colorEpoch)
        if let previous = rows.object(forKey: row), previous.key == key,
           stillPainted(previous.firstView, at: previous.firstLocation) {
            return
        }
        rowPaintCount += 1
        let text = row.findText
        let ranges = matchRanges(in: text.plainText, query: query, searched: searched)
        let current = Self.clamp(current, total: ranges.count)
        var index = 0
        var first: (view: NSTextView, location: Int)?
        for segment in text.segments {
            let span = NSRange(location: segment.offset, length: segment.length)
            var local: [NSRange] = []
            var localCurrent: Int?
            while index < ranges.count, ranges[index].location < NSMaxRange(span) {
                let part = NSIntersectionRange(ranges[index], span)
                if part.length > 0 {
                    if index == current { localCurrent = local.count }
                    local.append(NSRange(location: part.location - span.location, length: part.length))
                }
                // A match running past this view continues in the next one.
                if NSMaxRange(ranges[index]) > NSMaxRange(span) { break }
                index += 1
            }
            if first == nil, let location = local.first?.location { first = (segment.view, location) }
            paint(segment.view, ranges: local, current: localCurrent)
        }
        rows.setObject(RowPainted(key: key, firstView: first?.view, firstLocation: first?.location), forKey: row)
    }

    /// The current match's text view and character range in a row, using the same
    /// matches as `paint`.
    func currentMatch(in row: AgentTimelineRow, query: String, searched: AgentConversationFindModel.Searched?,
                      ordinal: Int) -> (view: AgentRichTextView, range: NSRange)? {
        let text = row.findText
        let ranges = matchRanges(in: text.plainText, query: query, searched: searched)
        guard let index = Self.clamp(ordinal, total: ranges.count) else { return nil }
        return text.viewRanges(for: ranges[index]).first
    }

    /// Removes every painted match, including from rows that are no longer mounted.
    func clear() {
        for view in painted.keyEnumerator().allObjects.compactMap({ $0 as? NSTextView }) {
            erase(view)
        }
        painted.removeAllObjects()
        rows.removeAllObjects()
    }

    /// The model's matches when the row shows the text the model searched; otherwise the
    /// row's own text is searched, which happens only while the two disagree.
    private func matchRanges(in text: String, query: String, searched: AgentConversationFindModel.Searched?) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        if let searched {
            guard let known = searched.text else { return [] }
            if known == text { return searched.ranges }
        }
        searchCount += 1
        return search(query, text)
    }

    /// Rows hold fewer matches than the model when they show other text than it searched;
    /// a current match past the rendered ones lands on the last of them.
    private static func clamp(_ ordinal: Int?, total: Int) -> Int? {
        guard let ordinal, total > 0 else { return nil }
        return min(ordinal, total - 1)
    }

    private func paint(_ view: NSTextView, ranges: [NSRange], current: Int?) {
        let previous = painted.object(forKey: view)
        if let previous, previous.ranges == ranges, previous.current == current, previous.epoch == colorEpoch,
           stillPainted(view, at: ranges.first?.location) {
            return
        }
        if previous == nil, ranges.isEmpty { return }
        erase(view)
        if let manager = view.layoutManager {
            for (index, range) in ranges.enumerated() {
                manager.addTemporaryAttribute(.agentFindHighlight, value: index == current ? currentColor : matchColor,
                                              forCharacterRange: range)
                manager.invalidateDisplay(forCharacterRange: range)
            }
        }
        painted.setObject(ViewPainted(ranges: ranges, current: current, epoch: colorEpoch), forKey: view)
    }

    /// Replacing a text view's content drops its temporary attributes; repaint then.
    private func stillPainted(_ view: NSTextView?, at location: Int?) -> Bool {
        guard let location else { return true }
        guard let view, let manager = view.layoutManager, location < (view.textStorage?.length ?? 0) else { return false }
        return manager.temporaryAttribute(.agentFindHighlight, atCharacterIndex: location, effectiveRange: nil) != nil
    }

    private func erase(_ view: NSTextView) {
        guard let manager = view.layoutManager, let length = view.textStorage?.length, length > 0 else { return }
        let all = NSRange(location: 0, length: length)
        manager.removeTemporaryAttribute(.agentFindHighlight, forCharacterRange: all)
        manager.invalidateDisplay(forCharacterRange: all)
    }
}
