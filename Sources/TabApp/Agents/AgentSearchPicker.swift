import AppKit

/// A searchable native list shared by conversation history, prompt navigation and review comments.
@MainActor
final class AgentSearchPicker: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Entry: Equatable {
        var id: String
        var title: String
        var detail: String
    }
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var entries: [Entry] = []
    private var footerNote = ""
    private(set) var filtered: [Entry] = []
    private let theme: AppTheme

    init(title: String, placeholder: String, theme: AppTheme) {
        self.theme = theme
        let panel = AgentSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = title
        panel.minSize = NSSize(width: 360, height: 280)
        super.init(window: panel)
        panel.onCancel = { [weak self] in self?.close() }
        panel.delegate = self
        panel.appearance = theme.nsAppearance
        let content = ThemedBackground(color: { $0.floating })
        content.theme = theme
        panel.contentView = content
        search.placeholderString = placeholder
        search.delegate = self
        search.setAccessibilityLabel(placeholder)
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil
        table.rowHeight = 48
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose)
        table.setAccessibilityLabel(title)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        note.font = AppFont.small
        note.textColor = theme.fgDim
        let open = PillButton("Open", style: .normal)
        panel.defaultButtonCell = open.cell as? NSButtonCell
        open.onPress = { [weak self] in self?.choose() }
        for view in [search, scroll, note, open] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -10),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -12),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            note.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            open.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            open.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            open.widthAnchor.constraint(equalToConstant: 60), open.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ entries: [Entry], note: String = "") {
        guard self.entries != entries || footerNote != note else { return }
        self.entries = entries
        footerNote = note
        filter()
    }

    func present(in parent: NSWindow?) {
        guard let window else { return }
        if let parent, window.sheetParent == nil { parent.beginSheet(window) }
        else { showWindow(nil) }
        window.makeFirstResponder(search)
    }

    override func close() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
    func controlTextDidChange(_ obj: Notification) { filter() }

    private func filter() {
        let selected = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil
        filtered = Self.matches(entries, query: search.stringValue)
        note.stringValue = (filtered.isEmpty ? "No results. " : "") + footerNote
        table.reloadData()
        let index = selected.flatMap { id in filtered.firstIndex { $0.id == id } } ?? 0
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        table.setAccessibilityValue(filtered.isEmpty ? "No results" : "\(filtered.count) results")
    }

    static func matches(_ entries: [Entry], query: String) -> [Entry] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return entries.filter { entry in
            words.allSatisfy { (entry.title + " " + entry.detail).range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !filtered.isEmpty else { return true }
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(filtered.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        default: return false
        }
        return true
    }

    @objc private func choose() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        let id = filtered[table.selectedRow].id
        let action = onSelect
        close()
        action?(id)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let entry = filtered[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: tableView.rowHeight))
        let title = makeLabel(entry.title, font: AppFont.body)
        let detail = makeLabel(entry.detail, font: AppFont.small)
        title.textColor = theme.fg; detail.textColor = theme.fgDim
        title.lineBreakMode = .byTruncatingTail; detail.lineBreakMode = .byTruncatingTail
        cell.addSubview(title); cell.addSubview(detail)
        title.frame = NSRect(x: 6, y: 25, width: max(0, tableView.bounds.width - 16), height: 18)
        detail.frame = NSRect(x: 6, y: 5, width: max(0, tableView.bounds.width - 16), height: 17)
        title.autoresizingMask = [.width]; detail.autoresizingMask = [.width]
        cell.toolTip = entry.title + "\n" + entry.detail
        cell.setAccessibilityElement(true)
        cell.setAccessibilityLabel(entry.title + ", " + entry.detail)
        return cell
    }
}

@MainActor
private final class AgentSearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
