import AppKit
import TabCore
import TabProtocol

/// The project whose saved sessions the panel lists.
public struct AgentSessionsProject: Equatable, Sendable {
    public var id: ProjectId
    public var name: String
    /// The project's folder.
    public var path: String
    /// On this Mac; remote projects never show this computer's sessions.
    public var isLocal: Bool
    /// The folder exists.
    public var isAvailable: Bool

    public init(id: ProjectId, name: String, path: String, isLocal: Bool, isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.isLocal = isLocal
        self.isAvailable = isAvailable
    }
}

/// What the Agent Sessions panel needs from the app.
@MainActor
public protocol AgentSessionsHost: AnyObject {
    var theme: AppTheme { get }
    /// The saved appearance: provider choices, position, pin and sizes.
    var appearance: Appearance { get }
    /// Changes and saves the appearance.
    func updateAppearance(_ change: (inout Appearance) -> Void)
    /// The selected project, or `nil` when there is none.
    var agentSessionsProject: AgentSessionsProject? { get }
    /// Opens a new terminal pane in `project` titled `title` that runs
    /// `command` (such as `claude --resume ID`), and focuses it.
    func resumeAgentSession(command: String, title: String, in project: ProjectId)
    /// Gives the keyboard back to the focused pane.
    func focusActivePane()
    /// Hides the panel, saving `agentSessionsVisible = false`.
    func closeAgentSessions()
    /// The position or pin changed in the appearance; place the panel again.
    func agentSessionsLayoutDidChange()
    func showError(_ message: String)
}

/// Saved agent conversations of the selected local project, searchable and
/// filterable by provider, resumed in a new terminal.
@MainActor
public final class AgentSessionsController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    public private(set) weak var host: AgentSessionsHost?
    public private(set) var listing = AgentSessionListing()
    public private(set) var list = AgentSessionList()
    /// Whether a scan runs now.
    public var isLoading: Bool { scan != nil }

    private let roots: AgentSessionRoots?
    private var catalog = AgentSessionCatalog()
    private var scan: Task<Void, Never>?
    private var refreshPending = false
    private var scope: AgentSessionsProject?
    private var showUnsupported = false
    private var searchFocused = false
    private weak var filterPopover: NSPopover?
    private weak var filterView: ProviderFilterView?

    private let root = AgentSessionsRootView()
    private let titleLabel = makeLabel("Agent Sessions", font: AppFont.header)
    private let historyGlyph = NSImageView()
    private let refreshButton = IconButton(.refresh, label: "Refresh sessions")
    private let spinner = Spinner(size: .small)
    private let positionButton = IconButton(.panelBottom, label: "Move to Bottom")
    private let pinButton = IconButton(.pinOff, label: "Unpin")
    private let closeButton = IconButton(.close, label: "Close")
    private let search = SearchField(placeholder: "Search sessions…")
    private let clearButton = IconButton(.circleX, label: "Clear search")
    private let filterButton = IconButton(.filter, label: "Filter providers")
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let emptyLabel = makeLabel("", font: AppFont.body)
    private let resetButton = PillButton("Reset filters")
    private let emptyView = NSStackView()
    private let notices = makeLabel("", font: AppFont.footnote)
    private let edgeHandle = EdgeResizeHandle(edge: .leading)
    private let topHandle = EdgeResizeHandle(edge: .top)
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var dragStart: CGFloat = 0

    /// `roots` are where transcripts are looked for; `nil` reads nothing.
    public init(host: AgentSessionsHost, roots: AgentSessionRoots? = AgentSessionRoots.fromEnvironment()) {
        self.host = host
        self.roots = roots
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    public override func loadView() {
        let theme = host?.theme ?? .shared
        root.theme = theme
        root.controller = self
        historyGlyph.image = AppIcon.history.image(size: 14)
        historyGlyph.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.action = { [weak self] in self?.refresh() }
        positionButton.action = { [weak self] in self?.togglePosition() }
        pinButton.action = { [weak self] in self?.togglePinned() }
        closeButton.action = { [weak self] in self?.host?.closeAgentSessions() }
        clearButton.action = { [weak self] in self?.clearSearch(focus: true) }
        filterButton.action = { [weak self] in self?.toggleFilters() }
        resetButton.action = { [weak self] in self?.resetFilters() }
        spinner.isHidden = true
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [historyGlyph, titleLabel, NSView(), spinner, refreshButton, positionButton, pinButton, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 2
        header.setCustomSpacing(Metrics.controlGap, after: historyGlyph)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: Metrics.gutter)
        header.translatesAutoresizingMaskIntoConstraints = false

        search.field.delegate = self
        clearButton.isHidden = true
        let searchRow = NSStackView(views: [search, clearButton, filterButton])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 4
        searchRow.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gutter, bottom: 0, right: Metrics.gutter)
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.refusesFirstResponder = true
        table.setAccessibilityLabel("Agent sessions")
        tableScroll.documentView = table
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.scrollerStyle = .overlay
        tableScroll.autohidesScrollers = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 12
        emptyView.addArrangedSubview(emptyLabel)
        emptyView.addArrangedSubview(resetButton)
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        notices.lineBreakMode = .byWordWrapping
        notices.maximumNumberOfLines = 0

        for subview in [header, searchRow, tableScroll, emptyView, notices, edgeHandle, topHandle] as [NSView] {
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            historyGlyph.widthAnchor.constraint(equalToConstant: 14),
            searchRow.topAnchor.constraint(equalTo: header.bottomAnchor),
            searchRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchRow.heightAnchor.constraint(equalToConstant: 36),
            tableScroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            tableScroll.bottomAnchor.constraint(equalTo: notices.topAnchor, constant: -4),
            emptyView.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            emptyView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            emptyView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            notices.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            notices.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            notices.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Metrics.gutter),
            edgeHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: -3),
            edgeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            edgeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edgeHandle.widthAnchor.constraint(equalToConstant: 6),
            topHandle.topAnchor.constraint(equalTo: root.topAnchor, constant: -3),
            topHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topHandle.heightAnchor.constraint(equalToConstant: 6),
        ])
        edgeHandle.onBegin = { [weak self] in self?.dragStart = self?.widthConstraint?.constant ?? 0 }
        edgeHandle.onDrag = { [weak self] delta in self?.resize(by: delta) }
        edgeHandle.onEnd = { [weak self] in self?.saveSize() }
        topHandle.onBegin = { [weak self] in self?.dragStart = self?.heightConstraint?.constant ?? 0 }
        topHandle.onDrag = { [weak self] delta in self?.resize(by: delta) }
        topHandle.onEnd = { [weak self] in self?.saveSize() }
        widthConstraint = root.widthAnchor.constraint(equalToConstant: 320)
        widthConstraint?.priority = .defaultHigh
        heightConstraint = root.heightAnchor.constraint(equalToConstant: 220)
        heightConstraint?.priority = .defaultHigh
        view = root
        themeDidChange()
        applyLayout()
        rebuild()
    }

    func themeDidChange() {
        guard let theme = host?.theme else { return }
        titleLabel.textColor = theme.fg
        historyGlyph.contentTintColor = theme.fgMuted
        emptyLabel.textColor = theme.fgMuted
        notices.textColor = theme.fgMuted
        updateFilterButton()
        table.reloadData()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        projectDidChange()
    }

    // MARK: Public API

    /// Rescans when the selected project changed; call on project switches
    /// and when the panel is shown.
    public func projectDidChange() {
        let current = host?.agentSessionsProject.flatMap { $0.isLocal && $0.isAvailable ? $0 : nil }
        guard current != scope else { return }
        scope = current
        listing = AgentSessionListing()
        rebuild()
        if scope != nil { refresh() }
    }

    /// Reads the transcripts again, in bounded batches until done.
    public func refresh() {
        guard scan == nil else {
            refreshPending = true
            return
        }
        guard let roots, let requested = scope else { return }
        var catalog = self.catalog
        self.catalog = AgentSessionCatalog()
        let directory = requested.path
        scan = Task { [weak self] in
            let (updated, found) = await Task.detached(priority: .utility) {
                let listing = catalog.scan(roots, project: directory)
                return (catalog, listing)
            }.value
            self?.finishScan(catalog: updated, listing: found, requested: requested)
        }
        updateLoading()
    }

    /// Applies provider choices changed elsewhere, such as in another window.
    public func appearanceDidChange() {
        applyLayout()
        rebuild()
    }

    /// Puts the cursor in the search field.
    public func focusSearch() {
        view.window?.makeFirstResponder(search.field)
    }

    public var hasFocus: Bool {
        guard isViewLoaded, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    // MARK: Scanning

    private func finishScan(catalog: AgentSessionCatalog, listing found: AgentSessionListing, requested: AgentSessionsProject) {
        scan = nil
        self.catalog = catalog
        let pending = refreshPending || found.pending
        refreshPending = false
        if scope == requested {
            listing = found
            rebuild()
            if pending { refresh() }
        } else if scope != nil || pending {
            refresh()
        }
        updateLoading()
    }

    private func updateLoading() {
        spinner.isHidden = scan == nil
        refreshButton.isHidden = scan != nil
        if listing.sessions.isEmpty { updateEmptyState() }
    }

    // MARK: Filtering

    private var providers: [AgentProvider] { host?.appearance.agentSessionsProviders ?? AgentSessionProviders.supported }

    private var query: String { isViewLoaded ? search.stringValue : "" }

    private func rebuild() {
        guard isViewLoaded else { return }
        list.rebuild(listing.sessions, providers: providers, query: query)
        clearButton.isHidden = query.isEmpty
        table.reloadData()
        if let row = list.selectedRow { table.scrollRowToVisible(row) }
        updateEmptyState()
        updateNotices()
        updateFilterButton()
        filterView?.reload()
    }

    private func updateEmptyState() {
        let shown = list.entries.contains { if case .session = $0 { return true } else { return false } }
        tableScroll.isHidden = !shown
        emptyView.isHidden = shown
        guard !shown else { return }
        let (message, reset) = emptyMessage
        emptyLabel.stringValue = message
        resetButton.isHidden = !reset
    }

    /// What the panel says with no rows, and whether Reset filters helps.
    var emptyMessage: (String, Bool) {
        guard let project = host?.agentSessionsProject, project.isLocal else {
            return ("Select a local project to browse its saved agent sessions.", false)
        }
        if scope == nil || roots == nil { return ("The project or home directory could not be found.", false) }
        if scan != nil && listing.sessions.isEmpty { return ("Loading session history…", false) }
        if listing.sessions.isEmpty { return ("No agent sessions in this project", false) }
        if providers.isEmpty { return ("No providers selected", true) }
        return ("No matching sessions", true)
    }

    private func updateNotices() {
        var messages: [String] = []
        if listing.limited { messages.append("Some history exceeds the scan limit.") }
        for warning in listing.warnings { messages.append("Could not read some \(warning.provider.displayName) sessions.") }
        notices.stringValue = messages.joined(separator: "\n")
        notices.isHidden = messages.isEmpty
    }

    private func updateFilterButton() {
        let all = AgentSessionProviders.supported.allSatisfy(providers.contains)
        filterButton.isActive = !all
    }

    private func clearSearch(focus: Bool) {
        search.stringValue = ""
        rebuild()
        if focus { focusSearch() }
    }

    private func resetFilters() {
        search.stringValue = ""
        setProviders(AgentSessionProviders.supported)
        focusSearch()
    }

    func setProviders(_ providers: [AgentProvider]) {
        let supported = providers.filter(AgentSessionProviders.isSupported)
        host?.updateAppearance { $0.agentSessionsProviders = supported }
        rebuild()
    }

    func toggleProvider(_ provider: AgentProvider) {
        guard AgentSessionProviders.isSupported(provider) else { return }
        var selected = providers
        if selected.contains(provider) {
            selected.removeAll { $0 == provider }
        } else {
            selected.append(provider)
        }
        setProviders(selected)
    }

    // MARK: Resuming

    func moveSelection(backwards: Bool) {
        guard let row = list.advance(backwards: backwards) else { return }
        table.reloadData()
        table.scrollRowToVisible(row)
    }

    func resumeSelected() {
        guard let index = list.selectedIndex, listing.sessions.indices.contains(index) else { return }
        resume(listing.sessions[index])
    }

    private func resume(_ session: AgentSession) {
        guard let host, let scope, scope == host.agentSessionsProject, listing.sessions.contains(session),
              let command = session.resumeCommand
        else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            host.showError("This session is no longer available. Refresh the session list.")
            return
        }
        host.resumeAgentSession(command: command, title: session.title, in: scope.id)
    }

    // MARK: Search keys

    public func controlTextDidChange(_ notification: Notification) {
        rebuild()
    }

    public func controlTextDidBeginEditing(_ notification: Notification) {
        setSearchFocused(true)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        setSearchFocused(false)
    }

    private func setSearchFocused(_ focused: Bool) {
        guard focused != searchFocused else { return }
        searchFocused = focused
        table.reloadData()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(backwards: false)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(backwards: true)
        case #selector(NSResponder.insertNewline(_:)):
            resumeSelected()
        case #selector(NSResponder.insertTab(_:)):
            toggleFilters()
        case #selector(NSResponder.cancelOperation(_:)):
            escape()
        default:
            return false
        }
        return true
    }

    /// Escape clears the search; Escape again returns to the terminal.
    func escape() {
        if query.isEmpty {
            host?.focusActivePane()
        } else {
            clearSearch(focus: false)
        }
    }

    // MARK: Provider filter

    func toggleFilters() {
        if let popover = filterPopover, popover.isShown {
            popover.close()
            return
        }
        guard let host else { return }
        let filter = ProviderFilterView(controller: self, theme: host.theme)
        filterView = filter
        let popover = PopoverHost.show(filter, size: filter.preferredSize, relativeTo: filterButton, edge: .maxY, theme: host.theme)
        filterPopover = popover
        filter.window?.makeFirstResponder(filter)
    }

    /// Closes the provider filter and returns to the search field.
    func closeFilters() {
        filterPopover?.close()
        focusSearch()
    }

    var providerState: (selected: [AgentProvider], counts: [AgentProvider: Int], showUnsupported: Bool) {
        (providers, list.counts, showUnsupported)
    }

    func toggleUnsupported() {
        showUnsupported.toggle()
        filterView?.reload()
        if let filterView { filterPopover?.contentSize = filterView.preferredSize }
    }

    // MARK: Position and size

    private func applyLayout() {
        guard let host, isViewLoaded else { return }
        let appearance = host.appearance
        let right = appearance.agentSessionsPosition == .right
        positionButton.icon = right ? .panelBottom : .panelRight
        relabel(positionButton, right ? "Move to Bottom" : "Move to Right")
        pinButton.icon = appearance.agentSessionsPinned ? .pinOff : .pin
        relabel(pinButton, appearance.agentSessionsPinned ? "Unpin" : "Pin")
        edgeHandle.isHidden = !right
        topHandle.isHidden = right
        widthConstraint?.isActive = right
        heightConstraint?.isActive = !right
        widthConstraint?.constant = clampedSize(CGFloat(appearance.agentSessionsWidth ?? 320))
        heightConstraint?.constant = clampedSize(CGFloat(appearance.agentSessionsHeight ?? 220))
    }

    private func relabel(_ button: IconButton, _ label: String) {
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func clampedSize(_ value: CGFloat) -> CGFloat {
        let window = view.window?.contentView?.bounds.size ?? CGSize(width: 1200, height: 800)
        if host?.appearance.agentSessionsPosition ?? .right == .right {
            return min(max(value, 240), max(min(800, window.width - 400), 240))
        }
        return min(max(value, 120), max(min(600, window.height - 160), 120))
    }

    private func resize(by delta: CGFloat) {
        let right = host?.appearance.agentSessionsPosition ?? .right == .right
        let constraint = right ? widthConstraint : heightConstraint
        constraint?.constant = clampedSize(dragStart + delta)
    }

    private func saveSize() {
        guard let host else { return }
        if host.appearance.agentSessionsPosition == .right {
            let width = widthConstraint.map { Double($0.constant) }
            host.updateAppearance { $0.agentSessionsWidth = width }
        } else {
            let height = heightConstraint.map { Double($0.constant) }
            host.updateAppearance { $0.agentSessionsHeight = height }
        }
    }

    private func togglePosition() {
        host?.updateAppearance { $0.agentSessionsPosition = $0.agentSessionsPosition == .right ? .bottom : .right }
        applyLayout()
        host?.agentSessionsLayoutDidChange()
    }

    private func togglePinned() {
        host?.updateAppearance { $0.agentSessionsPinned.toggle() }
        applyLayout()
        host?.agentSessionsLayoutDidChange()
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { list.entries.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = list.entries[row] { return 26 }
        return 44
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let host else { return nil }
        switch list.entries[row] {
        case .section(let recency):
            let label = AgentsSectionLabel(recency.title)
            label.theme = host.theme
            return label
        case .session(let index, let key):
            let identifier = NSUserInterfaceItemIdentifier("agent-session")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? AgentSessionCell ?? AgentSessionCell()
            cell.identifier = identifier
            cell.theme = host.theme
            let session = listing.sessions[index]
            cell.configure(session, selected: searchFocused && key == list.selected)
            cell.onClick = { [weak self] in self?.resume(session) }
            return cell
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// The panel background and resize edges.
final class AgentSessionsRootView: ThemedView {
    weak var controller: AgentSessionsController?

    override func themeDidChange() {
        controller?.themeDidChange()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.cardRadius, yRadius: Metrics.cardRadius)
        theme.card.setFill()
        path.fill()
        theme.cardBorder.setStroke()
        path.stroke()
    }
}

/// A saved session: provider logo, title, and provider with age.
final class AgentSessionCell: HoverView {
    var onClick: (() -> Void)?
    private var selected = false
    private let logo = NSImageView()
    private let titleLabel = makeLabel("", font: AppFont.body)
    private let detailLabel = makeLabel("", font: AppFont.footnote)

    init() {
        super.init(frame: .zero)
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.imageScaling = .scaleProportionallyUpOrDown
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(logo)
        addSubview(text)
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gutter),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 14),
            logo.heightAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: Metrics.controlGap),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.gutter),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ session: AgentSession, selected: Bool) {
        let title = session.title == session.id ? "Untitled session" : session.title
        titleLabel.stringValue = title
        detailLabel.stringValue = "\(session.provider.displayName) · \(Self.age(session.modified))"
        logo.image = AgentLogo.image(for: session.provider, lightBackground: theme.palette.isLight)
        toolTip = "\(title)\n\(session.provider.displayName) · \(session.id)\nResume in a new terminal"
        setAccessibilityLabel("\(title), \(detailLabel.stringValue)")
        self.selected = selected
        themeDidChange()
    }

    /// "Just now", "5m ago".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let text = RelativeTime.ago(since: date, now: now)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fg
        detailLabel.textColor = theme.fgMuted
        logo.contentTintColor = theme.fgMuted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected || isHovered else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The provider filter popover: a checkable row per supported provider with
/// its matching count, the unsupported ones, Clear and Select all.
final class ProviderFilterView: ThemedView {
    private weak var controller: AgentSessionsController?
    private let stack = NSStackView()
    private var highlighted = 0
    private var rows: [ProviderFilterRow] = []

    init(controller: AgentSessionsController, theme: AppTheme) {
        self.controller = controller
        super.init(frame: .zero)
        self.theme = theme
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        addSubview(stack)
        stack.pinEdges(to: self)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    var preferredSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: 240, height: stack.fittingSize.height)
    }

    func reload() {
        guard let controller else { return }
        let state = controller.providerState
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        add(sectionLabel("Include providers"))
        for (index, provider) in AgentSessionProviders.supported.enumerated() {
            let row = ProviderFilterRow(
                provider: provider, theme: theme, checked: state.selected.contains(provider),
                trailing: "\(state.counts[provider] ?? 0)", enabled: true
            )
            row.isHighlighted = index == highlighted
            row.onClick = { [weak controller] in controller?.toggleProvider(provider) }
            rows.append(row)
            add(row)
        }
        add(divider())
        let disclosure = ProviderFilterRow(disclosure: state.showUnsupported, theme: theme)
        disclosure.onClick = { [weak controller] in controller?.toggleUnsupported() }
        add(disclosure)
        if state.showUnsupported {
            for provider in AgentSessionProviders.all where !AgentSessionProviders.isSupported(provider) {
                add(ProviderFilterRow(provider: provider, theme: theme, checked: false, trailing: "Not supported", enabled: false))
            }
        }
        let allSelected = AgentSessionProviders.supported.allSatisfy(state.selected.contains)
        let clear = PillButton("Clear", style: .plain) { [weak controller] in controller?.setProviders([]) }
        clear.isEnabled = !state.selected.isEmpty
        let all = PillButton("Select all", style: .plain) { [weak controller] in controller?.setProviders(AgentSessionProviders.supported) }
        all.isEnabled = !allSelected
        let footer = NSStackView(views: [NSView(), clear, all])
        footer.spacing = 4
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        add(divider())
        add(footer)
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
    }

    private func sectionLabel(_ title: String) -> NSView {
        let label = AgentsSectionLabel(title)
        label.theme = theme
        return label
    }

    private func divider() -> NSView {
        let line = ThemedBackground(color: { $0.separator })
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(line)
        line.pinEdges(to: wrapper, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
        return wrapper
    }

    override func keyDown(with event: NSEvent) {
        let count = AgentSessionProviders.supported.count
        switch event.keyCode {
        case 125: highlighted = (highlighted + 1) % count
        case 126: highlighted = (highlighted + count - 1) % count
        case 36, 76, 49:
            controller?.toggleProvider(AgentSessionProviders.supported[highlighted])
            return
        case 53, 48:
            controller?.closeFilters()
            return
        default:
            super.keyDown(with: event)
            return
        }
        for (index, row) in rows.enumerated() { row.isHighlighted = index == highlighted }
    }
}

/// A row of the provider filter: check, logo, name and count or note.
final class ProviderFilterRow: HoverView {
    var onClick: (() -> Void)?
    var isHighlighted = false { didSet { needsDisplay = true } }
    private let enabled: Bool
    private var labels: [(NSTextField, Bool)] = []
    private var glyphs: [(NSImageView, Bool)] = []

    init(provider: AgentProvider, theme: AppTheme, checked: Bool, trailing: String, enabled: Bool) {
        self.enabled = enabled
        super.init(frame: .zero)
        self.theme = theme
        let check = NSImageView(image: AppIcon.check.image(size: 14) ?? NSImage())
        check.isHidden = !checked
        let checkSlot = Self.slot(check)
        glyphs.append((check, true))
        let logo = AgentStatusStyle.logo(provider, theme: theme)
        let name = makeLabel(provider.displayName, font: AppFont.body)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let count = makeLabel(trailing, font: AppFont.footnote)
        labels = [(name, false), (count, true)]
        build([checkSlot, logo, name, count])
        setAccessibilityLabel("\(provider.displayName), \(trailing)")
        setAccessibilityValue(checked ? 1 : 0)
        setAccessibilityRole(enabled ? .checkBox : .staticText)
    }

    init(disclosure open: Bool, theme: AppTheme) {
        enabled = true
        super.init(frame: .zero)
        self.theme = theme
        let chevron = NSImageView(image: (open ? AppIcon.chevronDown : AppIcon.chevronRight).image(size: 14) ?? NSImage())
        glyphs.append((chevron, false))
        let name = makeLabel("Unavailable providers", font: AppFont.body)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels = [(name, true)]
        build([Self.slot(chevron), name])
        setAccessibilityLabel("Unavailable providers")
        setAccessibilityRole(.disclosureTriangle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func slot(_ image: NSImageView) -> NSView {
        image.translatesAutoresizingMaskIntoConstraints = false
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(image)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: 14),
            slot.heightAnchor.constraint(equalToConstant: 14),
            image.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
        ])
        return slot
    }

    private func build(_ views: [NSView]) {
        translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.controlGap
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 4, left: Metrics.gutter, bottom: 4, right: Metrics.gutter))
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        setAccessibilityElement(true)
        themeDidChange()
    }

    override func themeDidChange() {
        for (label, muted) in labels {
            label.textColor = !enabled ? theme.fgDim : (muted ? theme.fgMuted : theme.fg)
        }
        for (glyph, accent) in glyphs { glyph.contentTintColor = accent ? theme.accent : theme.fgDim }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard enabled, isHovered || isHighlighted else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        onClick?()
        return true
    }
}
