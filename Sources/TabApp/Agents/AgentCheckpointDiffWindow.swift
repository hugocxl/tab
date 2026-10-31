import AppKit
import TabProtocol

/// Historical diffs are fetched by checkpoint identity, never from the current worktree.
@MainActor
final class AgentCheckpointDiffWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias Fetch = (AgentCheckpointRequest) async throws -> AgentCheckpointReply
    private let session: SessionId
    private let checkpoint: String
    private let fetch: Fetch
    private let surface = AgentCheckpointDiffSurface(frame: .zero)
    private var files: [AgentTurnCheckpoint.File] = []
    private var loadTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectedPath: String?
    private var selectionGeneration = 0
    var onClose: (() -> Void)?

    init(session: SessionId, checkpoint: String, path: String?, theme: AppTheme, fetch: @escaping Fetch) {
        self.session = session; self.checkpoint = checkpoint; self.fetch = fetch
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Turn changes"
        window.minSize = NSSize(width: 600, height: 360)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.delegate = self
        surface.theme = theme
        surface.themeDidChange()
        surface.files.dataSource = self
        surface.files.delegate = self
        surface.retry.onPress = { [weak self] in
            guard let self else { return }
            if self.files.isEmpty { self.load(path: path) }
            else if let selected = self.selectedPath { self.select(selected) }
        }
        window.center()
        load(path: path)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func load(path: String?) {
        loadTask?.cancel()
        surface.showMessage("Loading changed files…")
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                var offset = 0
                var loaded: [AgentTurnCheckpoint.File] = []
                while true {
                    let reply = try await fetch(.init(session: session, checkpoint: checkpoint, offset: offset))
                    try Task.checkCancellation()
                    loaded += reply.files
                    guard let next = reply.nextOffset else { break }
                    guard next > offset else { throw NSError(domain: "AgentCheckpoint", code: 1, userInfo: [NSLocalizedDescriptionKey: "The server returned an invalid checkpoint page."]) }
                    offset = next
                }
                files = loaded
                surface.files.reloadData()
                guard let selected = path.flatMap({ wanted in self.files.first { $0.path == wanted }?.path }) ?? files.first?.path else {
                    surface.showMessage("No changed files in this turn."); return
                }
                if let index = files.firstIndex(where: { $0.path == selected }) {
                    surface.files.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                }
            } catch is CancellationError {} catch { surface.showMessage(error.localizedDescription, retry: true) }
        }
    }
    private func select(_ path: String) {
        selectedPath = path
        selectionGeneration += 1
        let generation = selectionGeneration
        selectionTask?.cancel()
        surface.path.stringValue = path
        surface.showMessage("Loading diff…")
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await fetch(.init(session: session, checkpoint: checkpoint, path: path))
                try Task.checkCancellation()
                guard generation == selectionGeneration, let diff = reply.diff else { return }
                surface.setDiff(diff)
            } catch is CancellationError {} catch {
                guard generation == selectionGeneration else { return }
                surface.showMessage(error.localizedDescription, retry: true)
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { files.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard files.indices.contains(row) else { return nil }
        let label = makeLabel(files[row].path, font: AppFont.mono(12))
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = files[row].path
        label.textColor = surface.theme.fg
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = surface.files.selectedRow
        if files.indices.contains(row) { select(files[row].path) }
    }
    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel(); selectionTask?.cancel()
        onClose?()
    }
}

@MainActor
private final class AgentCheckpointDiffSurface: ThemedView {
    let files = NSTableView()
    let path = makeLabel("", font: AppFont.small)
    let retry = PillButton("Retry", style: .normal)
    private let counts = makeLabel("", font: AppFont.small)
    private let message = makeLabel("", font: AppFont.body)
    private let note = makeLabel("Diff preview truncated.", font: AppFont.footnote)
    private let mode = SegmentedPill(["Unified", "Split"], selected: 0)
    private let fileScroll = NSScrollView()
    private let diffScroll = NSScrollView()
    private let rows = DiffRowsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        files.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path")))
        files.headerView = nil
        files.rowHeight = 28
        files.backgroundColor = .clear
        files.usesAlternatingRowBackgroundColors = false
        fileScroll.documentView = files
        diffScroll.documentView = rows
        for scroll in [fileScroll, diffScroll] {
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        }
        diffScroll.hasHorizontalScroller = true
        path.lineBreakMode = .byTruncatingMiddle
        for child in [fileScroll, diffScroll, path, counts, message, note, mode, retry] {
            child.translatesAutoresizingMaskIntoConstraints = true; addSubview(child)
        }
        mode.onChange = { [weak self] index in
            guard let self else { return }
            self.rows.split = index == 1
            self.diffScroll.contentView.scroll(to: .zero)
            self.needsLayout = true
        }
        note.isHidden = true
        retry.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func showMessage(_ text: String, retry: Bool = false) {
        message.stringValue = text; message.isHidden = false
        diffScroll.isHidden = true; note.isHidden = true
        self.retry.isHidden = !retry
        counts.stringValue = ""
    }
    func setDiff(_ diff: GitDiff) {
        counts.attributedStringValue = AgentChangedFilesRow.stat(diff.additions, diff.deletions, font: AppFont.small)
        if diff.binary { showMessage("Binary file changed."); return }
        message.isHidden = true; retry.isHidden = true
        diffScroll.isHidden = false; note.isHidden = !diff.truncated
        rows.document = DiffDocument(diff)
        diffScroll.contentView.scroll(to: .zero)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let sidebar: CGFloat = min(260, bounds.width * 0.28)
        fileScroll.frame = NSRect(x: 0, y: 0, width: sidebar, height: bounds.height)
        files.tableColumns.first?.width = max(1, sidebar - 10)
        let left = sidebar + 12
        let width = max(1, bounds.width - left - 12)
        path.frame = NSRect(x: left, y: 10, width: max(1, width - 240), height: 20)
        counts.frame = NSRect(x: max(left, bounds.width - 250), y: 10, width: 90, height: 20)
        mode.frame = NSRect(x: max(left, bounds.width - 152), y: 5, width: 140, height: 28)
        diffScroll.frame = NSRect(x: left, y: 40, width: width, height: max(1, bounds.height - 40 - (note.isHidden ? 0 : 24)))
        rows.fitWidth(diffScroll.contentSize.width)
        message.frame = NSRect(x: left + 12, y: 64, width: max(1, width - 24), height: 44)
        retry.frame = NSRect(x: left + 12, y: 116, width: 70, height: 28)
        note.frame = NSRect(x: left, y: bounds.height - 22, width: width, height: 20)
    }
    override func themeDidChange() {
        wantsLayer = true; layer?.backgroundColor = theme.card.cgColor
        rows.theme = theme; rows.themeDidChange()
        path.textColor = theme.fg; message.textColor = theme.fgMuted; note.textColor = theme.fgDim
        files.reloadData()
    }
}
