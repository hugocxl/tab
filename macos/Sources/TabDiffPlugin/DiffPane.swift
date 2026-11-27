import AppKit
import TabApp
import TabCore
import TabProtocol

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
