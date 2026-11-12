import AppKit
import TabCore

/// A Find request for the conversation, from the menu bar or a shortcut.
enum AgentConversationFindAction: Equatable {
    case open, next, previous, close

    init?(shortcut: ShortcutId) {
        switch shortcut {
        case .find: self = .open
        case .findNext: self = .next
        case .findPrevious: self = .previous
        default: return nil
        }
    }
}

extension AgentPaneController {
    /// Cmd-F, Cmd-G and Shift-Cmd-G in an agent pane; false lets the key go on.
    @MainActor
    func performConversationShortcut(_ id: ShortcutId) -> Bool {
        switch id {
        case .agentPromptOutline: surface.showOutline(); return true
        case .agentPreviousPrompt: surface.navigatePrompt(previous: true); return true
        case .agentNextPrompt: surface.navigatePrompt(previous: false); return true
        case .agentHistory: showHistory(); return true
        default: break
        }
        if id == .toggleAgentPlan { togglePlanMode(); return true }
        guard let action = AgentConversationFindAction(shortcut: id) else { return false }
        return surface.performFind(action)
    }
}

extension AgentPaneView {
    /// True while the find bar is open.
    var isFindOpen: Bool { findModel != nil }

    /// Find in the transcript. Open (or refocus) the bar, step through matches, or close.
    /// Stepping and closing return false while the bar is closed, so the key goes on.
    @discardableResult
    func performFind(_ action: AgentConversationFindAction) -> Bool {
        switch action {
        case .open:
            openFind()
            return true
        case .next, .previous:
            guard findModel != nil else { return false }
            stepFind(previous: action == .previous)
            return true
        case .close:
            guard findModel != nil else { return false }
            closeFind()
            return true
        }
    }

    private func openFind() {
        let bar = findBar ?? makeFindBar()
        if findModel == nil {
            var model = AgentConversationFindModel { [weak self] item in self?.renderedFindText(item) }
            model.search(bar.query, in: snapshot?.items ?? [])
            findModel = model
            findHighlighter.setTheme(theme)
            transcript.onViewportSettled = { [weak self] in self?.paintFindMatches() }
            bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: AgentConversationFindBar.height)
            bar.isHidden = false
            bar.counter = model.counter
            paintFindMatches()
        }
        bar.focus()
    }

    private func makeFindBar() -> AgentConversationFindBar {
        let bar = AgentConversationFindBar(frame: .zero)
        bar.theme = theme
        bar.isHidden = true
        bar.onQueryChange = { [weak self] query in self?.findQueryDidChange(query) }
        bar.onStep = { [weak self] previous in self?.stepFind(previous: previous) }
        bar.onClose = { [weak self] in self?.closeFind() }
        addSubview(bar, positioned: .above, relativeTo: transcriptScroll)
        findBar = bar
        return bar
    }

    private func closeFind() {
        findModel = nil
        transcript.onViewportSettled = nil
        findHighlighter.clear()
        findBar?.isHidden = true
        window?.makeFirstResponder(composer)
    }

    private func findQueryDidChange(_ query: String) {
        guard var model = findModel else { return }
        model.search(query, in: snapshot?.items ?? [])
        findModel = model
        findSelectionDidChange()
    }

    private func stepFind(previous: Bool) {
        guard var model = findModel else { return }
        if previous { model.selectPrevious() } else { model.selectNext() }
        findModel = model
        findSelectionDidChange()
    }

    private func findSelectionDidChange() {
        findBar?.counter = findModel?.counter ?? ""
        paintFindMatches()
        revealFindSelection()
    }

    /// A new snapshot: keep the selection on its occurrence and repaint, without scrolling.
    func findTranscriptDidChange() {
        guard var model = findModel else { return }
        model.update(snapshot?.items ?? [])
        findModel = model
        findBar?.counter = model.counter
        paintFindMatches()
    }

    /// The plain text Find searches in `item`: a mounted row's own text, so the matches
    /// map exactly onto what it paints, else an off-screen render of the item.
    func renderedFindText(_ item: AgentChatItem) -> String? {
        if let row = transcript.mountedRow(showing: item) { return row.findText.plainText }
        return findTexts.text(for: item, theme: theme)
    }

    /// Paints the matches of every mounted row; rows mounted later are painted as the
    /// transcript settles its viewport. Rows already painted cost a comparison each.
    func paintFindMatches() {
        guard let model = findModel else { return }
        guard !model.query.isEmpty else { return findHighlighter.clear() }
        let selected = model.selected
        transcript.forEachMountedItemRow { itemID, row in
            guard let searched = model.searched(itemID) else { return }
            findHighlighter.paint(row, query: model.query, searched: searched,
                                  current: selected?.itemID == itemID ? selected?.ordinal : nil)
        }
    }

    /// The transcript's visible area below the find bar, in document coordinates.
    var findVisibleRect: NSRect {
        var rect = transcriptScroll.contentView.bounds
        let inset = findBar?.isHidden == false ? AgentConversationFindBar.height : 0
        rect.origin.y += inset
        rect.size.height = max(0, rect.height - inset)
        return rect
    }

    /// The current match's rect in transcript document coordinates, when its row is mounted.
    func currentFindMatchRect() -> NSRect? {
        guard let (view, range) = currentFindMatch(), !view.isHiddenOrHasHiddenAncestor,
              let manager = view.layoutManager, let container = view.textContainer else { return nil }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        // Code blocks and tool output scroll on their own; bring the match into their view first.
        if let inner = view.enclosingScrollView, inner !== transcriptScroll { view.scrollToVisible(rect) }
        return transcript.convert(rect, from: view)
    }

    /// The current match's text view and range, when its row is mounted.
    private func currentFindMatch() -> (view: AgentRichTextView, range: NSRange)? {
        guard let model = findModel, let match = model.selected,
              let entryID = transcript.entryID(showing: match.itemID),
              let row = transcript.mountedRow(entryID) else { return nil }
        return findHighlighter.currentMatch(in: row, query: model.query, searched: model.searched(match.itemID),
                                            ordinal: match.ordinal)
    }

    /// Scrolls the current match into view, below the bar. A folded work group, a folded
    /// `<details>` block or a collapsed message opens only when the match is inside it.
    private func revealFindSelection() {
        guard let match = findModel?.selected else { return }
        if transcript.entryID(showing: match.itemID) == nil {
            guard transcript.anchor(revealing: .item(match.itemID)) != nil else { return }
        }
        guard let entryID = transcript.entryID(showing: match.itemID) else { return }
        if transcript.mountedRow(entryID) == nil {
            scroll(to: AgentTranscriptAnchor(rowID: entryID, localOffset: 0, fallback: findVisibleRect.minY))
        }
        if let row = transcript.mountedRow(entryID), let current = currentFindMatch(),
           row.revealFindText(current.view, range: current.range) {
            paintFindMatches()
        }
        if currentFindMatchRect() == nil {
            scroll(to: AgentTranscriptAnchor(rowID: entryID, localOffset: 0, fallback: findVisibleRect.minY))
        }
        guard let rect = currentFindMatchRect(), let row = transcript.frameForEntry(entryID) else { return }
        let visible = findVisibleRect
        if rect.minY >= visible.minY && rect.maxY <= visible.maxY { return }
        let target = rect.minY - AgentConversationFindBar.height - max(0, visible.height - rect.height) / 3
        scroll(to: AgentTranscriptAnchor(rowID: entryID, localOffset: target - row.minY, fallback: target))
        paintFindMatches()
    }
}

/// The rendered plain text of transcript items that are not mounted, for Find: an
/// off-screen render per item, kept while the item's Markdown is unchanged. Bounded,
/// dropping the oldest renders first.
@MainActor
final class AgentConversationFindTextCache {
    /// The most items kept; a long conversation renders the rest again when searched.
    let capacity: Int

    private var entries: [String: (source: String, text: String)] = [:]
    private var order: [String] = []
    /// How many items were rendered off screen.
    private(set) var renderCount = 0

    init(capacity: Int = 512) {
        self.capacity = capacity
    }

    /// The text the transcript would show for `item`, or nil when Find does not search it.
    func text(for item: AgentChatItem, theme: AppTheme) -> String? {
        guard let source = AgentConversationFindModel.searchableText(item) else { return nil }
        if let entry = entries[item.id], entry.source == source { return entry.text }
        renderCount += 1
        // Rendered like the rows: user messages keep hard line breaks and show raw HTML as text.
        let text = AgentMessageTextMap.render(source, theme: theme, parseRawHTML: item.kind != .user,
                                              lineBreaks: item.kind == .user).plainText
        if entries[item.id] == nil { order.append(item.id) }
        entries[item.id] = (source, text)
        while entries.count > capacity, !order.isEmpty { entries[order.removeFirst()] = nil }
        return text
    }
}
