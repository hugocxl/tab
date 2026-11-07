import TabMobileKit
import TabProtocol
import UIKit

/// The home screen: the desktop sidebar's Open Tabs layout. Every open tab of
/// every paired Mac, oldest first, each card saying what runs there, where,
/// and in which project. With more than one Mac, each gets a heading.
final class TabListViewController: UICollectionViewController {
    private let app: AppModel
    private var dataSource: UICollectionViewDiffableDataSource<ServerId, TabId>!
    private var cards: [TabId: (server: ServerModel, card: TabCard)] = [:]
    private var icons: [ProjectId: UIImage] = [:]
    private var filter = ""
    private let statusView = UIContentUnavailableView(configuration: .empty())
    /// Shows a tab in the detail column.
    var onOpen: ((ServerModel, TabCard) -> Void)?
    /// Starts a tab in a project that has none.
    var onOpenProject: ((ServerModel, ProjectDescriptor) -> Void)?
    var onSettings: (() -> Void)?
    var onPair: (() -> Void)?
    private(set) var selected: TabId?
    /// The tab shown last time, reopened on an iPad once its Mac reports it.
    private var restoring = LastTab.load()

    private struct LastTab: Codable {
        var server: UUID
        var tab: UUID

        static let key = "lastTab"

        static func load() -> LastTab? {
            guard UIDevice.current.userInterfaceIdiom == .pad, let data = UserDefaults.standard.data(forKey: key) else {
                return nil
            }
            return try? JSONDecoder().decode(LastTab.self, from: data)
        }

        func save() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    init(app: AppModel) {
        self.app = app
        super.init(collectionViewLayout: UICollectionViewLayout())
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.backgroundColor = .clear
            configuration.headerMode = (self?.app.servers.count ?? 0) > 1 ? .supplementary : .none
            configuration.separatorConfiguration.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
            configuration.trailingSwipeActionsConfigurationProvider = { path in self?.swipeActions(path) }
            // A hairline between cards, except beside the selected one.
            configuration.itemSeparatorHandler = { path, separators in
                guard let self else { return separators }
                var separators = separators
                let next = IndexPath(item: path.item + 1, section: path.section)
                let selected = Set(self.collectionView.indexPathsForSelectedItems ?? [])
                if selected.contains(path) || selected.contains(next) { separators.bottomSeparatorVisibility = .hidden }
                separators.topSeparatorVisibility = .hidden
                return separators
            }
            return .list(using: configuration, layoutEnvironment: environment)
        }
        collectionView.collectionViewLayout = layout
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.setToolbarHidden(!isPhone, animated: animated)
        if splitViewController?.isCollapsed ?? true, let selection = collectionView.indexPathsForSelectedItems {
            selection.forEach { collectionView.deselectItem(at: $0, animated: animated) }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A phone's tab is pushed over the list; the bottom bar stays with the list.
        if isPhone { navigationController?.setToolbarHidden(true, animated: animated) }
    }

    private var isPhone: Bool { traitCollection.userInterfaceIdiom == .phone }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        // Clear, so an iPad's sidebar shows its own material.
        collectionView.backgroundColor = .clear
        configureDataSource()
        let search = UISearchController()
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search"
        navigationItem.searchController = search
        // A phone searches from a field in the bottom bar, beside New Tab; an
        // iPad's sidebar keeps its bar buttons free.
        navigationItem.preferredSearchBarPlacement = isPhone ? .integrated : .stacked

        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            self?.onSettings?()
        })
        settings.accessibilityLabel = "Settings"
        navigationItem.leftBarButtonItem = settings

        statusView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusView)
        NSLayoutConstraint.activate([
            statusView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    override func updateProperties() {
        super.updateProperties()
        let servers = app.servers
        if servers.count == 1, let server = servers.first {
            title = server.server.name
            navigationItem.subtitle = Self.describe(server.status)
        } else {
            title = "Tabs"
            navigationItem.subtitle = nil
        }
        // An iPad sidebar counts a title menu as a bar item and folds + away;
        // there, pairing lives in Settings.
        navigationItem.titleMenuProvider = traitCollection.userInterfaceIdiom == .phone
            ? { [weak self] _ in self?.serverMenu() } : nil
        if isPhone {
            toolbarItems = [navigationItem.searchBarPlacementBarButtonItem, .flexibleSpace(), newTabButton()]
        } else {
            navigationItem.rightBarButtonItem = newTabButton()
        }
        for server in servers {
            server.isImage = { UIImage(data: $0) != nil }
        }
        apply(servers)
    }

    static func describe(_ status: ServerModel.Status) -> String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .offline: "Offline · retrying"
        case .needsPairing: "Not paired"
        }
    }

    private func serverMenu() -> UIMenu {
        let servers = app.servers.map { model in
            UIAction(title: model.server.name, subtitle: Self.describe(model.status),
                     image: UIImage(systemName: "laptopcomputer")) { _ in model.retryNow() }
        }
        let pair = UIAction(title: "Pair Another Mac", image: UIImage(systemName: "qrcode.viewfinder")) { [weak self] _ in
            self?.onPair?()
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: servers), pair])
    }

    // MARK: New tabs

    /// The desktop's New Tab menu, for the kinds a phone opens, and a tab in
    /// any project that has none.
    private func newTabButton() -> UIBarButtonItem {
        let menu = UIMenu(title: "New Tab", children: app.servers.count > 1
            ? app.servers.map { server in UIMenu(title: server.server.name, children: newTabItems(server)) }
            : app.servers.first.map(newTabItems) ?? [])
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: menu)
        item.accessibilityLabel = "New Tab"
        item.isEnabled = app.servers.contains { $0.board != nil }
        return item
    }

    private func newTabItems(_ server: ServerModel) -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(title: "Terminal Tab", image: UIImage(systemName: "apple.terminal")) { [weak self] _ in
                self?.newTab(.terminal, on: server)
            },
            UIAction(title: "Agent Tab", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.newTab(.agent(.claude), on: server)
            },
        ]
        let projects = server.projectsWithoutTabs
        if !projects.isEmpty {
            items.append(UIMenu(title: "Open Project", image: UIImage(systemName: "folder"), children: projects.map { project in
                UIAction(title: project.name, subtitle: ServerModel.abbreviate(project.directory),
                         image: UIImage(systemName: project.kind == .worktree ? "arrow.triangle.branch" : "folder")) { [weak self] _ in
                    self?.onOpenProject?(server, project)
                }
            }))
        }
        return items
    }

    private func newTab(_ kind: MobilePaneKind, on server: ServerModel) {
        guard let tab = try? server.newTab(kind, size: Size(cols: 80, rows: 24)) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let card = server.cards.first(where: { $0.id == tab }) else { return }
        open(card, on: server)
    }

    /// A new tab on the chosen tab's Mac, else the first connected one.
    func newTab(_ kind: MobilePaneKind) {
        let current = selected.flatMap { cards[$0]?.server }
        guard let server = current ?? app.servers.first(where: { $0.board != nil }) else { return }
        newTab(kind, on: server)
    }

    // MARK: Keyboard navigation

    private var listedCards: [(server: ServerModel, card: TabCard)] {
        dataSource.snapshot().itemIdentifiers.compactMap { cards[$0] }
    }

    func selectTab(number: Int) {
        let listed = listedCards
        guard listed.indices.contains(number - 1) else { return }
        open(listed[number - 1].card, on: listed[number - 1].server)
    }

    func selectAdjacentTab(_ offset: Int) {
        let listed = listedCards
        guard !listed.isEmpty else { return }
        let current = listed.firstIndex { $0.card.id == selected }
        let next = current.map { ($0 + offset + listed.count) % listed.count } ?? (offset > 0 ? 0 : listed.count - 1)
        open(listed[next].card, on: listed[next].server)
    }

    func focusFilter() {
        guard let search = navigationItem.searchController else { return }
        search.isActive = true
        search.searchBar.becomeFirstResponder()
    }

    // MARK: Cards

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<TabCardCell, TabId> { [weak self] cell, _, id in
            guard let self, let entry = cards[id] else { return }
            cell.configure(entry.card, icon: icon(entry.card.iconProject, on: entry.server))
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
            guard let self, let id = dataSource.sectionIdentifier(for: path.section), let server = app.server(id) else { return }
            var content = UIListContentConfiguration.header()
            content.text = server.server.name
            content.secondaryText = Self.describe(server.status)
            content.prefersSideBySideTextAndSecondaryText = true
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, id in
            view.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
        dataSource.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: header, for: path)
        }
    }

    /// The project's icon, decoded once; starts the search on first use.
    private func icon(_ project: ProjectId?, on server: ServerModel) -> UIImage? {
        guard let project else { return nil }
        if let icon = icons[project] { return icon }
        guard let data = server.icon(project), let image = UIImage(data: data) else { return nil }
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        icons[project] = rendered
        return rendered
    }

    private func apply(_ servers: [ServerModel]) {
        var snapshot = NSDiffableDataSourceSnapshot<ServerId, TabId>()
        var next: [TabId: (ServerModel, TabCard)] = [:]
        let query = filter.lowercased()
        for server in servers {
            let cards = server.cards.filter { card in
                guard !query.isEmpty else { return true }
                return [card.name, card.header, card.branch ?? "", server.server.name, Self.headlineText(card.headline)]
                    .contains { $0.lowercased().contains(query) }
            }
            // Icons that arrived since: touching them registers the dependency.
            _ = server.projectIcons.count
            guard !cards.isEmpty || servers.count > 1 else { continue }
            snapshot.appendSections([server.id])
            snapshot.appendItems(cards.map(\.id), toSection: server.id)
            for card in cards { next[card.id] = (server, card) }
        }
        let changed = next.keys.filter { id in cards[id].map { $0.card != next[id]?.1 } ?? false }
        let iconsArrived = servers.contains { server in server.projectIcons.keys.contains { icons[$0] == nil } }
        cards = next.mapValues { (server: $0.0, card: $0.1) }
        snapshot.reconfigureItems(iconsArrived ? Array(next.keys) : changed)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        if let selected, let path = dataSource.indexPath(for: selected), splitViewController?.isCollapsed == false {
            collectionView.selectItem(at: path, animated: false, scrollPosition: [])
        }
        showStatus(servers, empty: next.isEmpty)
        restoreLastTab(servers)
    }

    private func restoreLastTab(_ servers: [ServerModel]) {
        guard let last = restoring, selected == nil, let server = servers.first(where: { $0.id.uuid == last.server }),
              server.board != nil else { return }
        if let entry = cards[TabId(uuid: last.tab)] {
            restoring = nil
            DispatchQueue.main.async { [weak self] in self?.open(entry.card, on: entry.server) }
        } else if !server.cards.isEmpty {
            // The Mac reports its tabs and that one is gone.
            restoring = nil
        }
    }

    private static func headlineText(_ headline: CardHeadline) -> String {
        switch headline {
        case let .agent(provider, task): task ?? provider.displayName
        case let .shell(name, directory): [name, directory ?? ""].joined(separator: " ")
        case .command(let text), .other(let text): text
        case .empty: ""
        }
    }

    private func showStatus(_ servers: [ServerModel], empty: Bool) {
        var configuration: UIContentUnavailableConfiguration?
        let connected = servers.contains { $0.board != nil }
        let server = servers.first
        switch server?.status {
        case .connecting? where !connected:
            configuration = .loading()
            configuration?.text = "Connecting to \(server?.server.name ?? "your Mac")…"
        case .offline(let reason)? where !connected:
            var value = UIContentUnavailableConfiguration.empty()
            value.image = UIImage(systemName: "wifi.exclamationmark")
            value.text = "Can't Reach \(server?.server.name ?? "Your Mac")"
            value.secondaryText = reason
            var button = UIButton.Configuration.glass()
            button.title = "Try Again"
            value.button = button
            value.buttonProperties.primaryAction = UIAction { _ in servers.forEach { $0.retryNow() } }
            configuration = value
        case .needsPairing(let reason)? where servers.count == 1:
            var value = UIContentUnavailableConfiguration.empty()
            value.image = UIImage(systemName: "lock.slash")
            value.text = "Pair Again"
            value.secondaryText = reason
            var button = UIButton.Configuration.prominentGlass()
            button.title = "Scan Pairing Code"
            value.button = button
            value.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onPair?() }
            configuration = value
        default:
            if empty && filter.isEmpty {
                var value = UIContentUnavailableConfiguration.empty()
                value.image = UIImage(systemName: "rectangle.stack.badge.plus")
                value.text = "No Open Tabs"
                value.secondaryText = "Start a terminal or an agent with +, or open a project."
                configuration = value
            } else if empty {
                configuration = .search()
            }
        }
        statusView.configuration = configuration ?? .empty()
        statusView.isHidden = configuration == nil
    }

    // MARK: Opening and closing

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let entry = cards[id] else { return }
        open(entry.card, on: entry.server)
    }

    func open(_ card: TabCard, on server: ServerModel) {
        selected = card.id
        restoring = nil
        LastTab(server: server.id.uuid, tab: card.id.uuid).save()
        server.markRead(sessions: Set(card.tab.panes.compactMap(\.content.activitySession)))
        if let path = dataSource.indexPath(for: card.id), splitViewController?.isCollapsed == false {
            collectionView.selectItem(at: path, animated: false, scrollPosition: [])
            collectionView.collectionViewLayout.invalidateLayout()
        }
        onOpen?(server, card)
    }

    private func swipeActions(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: path), let entry = cards[id] else { return nil }
        let close = UIContextualAction(style: .destructive, title: "Close Tab") { _, _, done in
            try? entry.server.closeTab(id)
            done(true)
        }
        close.image = UIImage(systemName: "checkmark")
        close.backgroundColor = .tintColor
        return UISwipeActionsConfiguration(actions: [close])
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                                 point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = indexPaths.first, let id = dataSource.itemIdentifier(for: path), let entry = cards[id] else {
            return nil
        }
        let server = entry.server
        let card = entry.card
        return UIContextMenuConfiguration(actionProvider: { _ in
            let anchor = card.tab.panes.last?.id
            let size = Size(cols: 80, rows: 24)
            let newPane = UIMenu(title: "New Pane", image: UIImage(systemName: "plus.square.on.square"), children: [
                UIAction(title: "Terminal", image: UIImage(systemName: "apple.terminal")) { _ in
                    _ = try? server.newPane(.terminal, project: card.project.id, beside: anchor, size: size)
                },
                UIAction(title: "Agent", image: UIImage(systemName: "sparkles")) { _ in
                    _ = try? server.newPane(.agent(.claude), project: card.project.id, beside: anchor, size: size)
                },
            ])
            var children: [UIMenuElement] = [newPane]
            if !card.project.home {
                children.append(UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = card.project.directory.rawValue
                })
            }
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
                    try? server.closeTab(id)
                },
            ]))
            return UIMenu(children: children)
        })
    }
}

extension TabListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        filter = searchController.searchBar.text ?? ""
        setNeedsUpdateProperties()
    }
}
