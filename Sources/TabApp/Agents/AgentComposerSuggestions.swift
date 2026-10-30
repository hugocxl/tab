import AppKit

/// T3 useComposerMenuItems combines real workspace paths and thread matches for
/// @, and supported actions plus discovered skill metadata for /. Keep lookup
/// and execution in the coordinator; the native surface never invents results.
struct AgentComposerSuggestion: Equatable, Identifiable {
    enum Kind: String { case file, thread, skill, action }
    struct SkillMetadata: Equatable {
        let name: String
        var path: String? = nil
        var source: String? = nil
    }

    let id: String
    let title: String
    var subtitle: String = ""
    var symbol: String = "doc"
    let kind: Kind
    /// The caller resolves real file/thread identities and executes actions, not the menu.
    var insertionText: String? = nil
    var skill: SkillMetadata? = nil
}

struct AgentComposerTrigger: Equatable {
    enum Kind { case mention, command }
    let kind: Kind
    let query: String
    let range: NSRange

    static func parse(text: String, selection: NSRange) -> Self? {
        AgentComposerTriggerParser.parse(text: text, selection: selection)
    }
}

enum AgentComposerTriggerParser {
    /// Based on T3 apps/web/src/composer-logic.ts detectComposerTrigger: inspect the
    /// whitespace-delimited token *before the caret*, not the end of the draft.
    /// Native differences: slash actions are prompt-leading only, code is excluded,
    /// selections are left untouched, and replacement consumes a mid-token suffix.
    static func parse(text: String, selection: NSRange) -> AgentComposerTrigger? {
        let ns = text as NSString
        guard selection.location != NSNotFound, selection.length == 0,
              selection.location >= 0, selection.location <= ns.length,
              let caret = Range(selection, in: text)?.lowerBound else { return nil }
        // Foundation can map UTF-16 offsets into a scalar/grapheme interior.
        // Character-based backward traversal requires an actual Character boundary.
        guard caret == text.endIndex || text.indices.contains(caret) else { return nil }
        var start = caret
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        guard start < caret, !isInsideCode(text[..<start]) else { return nil }
        let prefix = text[start..<caret]
        guard let marker = prefix.first, marker == "@" || marker == "/" else { return nil }
        let kind: AgentComposerTrigger.Kind = marker == "@" ? .mention : .command
        if kind == .command && !text[..<start].allSatisfy(\.isWhitespace) { return nil }
        let query = String(prefix.dropFirst())
        // A second trigger, URL punctuation, or inline code is not a search query.
        guard !query.contains(where: { "@`<>\"'".contains($0) }),
              !query.contains("://"),
              kind != .command || query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" })
        else { return nil }
        var end = caret
        while end < text.endIndex && !text[end].isWhitespace { end = text.index(after: end) }
        return AgentComposerTrigger(kind: kind, query: query,
                                    range: NSRange(start..<end, in: text))
    }

    /// Ignore inline backticks and fenced code (including tilde fences). Keep this
    /// independent of AppKit/editor state so file searches need no live text view.
    private static func isInsideCode(_ prefix: Substring) -> Bool {
        var fence: Character?
        var fenceLength = 0
        var inlineTicks = 0
        for line in prefix.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    if fence == marker && count >= fenceLength { fence = nil; fenceLength = 0 }
                    else if fence == nil { fence = marker; fenceLength = count }
                    continue
                }
            }
            guard fence == nil else { continue }
            var index = line.startIndex
            while index < line.endIndex {
                if line[index] == "\\" {
                    index = line.index(after: index)
                    if index < line.endIndex { index = line.index(after: index) }
                    continue
                }
                if line[index] == "`" {
                    var count = 0
                    while index < line.endIndex && line[index] == "`" {
                        count += 1
                        index = line.index(after: index)
                    }
                    if inlineTicks == 0 { inlineTicks = count }
                    else if inlineTicks == count { inlineTicks = 0 }
                } else { index = line.index(after: index) }
            }
        }
        return fence != nil || inlineTicks != 0
    }
}

/// Mirrors T3 useComposerTriggerState: Escape stays dismissed for the current
/// token even while its query changes; leaving the token re-arms suggestions.
struct AgentComposerTriggerState {
    private var dismissed: AgentComposerTrigger?
    mutating func resolve(_ candidate: AgentComposerTrigger?) -> AgentComposerTrigger? {
        if let candidate, let dismissed,
           candidate.kind == dismissed.kind,
           candidate.range.location == dismissed.range.location { return nil }
        dismissed = nil
        return candidate
    }
    mutating func dismiss(_ trigger: AgentComposerTrigger?) { dismissed = trigger }
    mutating func reset() { dismissed = nil }
}

/// A non-modal child surface: the composer remains first responder while typing.
/// T3 ComposerCommandMenu scrolls the active item into view and prevents mouse
/// down from stealing editor focus; this native table follows both behaviors.
@MainActor
final class AgentComposerSuggestionsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((AgentComposerSuggestion) -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var items: [AgentComposerSuggestion] = []
    private(set) var selectedIndex = -1
    let tableView = AgentComposerSuggestionTable()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matches")
    var emptyStateText: String = "No matches" {
        didSet { emptyLabel.stringValue = emptyStateText; emptyLabel.setAccessibilityLabel(emptyStateText) }
    }
    private var theme: AppTheme = .shared
    private var isUpdatingItems = false
    private let rowHeight: CGFloat = 44
    var preferredHeight: CGFloat { CGFloat(max(1, min(items.count, 6))) * rowHeight + 12 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        setAccessibilityLabel("Composer suggestions")
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = false
        tableView.focusRingType = .none
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion")))
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onClick = { [weak self] row in
            guard let self, self.items.indices.contains(row) else { return }
            self.select(row)
            _ = self.acceptSelection()
        }
        tableView.setAccessibilityLabel("Composer suggestions")
        tableView.setAccessibilityHelp("Use Up and Down to choose, Return or Tab to insert, Escape to dismiss.")
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView
        addSubview(scrollView)
        emptyLabel.font = AppFont.system(12)
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.setAccessibilityLabel("No matches")
        addSubview(emptyLabel)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        // Hidden popup surfaces begin at .zero. Never pass negative inset sizes
        // into NSScrollView, whose scroller calculations can produce infinity.
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 12, bounds.height > 12 else {
            scrollView.frame = .zero
            emptyLabel.frame = .zero
            return
        }
        scrollView.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: bounds.height - 12)
        emptyLabel.frame = NSRect(x: 16, y: 18, width: max(0, bounds.width - 32), height: 18)
        let contentSize = scrollView.contentSize
        let width = contentSize.width.isFinite ? max(0, contentSize.width) : 0
        let height = contentSize.height.isFinite ? max(0, contentSize.height) : 0
        tableView.frame.size = NSSize(width: width, height: max(height, CGFloat(items.count) * rowHeight))
        tableView.tableColumns.first?.width = width
    }

    /// Does not change visibility; the pane positions and shows this above its composer.
    func update(_ items: [AgentComposerSuggestion], theme: AppTheme) {
        let selectedID = self.items.indices.contains(selectedIndex) ? self.items[selectedIndex].id : nil
        // reloadData can synchronously select the old numeric row and notify the
        // delegate. Preserve identity across the entire reload/selection transaction.
        isUpdatingItems = true
        defer { isUpdatingItems = false }
        self.items = items
        self.theme = theme
        layer?.backgroundColor = theme.floating.cgColor
        layer?.borderColor = theme.border.cgColor
        emptyLabel.textColor = theme.fgMuted
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
        selectedIndex = selectedID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? (items.isEmpty ? -1 : 0)
        tableView.reloadData()
        if selectedIndex >= 0 { select(selectedIndex) }
        needsLayout = true
    }

    @discardableResult
    func moveSelection(_ delta: Int) -> Bool {
        guard !items.isEmpty else { return false }
        let current = selectedIndex >= 0 ? selectedIndex : 0
        let step = delta % items.count
        select((current + step + items.count) % items.count)
        return true
    }

    @discardableResult
    func acceptSelection() -> Bool {
        guard items.indices.contains(selectedIndex) else { return false }
        onSelect?(items[selectedIndex])
        return true
    }

    func dismiss() { isHidden = true; onDismiss?() }

    /// Call before send handling in NSTextViewDelegate.doCommandBy. Return and
    /// Tab are consumed even with an empty/loading menu, never accidentally sent.
    @discardableResult
    func handleCommand(_ selector: Selector) -> Bool {
        guard !isHiddenOrHasHiddenAncestor else { return false }
        switch NSStringFromSelector(selector) {
        case "moveUp:": _ = moveSelection(-1)
        case "moveDown:": _ = moveSelection(1)
        case "insertTab:", "insertNewline:": _ = acceptSelection()
        case "cancelOperation:": dismiss()
        default: return false
        }
        return true
    }

    private func select(_ row: Int) {
        selectedIndex = row
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        tableView.enumerateAvailableRowViews { view, index in
            (view as? AgentComposerSuggestionRow)?.active = index == row
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = AgentComposerSuggestionRow()
        view.fill = theme.selection
        view.active = row == selectedIndex
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingItems else { return }
        if items.indices.contains(tableView.selectedRow) { selectedIndex = tableView.selectedRow }
        tableView.enumerateAvailableRowViews { view, index in
            (view as? AgentComposerSuggestionRow)?.active = index == self.selectedIndex
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("suggestion-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? AgentComposerSuggestionCell
            ?? AgentComposerSuggestionCell()
        cell.identifier = identifier
        cell.configure(items[row], theme: theme)
        return cell
    }
}

@MainActor
final class AgentComposerSuggestionTable: NSTableView {
    var onClick: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onClick?(row) }
    }
}

@MainActor
private final class AgentComposerSuggestionRow: NSTableRowView {
    var fill = NSColor.selectedContentBackgroundColor
    var active = false { didSet { needsDisplay = true } }
    override func drawBackground(in dirtyRect: NSRect) {
        guard active else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

@MainActor
private final class AgentComposerSuggestionCell: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for child in [icon, titleLabel, subtitleLabel] as [NSView] { addSubview(child) }
        titleLabel.font = AppFont.system(13)
        subtitleLabel.font = AppFont.system(11)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        subtitleLabel.maximumNumberOfLines = 1
        icon.imageScaling = .scaleProportionallyDown
        setAccessibilityElement(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    func configure(_ item: AgentComposerSuggestion, theme: AppTheme) {
        titleLabel.stringValue = item.title
        titleLabel.textColor = theme.fg
        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.textColor = theme.fgMuted
        subtitleLabel.isHidden = item.subtitle.isEmpty
        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        icon.contentTintColor = theme.fgMuted
        toolTip = [item.title, item.subtitle].filter { !$0.isEmpty }.joined(separator: " — ")
        setAccessibilityLabel("\(item.title), \(item.kind.rawValue)\(item.subtitle.isEmpty ? "" : ", \(item.subtitle)")")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let width = max(0, bounds.width - 48)
        titleLabel.frame = NSRect(x: 36, y: subtitleLabel.isHidden ? 13 : 5, width: width, height: 18)
        subtitleLabel.frame = NSRect(x: 36, y: 23, width: width, height: 15)
    }
}
