import AppKit
import TabProtocol

/// Historical diffs are fetched by checkpoint identity, never from the current worktree.
@MainActor
final class AgentCheckpointDiffWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias Fetch = (AgentCheckpointRequest) async throws -> AgentCheckpointReply
    private let session: SessionId
    private let checkpoint: String
    var checkpointID: String { checkpoint }
    private let fetch: Fetch
    private let surface = AgentCheckpointDiffSurface(frame: .zero)
    private var files: [AgentTurnCheckpoint.File] = []
    private var loadTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectedPath: String?
    private var selectionGeneration = 0
    /// Unchanged lines around each change, read from the checkpoint's own files.
    private(set) var context = AgentCheckpointDiffWindow.contextSteps[0]
    /// The server reads more context; false once one that predates it answered.
    private var contextSupported = true
    /// Whether the diffs come from a checkpoint, which can show more context.
    var expandsContext = true { didSet { updateContextControl() } }
    /// A comment chosen in the picker, shown once its file's diff arrives.
    private var pendingReveal: AgentReviewComment?
    /// Context levels More Context steps through: the usual three lines, more, the whole file.
    static let contextSteps = [3, 25, AgentCheckpointRequest.wholeFile]
    var onClose: (() -> Void)?
    var onReviewChange: (([AgentReviewComment]) -> Void)? {
        didSet {
            surface.setReviewEnabled(onReviewChange != nil)
            window?.minSize = NSSize(width: onReviewChange == nil ? 600 : 680, height: 360)
        }
    }
    var onDraftReview: (() throws -> Void)?
    /// Opens the file in the editor at a line of the diff.
    var onOpenFile: ((String, Int?) -> Void)? { didSet { surface.openInEditor.isHidden = onOpenFile == nil } }
    var reviewComments: [AgentReviewComment] = [] {
        didSet {
            surface.updateReviewCount(reviewComments.count)
            updateReviewMarks()
        }
    }
    private var commentEditor: AgentTextEditorSheet?
    private var commentPicker: AgentSearchPicker?

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
        surface.addComment.onPress = { [weak self] in self?.addComment() }
        surface.moreContext.onPress = { [weak self] in self?.showMoreContext() }
        surface.rows.onReviewSelection = { [weak self] in self?.reviewSelectionChanged() }
        surface.openInEditor.onPress = { [weak self] in self?.openSelectionInEditor() }
        surface.reviewComments.onPress = { [weak self] in self?.showComments() }
        surface.draftReview.onPress = { [weak self] in
            do { try self?.onDraftReview?() }
            catch {
                guard let self, let window = self.window else { return }
                let alert = NSAlert()
                alert.messageText = "Could not add comments to the draft"
                alert.informativeText = error.localizedDescription
                alert.window.appearance = self.surface.theme.nsAppearance
                alert.beginSheetModal(for: window)
            }
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
        if selectedPath != path { context = Self.contextSteps[0] }
        selectedPath = path
        selectionGeneration += 1
        let generation = selectionGeneration
        selectionTask?.cancel()
        surface.path.stringValue = path
        surface.showMessage("Loading diff…")
        updateReviewMarks()
        let wanted = context
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await fetch(.init(session: session, checkpoint: checkpoint, path: path,
                                                  context: wanted == Self.contextSteps[0] ? nil : wanted))
                try Task.checkCancellation()
                guard generation == selectionGeneration, let diff = reply.diff else { return }
                if wanted != Self.contextSteps[0], reply.context == nil {
                    contextSupported = false
                    context = Self.contextSteps[0]
                }
                surface.setDiff(diff)
                updateContextControl()
                updateReviewMarks()
                revealPending()
            } catch is CancellationError {} catch {
                guard generation == selectionGeneration else { return }
                surface.showMessage(error.localizedDescription, retry: true)
            }
        }
    }
    /// Shows more unchanged lines around the changes, from the checkpoint's own files.
    func showMoreContext() {
        guard contextSupported, expandsContext, let path = selectedPath,
              let next = Self.contextSteps.first(where: { $0 > context }) else { return }
        context = next
        select(path)
    }

    private func updateContextControl() {
        let button = surface.moreContext
        let whole = context >= AgentCheckpointRequest.wholeFile
        button.isHidden = surface.rows.document == nil || !expandsContext
        button.isEnabled = contextSupported && !whole
        button.title = whole ? "Whole file" : "More context"
        button.toolTip = !contextSupported ? "This server can't show more context. Update Tab on it, then restart it."
            : whole ? "Showing every line of the file as this turn left it" : "Show more unchanged lines around each change, as they were at this turn"
        surface.needsLayout = true
    }

    private func updateReviewMarks() {
        surface.rows.reviewMarks = reviewComments.filter { $0.path == selectedPath }.map(\.mark)
        reviewSelectionChanged()
    }

    /// The saved comment the selection covers exactly, which Add Comment then edits.
    private var selectedComment: AgentReviewComment? {
        guard let path = selectedPath, let document = surface.rows.document, let selection = surface.rows.reviewSelection,
              let lines = selection.lines(in: document) else { return nil }
        return reviewComments.first { $0.path == path && $0.old == selection.old && $0.firstLine == lines.first && $0.lastLine == lines.last }
    }

    private func reviewSelectionChanged() {
        surface.updateReviewSelection(editing: selectedComment != nil)
    }

    /// Opens the comment's file, selects its lines on its side and scrolls to them. Lines
    /// the diff leaves out are loaded with more context; a truncated diff says so.
    func reveal(_ comment: AgentReviewComment) {
        pendingReveal = comment
        if comment.path != selectedPath, let index = files.firstIndex(where: { $0.path == comment.path }) {
            surface.files.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            surface.files.scrollRowToVisible(index)
            return
        }
        if surface.rows.document != nil { revealPending() }
    }

    private func revealPending() {
        guard let comment = pendingReveal, comment.path == selectedPath, surface.rows.document != nil else { return }
        if let rows = surface.rows.rows(for: comment.mark) {
            pendingReveal = nil
            surface.rows.reveal(rows, old: comment.old)
            window?.makeFirstResponder(surface.rows)
            return
        }
        if contextSupported, expandsContext, context < AgentCheckpointRequest.wholeFile, let path = selectedPath {
            context = AgentCheckpointRequest.wholeFile
            select(path)
            return
        }
        pendingReveal = nil
        surface.showNote("This comment's lines aren't in the diff preview" + (surface.rows.document?.diff.truncated == true ? ", which is truncated." : "."))
    }

    /// The selected line on the new side, else the diff's first changed line.
    private func openSelectionInEditor() {
        guard let path = selectedPath else { return }
        let document = surface.rows.document
        var line: UInt64?
        if let document, let selection = surface.rows.reviewSelection, !selection.old {
            line = selection.lines(in: document)?.first
        }
        line = line ?? document?.rows.first { $0.kind == .addition || $0.kind == .context }?.newLineNumber
        onOpenFile?(path, line.map { Int(clamping: $0) })
    }

    private func addComment() {
        if let existing = selectedComment { editComment(existing, existing: true); return }
        guard let path = selectedPath, let document = surface.rows.document,
              let selection = surface.rows.reviewSelection, let lines = selection.lines(in: document) else { return }
        editComment(AgentReviewComment(checkpoint: checkpoint, path: path, old: selection.old,
                                      firstLine: lines.first, lastLine: lines.last, source: lines.source, text: ""), existing: false)
    }

    private func showComments() {
        guard commentEditor == nil else { return }
        commentPicker?.close()
        let picker = AgentSearchPicker(title: "Review comments", placeholder: "Search comments or files…", theme: surface.theme)
        picker.update(reviewComments.map { .init(id: $0.id, title: $0.text, detail: $0.location) },
                      note: "Choose a comment to show its lines; Edit Comment then changes or deletes it. Comments are saved with the conversation draft.")
        picker.onSelect = { [weak self] id in
            guard let self, let comment = self.reviewComments.first(where: { $0.id == id }) else { return }
            self.reveal(comment)
        }
        picker.onClose = { [weak self] in self?.commentPicker = nil }
        commentPicker = picker
        picker.present(in: window)
    }

    private func editComment(_ comment: AgentReviewComment, existing: Bool) {
        guard commentEditor == nil, let window else { return }
        let editor = AgentTextEditorSheet(title: existing ? "Edit review comment" : "Add review comment",
            detail: comment.location + "\nCheckpoint: " + checkpoint,
            text: comment.text, theme: surface.theme, allowsDelete: existing)
        commentEditor = editor
        editor.present(in: window) { [weak self] response, text, _ in
            guard let self else { return }
            self.commentEditor = nil
            var comments = self.reviewComments
            if response == .alertThirdButtonReturn {
                comments.removeAll { $0.id == comment.id }
            } else if response == .alertFirstButtonReturn, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var edited = comment
                edited.text = text
                if let index = comments.firstIndex(where: { $0.id == comment.id }) { comments[index] = edited }
                else { comments.append(edited) }
            } else { return }
            self.onReviewChange?(comments)
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
        commentEditor?.close(); commentPicker?.close()
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
    let rows = DiffRowsView()
    let addComment = PillButton("Add comment", style: .plain)
    let moreContext = PillButton("More context", style: .plain)
    let openInEditor = PillButton("Open in Editor", style: .plain)
    let reviewComments = PillButton("Comments", style: .plain)
    let draftReview = PillButton("Add comments to draft", style: .normal)
    private var reviewEnabled = false

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
        openInEditor.isHidden = true
        openInEditor.toolTip = "Open this file at the selected line"
        moreContext.isHidden = true
        moreContext.setAccessibilityLabel("Show more context")
        for child in [fileScroll, diffScroll, path, counts, message, note, mode, retry, addComment, reviewComments, draftReview, openInEditor, moreContext] {
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
        setReviewEnabled(false)
        rows.setAccessibilityElement(true)
        rows.setAccessibilityRole(.textArea)
        rows.setAccessibilityLabel("Historical diff. Use arrows to select lines, Shift-Up or Shift-Down to extend, and Left or Right to choose old or new lines.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func showMessage(_ text: String, retry: Bool = false) {
        rows.document = nil
        updateReviewSelection(editing: false)
        message.stringValue = text; message.isHidden = false
        diffScroll.isHidden = true; note.isHidden = true
        self.retry.isHidden = !retry
        moreContext.isHidden = true
        counts.stringValue = ""
    }
    /// A line under the diff, as for a comment it can't show.
    func showNote(_ text: String) {
        note.stringValue = text
        note.isHidden = false
        needsLayout = true
    }
    func setDiff(_ diff: GitDiff) {
        counts.attributedStringValue = AgentChangedFilesRow.stat(diff.additions, diff.deletions, font: AppFont.small, theme: theme)
        if diff.binary { showMessage("Binary file changed."); return }
        message.isHidden = true; retry.isHidden = true
        note.stringValue = "Diff preview truncated."
        diffScroll.isHidden = false; note.isHidden = !diff.truncated
        rows.document = DiffDocument(diff)
        diffScroll.contentView.scroll(to: .zero)
        needsLayout = true
    }
    func setReviewEnabled(_ enabled: Bool) {
        reviewEnabled = enabled
        rows.reviewEnabled = enabled
        for button in [addComment, reviewComments, draftReview] { button.isHidden = !enabled }
        updateReviewSelection(editing: false)
        needsLayout = true
    }
    func updateReviewCount(_ count: Int) {
        reviewComments.title = "Comments (\(count))"
        reviewComments.isEnabled = count > 0
        draftReview.isEnabled = count > 0
    }
    func updateReviewSelection(editing: Bool) {
        let lines = rows.document.flatMap { rows.reviewSelection?.lines(in: $0) }
        addComment.isEnabled = reviewEnabled && lines != nil
        addComment.title = editing ? "Edit comment" : "Add comment"
        addComment.toolTip = editing ? "Change or delete the comment on these lines"
            : lines.map { "Comment on lines \($0.first)–\($0.last)" } ?? "Select lines in the diff first"
        let commented = rows.markedOld.count + rows.markedNew.count > 0 ? " Commented lines are marked." : ""
        rows.setAccessibilityValue((lines.map { "Selected lines \($0.first) through \($0.last), \(rows.reviewSelection?.old == true ? "old" : "new") side" + (editing ? ", commented" : "") } ?? "No lines selected") + commented)
    }

    override func layout() {
        super.layout()
        let sidebar: CGFloat = min(260, bounds.width * 0.28)
        fileScroll.frame = NSRect(x: 0, y: 0, width: sidebar, height: bounds.height)
        files.tableColumns.first?.width = max(1, sidebar - 10)
        let left = sidebar + 12
        let width = max(1, bounds.width - left - 12)
        let editorWidth: CGFloat = openInEditor.isHidden ? 0 : ceil(openInEditor.fittingSize.width)
        let contextWidth: CGFloat = moreContext.isHidden ? 0 : ceil(moreContext.fittingSize.width)
        let accessories = (editorWidth > 0 ? editorWidth + 8 : 0) + (contextWidth > 0 ? contextWidth + 8 : 0)
        path.frame = NSRect(x: left, y: 10, width: max(1, width - 240 - accessories), height: 20)
        moreContext.frame = NSRect(x: max(left, bounds.width - 258 - contextWidth), y: 5, width: contextWidth, height: 28)
        openInEditor.frame = NSRect(x: max(left, bounds.width - 258 - contextWidth - (contextWidth > 0 ? 8 : 0) - editorWidth), y: 5, width: editorWidth, height: 28)
        counts.frame = NSRect(x: max(left, bounds.width - 250), y: 10, width: 90, height: 20)
        mode.frame = NSRect(x: max(left, bounds.width - 152), y: 5, width: 140, height: 28)
        diffScroll.frame = NSRect(x: left, y: 40, width: width, height: max(1, bounds.height - 40 - (note.isHidden ? 0 : 24) - (reviewEnabled ? 40 : 0)))
        rows.fitWidth(diffScroll.contentSize.width)
        message.frame = NSRect(x: left + 12, y: 64, width: max(1, width - 24), height: 44)
        retry.frame = NSRect(x: left + 12, y: 116, width: 70, height: 28)
        let footerY = bounds.height - 34
        addComment.frame = NSRect(x: left, y: footerY, width: 100, height: 28)
        reviewComments.frame = NSRect(x: left + 106, y: footerY, width: 110, height: 28)
        draftReview.frame = NSRect(x: max(left + 222, bounds.width - 190), y: footerY, width: 178, height: 28)
        note.frame = NSRect(x: left, y: bounds.height - (reviewEnabled ? 62 : 22), width: width, height: 20)
    }
    override func themeDidChange() {
        appearance = theme.nsAppearance
        window?.appearance = theme.nsAppearance
        wantsLayer = true; layer?.backgroundColor = theme.card.cgColor
        rows.theme = theme; rows.themeDidChange()
        path.textColor = theme.fg; message.textColor = theme.fgMuted; note.textColor = theme.fgDim
        files.reloadData()
    }
}
