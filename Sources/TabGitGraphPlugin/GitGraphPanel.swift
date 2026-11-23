import AppKit
import TabApp
import TabCore
import TabProtocol

/// The Git Graph panel pinned on the right of a project: every branch's
/// commits as a graph, newest first. History loads a page at a time as the
/// list nears its end, and the table only makes rows on screen, so long
/// histories cost nothing until they are scrolled to.
@MainActor
public final class GitGraphController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// Commits per request; the server allows up to 1,000.
    static let pageSize = 400
    /// How many rows before the end the next page starts loading.
    static let prefetchRows = 120
    /// The most commits a refresh reads again, so scrolling deep keeps its
    /// place without reading the whole history again on every change.
    static let refreshLimit = 1000

    public weak var host: GitGraphHost?
    public private(set) var model = GitGraphModel()
    private var stale = true
    private var loadingMore = false
    private var isBusy = false
    /// Increases with every reset, so a late page of the old history is dropped.
    private var generation = 0
    private var error: String?

    private let card = NativePanelCard()
    public var drawsCard: Bool {
        get { card.drawsCard }
        set { card.drawsCard = newValue }
    }

    private let footer = RightSidebarFooter()
    private var refreshButton: ChromeButton?
    private let spinner = Spinner()
    private let message = NativeMessageView("Loading history…")
    let table = NSTableView()
    private let scroll = NSScrollView()
    private var scrollFade: ScrollEdgeFade?
    private var style: GraphStyle?
    private var geometry = GraphGeometry()
    private var labelCache: [Int: [GraphRefLabel]] = [:]

    public init(host: GitGraphHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        card.theme = host?.theme ?? .shared
        view = card
        footer.title = host?.nativeProject.name ?? "Git Graph"
        footer.addButton(.locate, label: "Show HEAD") { [weak self] in self?.revealHead() }
        refreshButton = footer.addButton(.refresh, label: "Refresh") { [weak self] in self?.refresh() }
        spinner.isHidden = true
        footer.setSpinner(spinner)

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = GitGraphCell.rowHeight
        table.intercellSpacing = .zero
        table.focusRingType = .none
        table.style = .plain
        table.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Commits")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        scrollFade = ScrollEdgeFade(scroll)

        message.theme = card.theme
        card.addSubview(scroll)
        card.addSubview(message)
        card.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            message.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            message.topAnchor.constraint(equalTo: card.topAnchor),
            message.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        themeDidChange()
        card.onColorsChange = { [weak self] in self?.themeDidChange() }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if stale { refresh() }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateGeometry()
    }

    /// The panel is on screen again, or for the first time: watches the
    /// repository and reads its history.
    public func didShow() {
        host?.watchRepository()
        refresh()
    }

    public func focus() {
        view.window?.makeFirstResponder(table)
    }

    // MARK: Events from the app

    /// The repository changed on the server: refreshes when shown, else on
    /// the next showing.
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

    func themeDidChange() {
        style = GraphStyle(theme: card.theme)
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView as? GitGraphTableRowView)?.selectionColor = self.card.theme.selection
        }
        reloadVisible()
    }

    // MARK: Loading

    private var graphAction: (UInt32, UInt32) -> GitAction {
        host?.supportsGitGraph == true ? { .graph(maxCount: $0, skip: $1) } : { .log(maxCount: $0, skip: $1) }
    }

    /// Reads the summary and the first pages again, keeping the rows when
    /// nothing moved.
    public func refresh() {
        stale = false
        guard let host, let transport = host.nativeTransport else { return }
        let project = host.nativeProject.id
        let count = min(max(model.commits.count, Self.pageSize), Self.refreshLimit)
        let action = graphAction(UInt32(count), 0)
        setLoading(true)
        Task { [weak self] in
            do {
                async let summaryReply = transport.git(GitRequest(project: project, action: .summary))
                async let logReply = transport.git(GitRequest(project: project, action: action))
                let (summary, log) = try await (summaryReply, logReply)
                guard case .summary(let summaryValue) = summary else { return }
                guard case .log(let commits) = log else { return }
                self?.received(summary: summaryValue, commits: commits, requested: count)
            } catch {
                self?.showError(NativeErrors.describe(error))
            }
        }
    }

    func received(summary: GitSummary?, commits: [GitCommit], requested: Int) {
        setLoading(false)
        if error == nil, model.rowCount > 0, model.keep(summary: summary, firstPage: commits) {
            // Only the summary moved: the work-in-progress row and the branch name follow.
            if model.headRow == 0 { table.reloadData(forRowIndexes: [0], columnIndexes: [0]) }
            footer.title = model.currentBranch ?? footer.title
            return
        }
        let selectedHash = selectedCommit?.hash
        let wasAtTop = scroll.contentView.bounds.minY <= 1
        error = nil
        generation += 1
        loadingMore = false
        labelCache = [:]
        model.reset(summary: summary, commits: commits, requested: requested)
        render()
        if let selectedHash, let row = model.row(of: selectedHash) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        if wasAtTop { table.scrollRowToVisible(0) }
        loadMoreIfNeeded()
    }

    private func loadMoreIfNeeded() {
        guard !loadingMore, !model.exhausted, error == nil, model.rowCount > 0 else { return }
        let visible = table.rows(in: scroll.contentView.bounds)
        guard visible.location + visible.length + Self.prefetchRows >= model.rowCount else { return }
        guard let host, let transport = host.nativeTransport else { return }
        loadingMore = true
        let generation = generation
        let skip = model.commits.count
        let request = GitRequest(project: host.nativeProject.id, action: graphAction(UInt32(Self.pageSize), UInt32(skip)))
        Task { [weak self] in
            let reply = try? await transport.git(request)
            guard let self, self.generation == generation else { return }
            self.loadingMore = false
            guard case .log(let commits)? = reply else { return }
            let before = self.model.rowCount
            self.model.append(commits, requested: Self.pageSize)
            let after = self.model.rowCount
            if after > before {
                self.table.insertRows(at: IndexSet(before..<after), withAnimation: [])
            }
            if self.updateGeometry() == false, after > before { self.reloadVisible() }
            self.loadMoreIfNeeded()
        }
    }

    @objc private func scrolled() {
        loadMoreIfNeeded()
    }

    private func setLoading(_ loading: Bool) {
        spinner.isHidden = !loading
        refreshButton?.isHidden = loading
    }

    private func showError(_ text: String?) {
        setLoading(false)
        error = text.map { NativeErrors.friendly($0, folder: true) }
        render()
    }

    // MARK: Drawing

    private func render() {
        guard isViewLoaded else { return }
        footer.title = model.currentBranch ?? model.summary?.head.map { String($0.prefix(7)) }
            ?? host?.nativeProject.name ?? footer.title
        if let error {
            message.set(error)
            message.isHidden = false
        } else if model.rowCount == 0 {
            message.set(model.summary == nil ? "Loading history…" : "No commits yet")
            message.isHidden = false
        } else {
            message.isHidden = true
        }
        scroll.isHidden = !message.isHidden
        updateGeometry()
        table.reloadData()
    }

    /// Sizes the graph column for the widest row loaded and the panel's
    /// width; returns whether it changed and the rows were redrawn.
    @discardableResult
    private func updateGeometry() -> Bool {
        let width = scroll.contentView.bounds.width
        guard width > 0 else { return false }
        let next = GraphGeometry(lanes: model.layout.width(covering: 0.95), rowWidth: width)
        guard next != geometry else { return false }
        geometry = next
        reloadVisible()
        return true
    }

    private func reloadVisible() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                         columnIndexes: [0])
    }

    private func labels(at row: Int, for commit: GitCommit) -> [GraphRefLabel] {
        if commit.refs.isEmpty { return [] }
        if let cached = labelCache[row] { return cached }
        let labels = GraphRefLabel.labels(for: commit.refs, currentBranch: model.currentBranch)
        labelCache[row] = labels
        return labels
    }

    private func content(at row: Int) -> GraphRowContent? {
        guard row < model.rowCount else { return nil }
        let layout = model.layout
        let graphRow = layout.rows[row]
        let edges = Array(layout.edges(of: row))
        switch model.row(row) {
        case .workInProgress(let changed):
            return GraphRowContent(kind: .workInProgress(changed: changed), row: graphRow, edges: edges)
        case .commit(let index):
            let commit = model.commits[index]
            let date = GraphDate.parse(commit.authorDate).map { GraphDate.relative($0) } ?? ""
            let isHead = commit.hash == model.summary?.head
            return GraphRowContent(kind: .commit(commit, labels: labels(at: row, for: commit), isHead: isHead, date: date),
                                   row: graphRow, edges: edges)
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { model.rowCount }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = GitGraphTableRowView()
        rowView.selectionColor = card.theme.selection
        return rowView
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let style, let content = content(at: row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: GitGraphCell.identifier, owner: nil) as? GitGraphCell) ?? GitGraphCell()
        cell.configure(content, style: style, geometry: geometry)
        return cell
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    // MARK: Navigation

    private var selectedCommit: GitCommit? {
        table.selectedRow >= 0 ? model.commit(at: table.selectedRow) : nil
    }

    /// Scrolls to HEAD's commit and selects it.
    func revealHead() {
        guard let row = model.headRow else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        focus()
    }

    // MARK: Actions

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, let commit = model.commit(at: row) else { return }
        let busy = isBusy
        let merge = commit.parentHashes.count > 1
        for label in labels(at: row, for: commit) {
            switch label.kind {
            case .local, .current:
                let current = label.kind == .current
                menu.addItem(ActionMenuItem("Switch to \(label.name)", enabled: !busy && !current) { [weak self] in
                    self?.change(.switchBranch(label.name))
                })
            default:
                continue
            }
        }
        menu.addItem(ActionMenuItem("Check Out Commit…", enabled: !busy) { [weak self] in
            self?.confirm(.checkout(commit.hash), title: "Check Out \(commit.shortHash)?",
                          message: "HEAD will be detached at “\(commit.subject)”.", confirmTitle: "Check Out")
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Cherry-Pick Commit…", enabled: !busy && !merge) { [weak self] in
            self?.confirm(.cherryPick(commit.hash), title: "Cherry-Pick \(commit.shortHash)?",
                          message: "“\(commit.subject)” will be applied on top of the current branch.",
                          confirmTitle: "Cherry-Pick")
        })
        menu.addItem(ActionMenuItem("Revert Commit…", enabled: !busy && !merge) { [weak self] in
            self?.confirm(.revert(commit.hash), title: "Revert \(commit.shortHash)?",
                          message: "The changes undoing “\(commit.subject)” will be staged for you to commit.",
                          confirmTitle: "Revert")
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Copy Commit Hash") { Self.copy(commit.hash) })
        menu.addItem(ActionMenuItem("Copy Commit Subject") { Self.copy(commit.subject) })
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func confirm(_ action: GitAction, title: String, message: String, confirmTitle: String) {
        host?.confirm(title: title, message: message, confirmTitle: confirmTitle, destructive: false) { [weak self] confirmed in
            if confirmed { self?.change(action) }
        }
    }

    /// Runs a change the user asked for, then reads the history again.
    private func change(_ action: GitAction) {
        guard let host, !isBusy else { return }
        guard let transport = host.nativeTransport else {
            host.showToast("The project's server isn't connected.", style: .error)
            return
        }
        isBusy = true
        setLoading(true)
        let request = GitRequest(project: host.nativeProject.id, action: action)
        Task { [weak self] in
            var failure: String?
            do {
                _ = try await transport.git(request)
            } catch {
                failure = NativeErrors.friendly(NativeErrors.describe(error), folder: true)
            }
            guard let self else { return }
            self.isBusy = false
            if let failure { self.host?.showToast(failure, style: .error) }
            self.refresh()
            self.host?.repositoryDidChange()
        }
    }
}
