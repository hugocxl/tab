import AppKit
import Combine
import TabCore
import TabProtocol

/// The project sidebar: the top row beside the window buttons, Home
/// terminals and projects with their worktree cards, the update card, and
/// the footer with the host filter, Add Project and New Browser.
/// A collapsed sidebar is hidden, as in Codesh; its toggle moves into the
/// top-left pane. It rebuilds only when what it shows changed.
@MainActor
final class SidebarViewController: NSViewController {
    unowned let model: AppModel
    weak var actions: WindowActions?
    /// The live width while the resize handle is dragged, committed on release.
    var onResize: ((CGFloat?) -> Void)?

    private let root = SidebarRootView()
    private let topRow = FlippedView()
    private let toggle = ChromeButton(.panelLeft, label: "Toggle Sidebar")
    private let newTerminal = ChromeButton(.plus, label: "New Terminal")
    private let scroll = ScrollView()
    private let list = NSStackView()
    private let footer = FlippedView()
    private let hostButton = ChromeButton(.filterCircle, label: "Filter by Host")
    private let addButton = ChromeButton(.plus, label: "Add Project")
    private let browserButton = ChromeButton(.globe, label: "New Browser")
    private let filterField = SearchField(placeholder: "Filter")
    private let resizeHandle = SidebarResizeHandle()
    private let updateCard = UpdateCardView()
    private var snapshot: SidebarSnapshot?
    private var subscription: AnyCancellable?
    private var filterShown = false

    /// Where the window buttons end, from the window's left edge.
    var trafficLightsEnd: CGFloat = 78 {
        didSet {
            guard trafficLightsEnd != oldValue else { return }
            root.needsLayout = true
            root.superview?.needsLayout = true
        }
    }

    /// The window's title bar band the list starts below.
    static let titleBarHeight: CGFloat = 32
    static let footerHeight: CGFloat = Metrics.gutter * 2 + ChromeButton.side

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        root.controller = self
        view = root
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.content.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.content.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.content.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.content.bottomAnchor),
        ])
        scroll.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(scroll)
        root.addSubview(topRow)
        root.addSubview(footer)
        updateCard.isHidden = true
        root.addSubview(updateCard)
        root.addSubview(resizeHandle)
        for button in [toggle, newTerminal] { topRow.addSubview(button) }
        for button in [hostButton, addButton, browserButton] { footer.addSubview(button) }
        filterField.translatesAutoresizingMaskIntoConstraints = true
        filterField.isHidden = true
        footer.addSubview(filterField)

        toggle.onPress = { [weak self] _ in self?.model.toggleSidebar() }
        newTerminal.onPress = { [weak self] _ in self?.model.newTerminal() }
        hostButton.onPress = { [weak self] button in self?.model.remoteController.toggleHostMenu(relativeTo: button) }
        hostButton.menuProvider = { [weak self] in self?.filterMenu() }
        addButton.onPress = { [weak self] button in self?.actions?.addProject(anchor: button) }
        browserButton.onPress = { [weak self] _ in self?.model.openBrowser() }
        filterField.onChange = { [weak self] text in self?.model.nameFilter = text }
        filterField.onSubmit = { [weak self] in self?.view.window?.makeFirstResponder(nil) }
        updateCard.onAction = { [weak self] action in self?.model.updater.handle(action) }
        updateCard.onDismiss = { [weak self] in self?.model.updater.dismissCard() }
        resizeHandle.onDrag = { [weak self] width in self?.onResize?(width) }
        resizeHandle.widthAtStart = { [weak self] in self?.model.sidebarWidth ?? Metrics.sidebarExpandedWidth }

        subscription = model.changes.sink { [weak self] changes in
            guard let self, !changes.isDisjoint(with: [.state, .activity, .settings, .panel]) else { return }
            self.reload()
        }
        reload()
    }

    var isExpanded: Bool { model.appearance.sidebarExpanded }

    /// Clears the name filter, as Escape does in the sidebar.
    func clearFilter() {
        filterShown = false
        filterField.stringValue = ""
        model.nameFilter = ""
        reload()
    }

    func showFilter() {
        filterShown = true
        reload()
        view.window?.makeFirstResponder(filterField.field)
    }

    // MARK: Building

    func reload() {
        let next = SidebarSnapshot(model: model, filterShown: filterShown)
        updateChrome(next)
        guard next != snapshot else { return }
        snapshot = next
        rebuild(next)
    }

    private func updateChrome(_ snapshot: SidebarSnapshot) {
        toggle.toolTip = isExpanded ? "Hide Sidebar" : "Show Sidebar"
        filterField.isHidden = !(snapshot.filterShown || !model.nameFilter.isEmpty) || !isExpanded
        updateUpdateCard()
        root.needsLayout = true
    }

    private func updateUpdateCard() {
        let card = isExpanded ? model.updater.card : nil
        updateCard.isHidden = card == nil
        updateCard.card = card
    }

    private func rebuild(_ snapshot: SidebarSnapshot) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        list.edgeInsets = NSEdgeInsets(top: 10, left: Metrics.gutter, bottom: 6, right: 0)
        guard isExpanded else { return }
        buildExpanded(snapshot)
    }

    private func add(_ view: NSView, fill: Bool = true) {
        view.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(view)
        if fill {
            view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -list.edgeInsets.left - list.edgeInsets.right).isActive = true
        }
    }

    private func buildExpanded(_ snapshot: SidebarSnapshot) {
        var cardNumber = 0
        for card in snapshot.terminals {
            let view = cardView(card, hint: hint(.tabs, &cardNumber))
            add(view)
        }
        for group in snapshot.groups {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = 2
            stack.alignment = .leading
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: group.hasWorktrees ? 4 : 0, right: 0)
            let header = headerView(group)
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(0, after: header)
            header.translatesAutoresizingMaskIntoConstraints = false
            header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            for card in group.cards {
                let view = cardView(card, hint: hint(.tabs, &cardNumber))
                view.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            for name in group.creating {
                let row = CreatingRow(name: name)
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            add(stack)
        }
        let addRow = AddProjectRow()
        addRow.onClick = { [weak self] view in self?.actions?.addProject(anchor: view) }
        add(addRow)
    }

    private enum HintKind { case tabs }

    private func hint(_ kind: HintKind, _ counter: inout Int) -> String? {
        defer { counter += 1 }
        guard counter < 9 else { return nil }
        return hintLabel(ShortcutId.tabs[counter])
    }

    private func hintLabel(_ id: ShortcutId) -> String? {
        guard let held = model.shortcutHints, let chord = model.settings.keymap.chord(id), chord.modifiers == held else {
            return nil
        }
        return ShortcutCatalog.displayChord(chord.key)
    }

    private func cardView(_ card: SidebarSnapshot.CardEntry, hint: String?) -> SidebarCardView {
        let view = SidebarCardView(data: card.data, hint: hint)
        let target = card.target
        view.onClick = { [weak self] in self?.model.select(target) }
        view.menuProvider = { [weak self, weak view] in self?.cardMenu(card, anchor: view) }
        return view
    }

    private func headerView(_ group: SidebarSnapshot.GroupEntry) -> NSView {
        guard let project = model.state.project(group.project) else { return NSView() }
        let header = ProjectHeaderRow(
            project: project, title: group.title, icon: model.projectIcon(project.id),
            remoteName: model.serverName(project.serverId), canCreateWorktree: group.canCreateWorktree
        )
        header.onGear = { [weak self] anchor in
            self?.projectMenu(project.id, anchor: anchor)?.popUp(below: anchor)
        }
        header.onNewWorktree = { [weak self] in self?.actions?.newWorktree(parent: project.id) }
        header.menuProvider = { [weak self, weak header] in self?.projectMenu(project.id, anchor: header) }
        header.onDrag = { [weak self, weak header] event in
            guard let self, let header else { return }
            self.dragProject(project.id, from: header, event: event)
        }
        return header
    }

    // MARK: Reordering

    private func dragProject(_ project: ProjectId, from header: NSView, event: NSEvent) {
        guard model.appearance.sidebarProjectOrder == .manual, let window = view.window,
              model.state.project(project)?.status == .available else { return }
        let start = event.locationInWindow
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            if !moved, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) < 4 { continue }
            moved = true
            let point = list.convert(next.locationInWindow, from: nil)
            guard let target = headerTarget(at: point), target != project else { continue }
            model.moveProject(project, before: target)
            reload()
        }
    }

    private func headerTarget(at point: NSPoint) -> ProjectId? {
        for group in list.arrangedSubviews {
            guard group.frame.contains(point), let stack = group as? NSStackView,
                  let header = stack.arrangedSubviews.first as? ProjectHeaderRow else { continue }
            return header.project
        }
        return nil
    }

    // MARK: Menus

    func projectMenu(_ id: ProjectId, anchor: NSView?) -> NSMenu? {
        guard let project = model.state.project(id) else { return nil }
        if project.parentId != nil { return worktreeMenu(project, primary: false, anchor: anchor) }
        var items: [NSMenuItem] = []
        if project.status != .available {
            if !project.home { items.append(ClosureMenuItem("Remove Project…") { [weak self] in self?.model.confirmRemoveProject(id) }) }
            return NSMenu.make(items)
        }
        items += terminalItems(id)
        if !project.isRemoteHome {
            items.append(.separator())
            items.append(ClosureMenuItem("Rename…") { [weak self, weak anchor] in self?.actions?.rename(project: id, anchor: anchor) })
        }
        if !project.home {
            items.append(.submenu("Workspaces", workspaceItems(id, anchor: anchor)))
            if model.git[id]?.isRepository ?? false {
                items.append(.separator())
                let visible = model.listingBuilder().worktreesVisible(project)
                items.append(ClosureMenuItem("Show Worktrees", checked: visible) { [weak self] in self?.model.toggleWorktrees(id) })
            }
        }
        items += pathItems(project)
        if !project.home {
            items.append(.separator())
            items.append(ClosureMenuItem("Remove Project…") { [weak self] in self?.model.confirmRemoveProject(id) })
        }
        return NSMenu.make(items)
    }

    private func worktreeMenu(_ project: Project, primary: Bool, anchor: NSView?) -> NSMenu {
        let id = project.id
        if project.status != .available {
            return NSMenu.make(primary ? [] : [ClosureMenuItem("Remove Worktree…") { [weak self] in self?.model.confirmRemoveProject(id) }])
        }
        var items = terminalItems(id)
        if !primary {
            items.append(.separator())
            items.append(ClosureMenuItem("Rename Worktree…") { [weak self, weak anchor] in self?.actions?.rename(project: id, anchor: anchor) })
        }
        items += pathItems(project)
        if !primary {
            items.append(.separator())
            items.append(ClosureMenuItem("Remove Worktree and Files…") { [weak self] in self?.model.confirmRemoveWorktree(id) })
        }
        return NSMenu.make(items)
    }

    private func cardMenu(_ card: SidebarSnapshot.CardEntry, anchor: NSView?) -> NSMenu? {
        switch card.target {
        case .tab(let tab):
            return NSMenu.make([ClosureMenuItem("Close Terminal") { [weak self] in
                guard let self else { return }
                self.model.selectTab(tab)
                self.model.closeTab()
            }])
        case .project(let id):
            guard let project = model.state.project(id) else { return nil }
            if project.parentId == nil && !card.data.primary { return projectMenu(id, anchor: anchor) }
            return worktreeMenu(project, primary: project.parentId == nil, anchor: anchor)
        }
    }

    private func terminalItems(_ id: ProjectId) -> [NSMenuItem] {
        [
            ClosureMenuItem("New Terminal") { [weak self] in self?.model.newTerminal(in: id) },
            ClosureMenuItem("Existing Terminals…") { [weak self] in self?.actions?.openPalette(.terminals(id)) },
        ]
    }

    private func pathItems(_ project: Project) -> [NSMenuItem] {
        let path = project.directory.rawValue
        var items: [NSMenuItem] = [.separator()]
        if project.serverId.isLocal {
            items.append(ClosureMenuItem("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            })
        }
        items.append(ClosureMenuItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
        return items
    }

    private func workspaceItems(_ project: ProjectId, anchor: NSView?) -> [NSMenuItem] {
        var items: [NSMenuItem] = model.state.workspaces.map { workspace in
            let member = workspace.projects.contains(project)
            return ClosureMenuItem(workspace.name, checked: member) { [weak self] in
                self?.model.setWorkspaceMember(workspace.id, project: project, member: !member)
            }
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(ClosureMenuItem("New Workspace…") { [weak self, weak anchor] in
            self?.actions?.newWorkspace(adding: project, anchor: anchor)
        })
        return items
    }

    /// The host button's right-click menu: which hosts and workspace the
    /// sidebar lists, and the name filter.
    private func filterMenu() -> NSMenu {
        let menu = model.remoteController.hostFilterMenu(selected: model.appearance.sidebarHost) { [weak self] host in
            self?.model.setSidebarHost(host)
            if case .server(let id) = host { self?.model.connectOnDemand(id) }
        }
        menu.addItem(.separator())
        menu.addItem(.submenu("Workspace", workspaceFilterItems(anchor: hostButton)))
        menu.addItem(ClosureMenuItem("Filter by Name…") { [weak self] in self?.showFilter() })
        return menu
    }

    private func workspaceFilterItems(anchor: NSView?) -> [NSMenuItem] {
        let active = model.state.activeWorkspace?.id
        var items: [NSMenuItem] = [
            ClosureMenuItem("All Projects", checked: active == nil && !model.state.remoteServersSelected) { [weak self] in
                self?.model.selectWorkspace(nil)
            },
        ]
        for workspace in model.state.workspaces {
            items.append(ClosureMenuItem(workspace.name, checked: workspace.id == active) { [weak self] in
                self?.model.selectWorkspace(workspace.id)
            })
        }
        if model.offersRemoteServersWorkspace {
            items.append(ClosureMenuItem("Remote Servers", checked: model.state.remoteServersSelected) { [weak self] in
                self?.model.selectRemoteServersWorkspace()
            })
        }
        items.append(.separator())
        items.append(ClosureMenuItem("New Workspace…") { [weak self, weak anchor] in self?.actions?.newWorkspace(adding: nil, anchor: anchor) })
        if let active, let workspace = model.state.workspace(active) {
            items.append(ClosureMenuItem("Rename “\(workspace.name)”…") { [weak self, weak anchor] in
                self?.actions?.renameWorkspace(active, anchor: anchor)
            })
            items.append(ClosureMenuItem("Delete “\(workspace.name)”") { [weak self] in self?.model.deleteWorkspace(active) })
        }
        return items
    }

    // MARK: Layout

    fileprivate func layoutRoot() {
        let bounds = root.bounds
        let rowHeight = Metrics.headerHeight
        let side = ChromeButton.side
        let step = side + ChromeButton.gap
        topRow.frame = CGRect(x: 0, y: Metrics.gutter, width: bounds.width, height: rowHeight)
        let mid = (rowHeight - side) / 2
        toggle.frame = CGRect(x: max(trafficLightsEnd, Metrics.gutter), y: mid, width: side, height: side)
        newTerminal.frame = CGRect(x: bounds.width - step, y: mid, width: side, height: side)
        let footerHeight = Self.footerHeight
        footer.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
        let y = Metrics.gutter
        hostButton.frame = CGRect(x: Metrics.gutter, y: y, width: side, height: side)
        browserButton.frame = CGRect(x: bounds.width - side, y: y, width: side, height: side)
        addButton.frame = CGRect(x: browserButton.frame.minX - ChromeButton.gap - side, y: y, width: side, height: side)
        let filterX = hostButton.frame.maxX + ChromeButton.gap
        filterField.frame = CGRect(x: filterX, y: y, width: max(addButton.frame.minX - ChromeButton.gap - filterX, 0), height: side)
        let inset = Metrics.radiusMedium
        let cardHeight = updateCard.isHidden ? 0 : updateCard.height(for: max(bounds.width - inset * 2, 0))
        updateCard.frame = CGRect(x: inset, y: footer.frame.minY - cardHeight, width: max(bounds.width - inset * 2, 0), height: cardHeight)
        let scrollTop = Self.titleBarHeight
        let listEnd = updateCard.isHidden ? footer.frame.minY : updateCard.frame.minY - inset
        scroll.frame = CGRect(x: 0, y: scrollTop, width: bounds.width, height: max(listEnd - scrollTop, 0))
        resizeHandle.frame = CGRect(x: bounds.width - 3, y: 0, width: 6, height: bounds.height)
    }
}

/// The sidebar's background view.
final class SidebarRootView: ThemedView {
    weak var controller: SidebarViewController?

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.chrome.cgColor
    }

    override func layout() {
        super.layout()
        controller?.layoutRoot()
    }
}

/// The sidebar's right edge, dragged to resize it.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat?) -> Void)?
    var widthAtStart: (() -> CGFloat)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow.x
        let initial = widthAtStart?() ?? Metrics.sidebarExpandedWidth
        var width = initial
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            width = min(max(initial + next.locationInWindow.x - start, Metrics.sidebarMinimumWidth), Metrics.sidebarMaximumWidth)
            if next.type == .leftMouseUp { break }
            onDrag?(width)
        }
        onDrag?(nil)
        if let controller = (superview as? SidebarRootView)?.controller {
            controller.model.setSidebarWidth(width)
        }
    }
}
