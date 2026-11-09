import AppKit
import Combine
import TabCore
import TabProtocol

/// The project sidebar: the top row beside the window buttons, Home
/// terminals and projects with their worktree cards, and the footer with the host and name filter, Add Project and the Remote
/// Servers host menu.
/// A collapsed sidebar is hidden; its toggle moves into the
/// top-left pane. It rebuilds only when what it shows changed.
@MainActor
final class SidebarViewController: NSViewController {
    unowned let model: AppModel
    weak var actions: WindowActions?
    /// The live width while the resize handle is dragged, committed on release.
    var onResize: ((CGFloat?) -> Void)?

    private let root = SidebarRootView()
    private let topRow = FlippedView()
    private let toggle = ChromeButton(SystemSymbol.panelLeft, label: "Toggle Sidebar")
    private let commandPalette = ChromeButton(SystemSymbol.command, label: "Command Palette")
    private let newTab = ChromeButton(SystemSymbol.plusCircle, label: "New Tab")
    private let scroll = ScrollView()
    private let list = NSStackView()
    private let footer = FlippedView()
    private let filter = SidebarFilterView()
    private let addButton = ChromeButton(SystemSymbol.addProject, label: "Add Project")
    private let serversButton = ChromeButton(SystemSymbol.globeBadgePlus, label: "Remote Servers")
    private let resizeHandle = SidebarResizeHandle()
    private var snapshot: SidebarSnapshot?
    private var collapsedProjects: Set<ProjectId> = []
    private var subscription: AnyCancellable?

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
        root.addSubview(resizeHandle)
        for button in [toggle, commandPalette, newTab] { topRow.addSubview(button) }
        for view in [filter, addButton, serversButton] as [NSView] { footer.addSubview(view) }

        toggle.shortcut = .toggleSidebar
        commandPalette.shortcut = .toggleCommandPalette
        addButton.shortcut = .addProject
        toggle.onPress = { [weak self] _ in self?.model.toggleSidebar() }
        commandPalette.onPress = { [weak self] _ in self?.actions?.openPalette(.root) }
        newTab.onPress = { [weak self] button in
            guard let self else { return }
            self.model.newTabMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
        filter.hostMenu = { [weak self] in self?.hostMenu() }
        filter.contextMenu = { [weak self] in self?.filterMenu() }
        filter.onChange = { [weak self] text in self?.model.nameFilter = text }
        addButton.onPress = { [weak self] button in self?.actions?.addProject(anchor: button) }
        serversButton.onPress = { [weak self] button in self?.model.remoteController.toggleHostMenu(relativeTo: button) }
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
        filter.text = ""
        model.nameFilter = ""
    }

    func showFilter() {
        filter.focus()
    }

    // MARK: Building

    func reload() {
        let next = SidebarSnapshot(model: model)
        updateChrome(next)
        guard next != snapshot else { return }
        if snapshot?.expanded == true, !next.expanded {
            InterfaceMotion.dismiss(root, style: model.appearance.animationStyle, slide: -24)
        }
        snapshot = next
        rebuild(next)
    }

    private func updateChrome(_ snapshot: SidebarSnapshot) {
        toggle.toolTip = isExpanded ? "Hide Sidebar" : "Show Sidebar"
        if filter.text != model.nameFilter { filter.text = model.nameFilter }
        root.needsLayout = true
    }

    private func rebuild(_ snapshot: SidebarSnapshot) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // The list starts and ends a gutter from the chrome rows' buttons.
        list.edgeInsets = NSEdgeInsets(top: ChromeButton.rowHeight - Self.titleBarHeight, left: Metrics.gutter, bottom: 0, right: 0)
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
        for (index, host) in snapshot.hosts.enumerated() {
            if snapshot.showsHostHeaders {
                if index > 0, let previous = list.arrangedSubviews.last {
                    list.setCustomSpacing(20, after: previous)
                }
                add(HostHeaderRow(title: host.title, remote: !host.server.isLocal, match: snapshot.query))
            }
            buildHost(host, cardNumber: &cardNumber)
        }
    }

    private func buildHost(_ host: SidebarSnapshot.HostEntry, cardNumber: inout Int) {
        if let cards = host.openTabs { return buildOpenTabs(cards, creating: host.groups.flatMap(\.creating), cardNumber: &cardNumber) }
        let terminals = host.terminals.map { cardView($0, hint: hint(.tabs, &cardNumber)) }
        terminals.forEach { add($0) }
        divide(terminals, in: list)
        for group in host.groups {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.spacing = list.spacing
            stack.alignment = .leading
            let header = headerView(group)
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(2, after: header)
            header.translatesAutoresizingMaskIntoConstraints = false
            header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            var cards: [SidebarCardView] = []
            for card in collapsedProjects.contains(group.project) ? [] : group.cards {
                let view = cardView(card, hint: hint(.tabs, &cardNumber))
                view.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                cards.append(view)
            }
            divide(cards, in: stack)
            for name in collapsedProjects.contains(group.project) ? [] : group.creating {
                let row = CreatingRow(name: name)
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            add(stack)
        }
    }

    /// Open Tabs: the host's open tabs in the listing's order, each card
    /// naming its project.
    private func buildOpenTabs(_ cards: [SidebarSnapshot.CardEntry], creating: [String], cardNumber: inout Int) {
        let views = cards.map { cardView($0, hint: hint(.tabs, &cardNumber)) }
        views.forEach { add($0) }
        divide(views, in: list)
        for name in creating {
            add(CreatingRow(name: name))
        }
    }

    /// Stacks consecutive cards with no gap and a hairline between them,
    /// clear beside the selected or hovered card.
    private func divide(_ cards: [SidebarCardView], in stack: NSStackView) {
        for (card, next) in zip(cards, cards.dropFirst()) {
            guard let index = stack.arrangedSubviews.firstIndex(of: next) else { continue }
            let divider = CardDivider()
            divider.above = card
            divider.below = next
            card.dividers.append(divider)
            next.dividers.append(divider)
            divider.refresh()
            divider.translatesAutoresizingMaskIntoConstraints = false
            stack.insertArrangedSubview(divider, at: index)
            divider.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
            stack.setCustomSpacing(0, after: card)
            stack.setCustomSpacing(0, after: divider)
        }
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
        let header = card.header.map { SidebarCardView.Header(title: $0.title, icon: $0.icon) }
        let view = SidebarCardView(data: card.data, hint: hint, header: header)
        let target = card.target
        view.onClick = { [weak self] in self?.model.select(target) }
        view.onClose = { [weak self] in self?.model.close(target) }
        view.onPaneClick = { [weak self] pane in self?.model.focusPane(pane) }
        view.menuProvider = { [weak self, weak view] in self?.cardMenu(card, anchor: view) }
        return view
    }

    private func headerView(_ group: SidebarSnapshot.GroupEntry) -> NSView {
        guard let project = model.state.project(group.project) else { return NSView() }
        let header = ProjectHeaderRow(
            project: project, title: group.title, icon: group.icon,
            remoteName: model.serverName(project.serverId), canCreateWorktree: group.canCreateWorktree,
            match: model.nameFilter
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
        guard let window = view.window else { return }
        let canReorder = model.appearance.sidebarProjectOrder == .manual
            && model.state.project(project)?.status == .available
        let start = event.locationInWindow
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if !moved, header.bounds.contains(header.convert(next.locationInWindow, from: nil)) {
                    if !collapsedProjects.insert(project).inserted { collapsedProjects.remove(project) }
                    if let snapshot { rebuild(snapshot) }
                }
                break
            }
            if !moved, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) < 4 { continue }
            moved = true
            guard canReorder else { continue }
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
            guard let project = model.state.projects.first(where: { $0.tabs.contains { $0.id == tab } })?.id else { return nil }
            return NSMenu.make([
                model.newPaneSubmenu(in: project, tab: tab),
                .separator(),
                ClosureMenuItem("Close Tab") { [weak self] in
                    guard let self else { return }
                    self.model.selectTab(tab)
                    self.model.closeTab()
                },
            ])
        case .project(let id):
            guard let project = model.state.project(id) else { return nil }
            if project.parentId == nil && !card.data.primary { return projectMenu(id, anchor: anchor) }
            return worktreeMenu(project, primary: project.parentId == nil, anchor: anchor)
        }
    }

    private func terminalItems(_ id: ProjectId) -> [NSMenuItem] {
        [
            model.newPaneSubmenu(in: id),
            ClosureMenuItem("Detached Terminals…") { [weak self] in self?.actions?.openPalette(.terminals(id)) },
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
        if !project.serverId.isLocal {
            items.append(.submenu("Forwarded Ports", model.portForwardItems(project.serverId)))
        }
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

    /// The filter glyph's menu: which hosts the sidebar lists.
    private func hostMenu() -> NSMenu {
        model.remoteController.hostFilterMenu(selected: model.appearance.sidebarHost) { [weak self] host in
            self?.model.setSidebarHost(host)
            if case .server(let id) = host { self?.model.connectOnDemand(id) }
        }
    }

    /// The filter glyph's right-click menu: the hosts, then the workspace.
    private func filterMenu() -> NSMenu {
        let menu = hostMenu()
        menu.addItem(.separator())
        menu.addItem(.submenu("Workspace", workspaceFilterItems(anchor: filter)))
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
        let side = ChromeButton.side
        topRow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ChromeButton.rowHeight)
        let y = Metrics.gutter
        toggle.frame = CGRect(x: max(trafficLightsEnd, Metrics.gutter), y: y, width: side, height: side)
        CircleButton.layOut([commandPalette, newTab], trailingAt: bounds.width - ChromeButton.gap, y: y)
        let footerHeight = ChromeButton.rowHeight
        footer.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
        CircleButton.layOut([addButton, serversButton], trailingAt: bounds.width - ChromeButton.gap, y: y)
        filter.frame = CGRect(x: Metrics.gutter, y: y, width: max(addButton.frame.minX - ChromeButton.gap - Metrics.gutter, side), height: side)
        let scrollTop = Self.titleBarHeight
        scroll.frame = CGRect(x: 0, y: scrollTop, width: bounds.width, height: max(footer.frame.minY - scrollTop, 0))
        resizeHandle.frame = CGRect(x: bounds.width - 3, y: 0, width: 6, height: bounds.height)
    }
}

/// The sidebar's background view.
final class SidebarRootView: ThemedView {
    weak var controller: SidebarViewController?

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (theme.glassEnabled ? NSColor.clear : theme.chrome).cgColor
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
