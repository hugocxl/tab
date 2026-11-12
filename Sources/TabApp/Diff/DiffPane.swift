import AppKit
import TabCore
import TabProtocol

/// What a diff pane needs from the app.
@MainActor
public protocol DiffHost: NativeHost {
    /// The monospaced font from the terminal settings; see `NativeStyle.codeFont`.
    var codeFont: NSFont { get }
}

/// A pane showing one file's working tree or staged diff: hunk headers,
/// added and removed lines tinted, line numbers, unified or split, with
/// horizontal scrolling. One controller per project, path and side; look an
/// open one up with `existing(project:path:staged:)` to reuse its pane.
@MainActor
public final class DiffPaneController: NSViewController {
    /// Diffs longer than this many lines are cut short by the server.
    public static let lineLimit: UInt32 = 100_000

    public weak var host: DiffHost?
    public let path: String
    public let staged: Bool
    public private(set) var document: DiffDocument?
    private var error: String?
    private var stale = true
    private var isSplit = false

    private let background = ThemedBackground(color: { $0.card })
    private let pathLabel = makeLabel("", font: AppFont.header)
    private let addedLabel = makeLabel("", font: AppFont.header)
    private let removedLabel = makeLabel("", font: AppFont.header)
    private let sideLabel = makeLabel("", font: AppFont.body)
    private let mode = SegmentedPill(["Unified", "Split"], selected: 0)
    private let message = NativeMessageView("Loading…")
    private let note = makeLabel("Diff truncated — additional changes are not shown.", font: AppFont.footnote)
    private let scroll = NSScrollView()
    let rowsView = DiffRowsView()

    private static let open = NSMapTable<NSString, DiffPaneController>.strongToWeakObjects()

    public init(host: DiffHost, path: String, staged: Bool) {
        self.host = host
        self.path = path
        self.staged = staged
        super.init(nibName: nil, bundle: nil)
        Self.open.setObject(self, forKey: Self.key(project: host.nativeProject.id, path: path, staged: staged))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func key(project: ProjectId, path: String, staged: Bool) -> NSString {
        "\(project.uuid.uuidString)\u{0}\(staged)\u{0}\(path)" as NSString
    }

    /// The open diff pane for this file and side, to reuse instead of opening another.
    public static func existing(project: ProjectId, path: String, staged: Bool) -> DiffPaneController? {
        open.object(forKey: key(project: project, path: path, staged: staged))
    }

    public override func loadView() {
        let theme = host?.theme ?? .shared
        background.theme = theme
        view = background
        pathLabel.stringValue = path
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sideLabel.stringValue = staged ? "Staged" : "Unstaged"
        mode.onChange = { [weak self] index in self?.setSplit(index == 1) }
        let header = NSStackView(views: [pathLabel, addedLabel, removedLabel, sideLabel, mode])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Metrics.controlGap
        header.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gutter, bottom: 0, right: Metrics.gutter)

        rowsView.theme = theme
        scroll.documentView = rowsView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        message.theme = theme
        note.isHidden = true

        let stack = NSStackView(views: [header, message, scroll, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        note.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Metrics.gutter).isActive = true
        themeDidChange()
        background.onColorsChange = { [weak self] in self?.themeDidChange() }
        render()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if stale || document == nil { refresh() }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        rowsView.fitWidth(scroll.contentSize.width)
    }

    // MARK: Events from the app

    /// The repository changed: reads the diff again when shown, else on the
    /// next showing.
    public func gitChanged() {
        guard isViewLoaded, view.window != nil else {
            stale = true
            return
        }
        refresh()
    }

    /// The side connection opened again: its repository watch is gone.
    public func reconnected() {
        guard isViewLoaded, view.window != nil else {
            stale = true
            return
        }
        didShow()
    }

    /// The pane is on screen again, or for the first time: watches the
    /// repository and reads the diff if it changed while hidden.
    public func didShow() {
        host?.watchRepository()
        if stale || document == nil { refresh() }
    }

    public func themeDidChange() {
        let theme = background.theme
        pathLabel.textColor = theme.fg
        addedLabel.textColor = theme.diffAdd
        removedLabel.textColor = theme.diffRemove
        sideLabel.textColor = theme.fgMuted
        note.textColor = theme.fgMuted
        codeFontDidChange()
    }

    /// The terminal font changed.
    public func codeFontDidChange() {
        rowsView.font = host?.codeFont ?? AppFont.mono(12)
        rowsView.fitWidth(scroll.contentSize.width)
    }

    // MARK: Requests

    /// Reads the diff again.
    public func refresh() {
        stale = false
        guard let host else { return }
        guard let transport = host.nativeTransport else {
            if document == nil {
                error = "Connect to the server to see this diff."
                render()
            }
            return
        }
        let request = GitRequest(project: host.nativeProject.id, action: .diff(GitDiffRequest(
            path: ServerPath(path), staged: staged, lineLimit: Self.lineLimit, context: 1_000_000
        )))
        let language = SyntaxLanguage.detect(fileName: path)
        Task { [weak self] in
            do {
                guard case .diff(let diff) = try await transport.git(request) else { return }
                // Highlighting a long diff takes a while: keep it off the main thread.
                let document = await Task.detached(priority: .userInitiated) { DiffDocument(diff, language: language) }.value
                self?.received(document)
            } catch {
                self?.error = NativeErrors.friendly(error, folder: false)
                self?.render()
            }
        }
    }

    func received(_ document: DiffDocument) {
        error = nil
        self.document = document
        render()
    }

    private func setSplit(_ split: Bool) {
        guard split != isSplit else { return }
        isSplit = split
        rowsView.split = split
        rowsView.fitWidth(scroll.contentSize.width)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func render() {
        guard isViewLoaded else { return }
        addedLabel.stringValue = "+\(document?.diff.additions ?? 0)"
        removedLabel.stringValue = "−\(document?.diff.deletions ?? 0)"
        let text: String?
        if let document {
            if document.diff.binary {
                text = "Binary file — no text diff available."
            } else if document.rows.isEmpty {
                text = "No changes to display."
            } else {
                text = nil
            }
        } else {
            text = error ?? "Loading…"
        }
        message.set(text ?? "")
        message.isHidden = text == nil
        scroll.isHidden = text != nil
        note.isHidden = document?.diff.truncated != true
        rowsView.document = document
        rowsView.fitWidth(scroll.contentSize.width)
    }
}

/// Draws the visible diff rows only: tinted backgrounds, dim line numbers,
/// markers and syntax-colored source text in the code font, clipped to the
/// visible columns.
final class DiffRowsView: ThemedView {
    var document: DiffDocument? { didSet { reviewSelection = nil; reviewAnchor = nil; reviewHead = nil; needsDisplay = true } }
    var reviewEnabled = false
    var onReviewSelection: (() -> Void)?
    var reviewSelection: DiffReviewSelection? { didSet { needsDisplay = true; onReviewSelection?() } }
    private var reviewAnchor: Int?
    private var reviewHead: Int?
    var split = false { didSet { needsDisplay = true } }
    var font: NSFont = AppFont.mono(12) {
        didSet {
            cell = NativeStyle.cell(font)
            tokenAttributes = Self.tokenAttributes(theme: theme, font: font)
            needsDisplay = true
        }
    }
    private(set) var cell = NativeStyle.cell(AppFont.mono(12))
    private var visibleWidth: CGFloat = 0
    private var tokenAttributes: [TokenKind: [NSAttributedString.Key: Any]] = [:]

    override func themeDidChange() {
        tokenAttributes = Self.tokenAttributes(theme: theme, font: font)
        needsDisplay = true
    }

    private static func tokenAttributes(theme: AppTheme, font: NSFont) -> [TokenKind: [NSAttributedString.Key: Any]] {
        let colors = theme.syntaxColors
        var attributes: [TokenKind: [NSAttributedString.Key: Any]] = [:]
        for kind in TokenKind.allCases {
            attributes[kind] = [.font: font].merging(colors.attributes(kind, font: font)) { $1 }
        }
        return attributes
    }

    override var acceptsFirstResponder: Bool { true }

    func reviewRow(at point: NSPoint) -> (index: Int, old: Bool)? {
        guard let document, cell.height > 0, point.y >= 0 else { return nil }
        let index = Int(point.y / cell.height)
        if split {
            guard document.split.indices.contains(index) else { return nil }
            let old = point.x < bounds.width / 2
            guard let row = old ? document.split[index].left : document.split[index].right,
                  (old ? document.rows[row].oldLineNumber : document.rows[row].newLineNumber) != nil else { return nil }
            return (row, old)
        }
        guard document.rows.indices.contains(index), document.rows[index].kind != .hunk else { return nil }
        let row = document.rows[index]
        let old = row.kind == .deletion || (row.kind == .context && point.x < Metrics.gutter + CGFloat(document.numberColumns) * cell.width)
        guard (old ? row.oldLineNumber : row.newLineNumber) != nil else { return nil }
        return (index, old)
    }

    override func mouseDown(with event: NSEvent) {
        guard reviewEnabled, let row = reviewRow(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event); return
        }
        window?.makeFirstResponder(self)
        if !event.modifierFlags.contains(.shift) || reviewSelection?.old != row.old { reviewAnchor = row.index }
        let anchor = reviewAnchor ?? row.index
        reviewHead = row.index
        reviewSelection = .init(rows: min(anchor, row.index)...max(anchor, row.index), old: row.old)
    }

    override func mouseDragged(with event: NSEvent) {
        guard reviewEnabled, let anchor = reviewAnchor,
              let row = reviewRow(at: convert(event.locationInWindow, from: nil)), row.old == reviewSelection?.old else { return }
        reviewHead = row.index
        reviewSelection = .init(rows: min(anchor, row.index)...max(anchor, row.index), old: row.old)
        autoscroll(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard reviewEnabled else { super.keyDown(with: event); return }
        interpretKeyEvents([event])
    }
    override func moveUp(_ sender: Any?) { moveReview(-1, extend: false) }
    override func moveDown(_ sender: Any?) { moveReview(1, extend: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { moveReview(-1, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { moveReview(1, extend: true) }
    override func moveLeft(_ sender: Any?) { selectReviewSide(old: true) }
    override func moveRight(_ sender: Any?) { selectReviewSide(old: false) }

    private func selectReviewSide(old: Bool) {
        guard let selection = reviewSelection, let document else { return }
        let current = reviewHead ?? selection.rows.lowerBound
        guard let pair = document.split.first(where: { $0.left == current || $0.right == current }),
              let target = old ? pair.left : pair.right,
              (old ? document.rows[target].oldLineNumber : document.rows[target].newLineNumber) != nil else { return }
        reviewAnchor = target
        reviewHead = target
        reviewSelection = .init(rows: target...target, old: old)
    }

    private func moveReview(_ delta: Int, extend: Bool) {
        guard let document else { return }
        let old = reviewSelection?.old ?? false
        let current = reviewHead ?? reviewSelection.map { delta < 0 ? $0.rows.lowerBound : $0.rows.upperBound }
        var next = current.map { $0 + delta } ?? (delta > 0 ? 0 : document.rows.count - 1)
        while document.rows.indices.contains(next) {
            if (old ? document.rows[next].oldLineNumber : document.rows[next].newLineNumber) != nil {
                let anchor = extend ? (reviewAnchor ?? next) : next
                reviewAnchor = anchor
                reviewHead = next
                reviewSelection = .init(rows: min(anchor, next)...max(anchor, next), old: old)
                let visual = split ? document.split.firstIndex(where: { (old ? $0.left : $0.right) == next }) ?? 0 : next
                scrollToVisible(NSRect(x: visibleRect.minX, y: CGFloat(visual) * cell.height, width: 1, height: cell.height))
                return
            }
            next += delta
        }
    }

    /// Sizes the view to its rows and widest line, at least `width` wide.
    func fitWidth(_ width: CGFloat) {
        visibleWidth = width
        guard let document else {
            setFrameSize(NSSize(width: width, height: 0))
            return
        }
        let columns = CGFloat(document.totalColumns(split: split)) * (split ? 2 : 1)
        let contentWidth = columns * cell.width + Metrics.gutter * 2
        let height = CGFloat(document.rowCount(split: split)) * cell.height + Metrics.gutter
        setFrameSize(NSSize(width: max(contentWidth, width), height: height))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let document, cell.height > 0 else { return }
        let count = document.rowCount(split: split)
        let first = max(Int(dirtyRect.minY / cell.height), 0)
        let last = min(Int((dirtyRect.maxY / cell.height).rounded(.up)), count)
        guard first < last else { return }
        let half = bounds.width / 2
        for index in first..<last {
            let y = CGFloat(index) * cell.height
            if split {
                let pair = document.split[index]
                drawCell(pair.left, old: true, unified: false,
                         frame: NSRect(x: 0, y: y, width: half, height: cell.height), dirty: dirtyRect, document: document)
                drawCell(pair.right, old: false, unified: false,
                         frame: NSRect(x: half, y: y, width: half, height: cell.height), dirty: dirtyRect, document: document)
            } else {
                drawCell(index, old: document.rows[index].kind == .deletion, unified: true,
                         frame: NSRect(x: 0, y: y, width: bounds.width, height: cell.height), dirty: dirtyRect, document: document)
            }
        }
    }

    private func drawCell(_ index: Int?, old: Bool, unified: Bool, frame: NSRect, dirty: NSRect, document: DiffDocument) {
        guard let index else { return }
        let row = document.rows[index]
        switch row.kind {
        case .addition:
            theme.diffAdd.withAlphaComponent(0.12).setFill()
            frame.intersection(dirty).fill()
        case .deletion:
            theme.diffRemove.withAlphaComponent(0.12).setFill()
            frame.intersection(dirty).fill()
        default:
            break
        }
        if reviewEnabled, let selection = reviewSelection, selection.rows.contains(index),
           unified || selection.old == old {
            theme.accent.withAlphaComponent(0.18).setFill()
            frame.intersection(dirty).fill()
        }
        let origin = frame.minX + Metrics.gutter
        let firstColumn = max(Int((max(dirty.minX, frame.minX) - origin) / cell.width), 0)
        let lastColumn = Int(((min(dirty.maxX, frame.maxX) - origin) / cell.width).rounded(.up)) + 1
        guard lastColumn > firstColumn else { return }
        let color = row.kind == .hunk ? theme.diffHunk : theme.fg
        let baseline = frame.minY + (cell.height - (font.ascender - font.descender)) / 2
        let segments = DiffDocument.segments(row, old: old, unified: unified, numberColumns: document.numberColumns)
        for (position, segment) in segments.enumerated() {
            guard let (column, text) = DiffDocument.visible(segment, first: firstColumn, last: lastColumn) else { continue }
            let point = NSPoint(x: origin + CGFloat(column) * cell.width, y: baseline)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: segment.dim ? theme.fgDim : color]
            let runs = position == segments.count - 1 ? document.runs(index, old: old) : []
            guard !runs.isEmpty else {
                (text as NSString).draw(at: point, withAttributes: attributes)
                continue
            }
            let colored = NSMutableAttributedString()
            for piece in DiffDocument.colored(text, skip: column - segment.column, runs: runs) {
                colored.append(NSAttributedString(string: String(piece.text), attributes: piece.kind.flatMap { tokenAttributes[$0] } ?? attributes))
            }
            colored.draw(at: point)
        }
    }
}
