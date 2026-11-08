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
    private let settingsButton = UIBarButtonItem()
    private let filterButton = UIBarButtonItem()
    private lazy var newTabButton = makeNewTabButton()
    /// Which tabs the filter button lets through.
    private enum Shown: CaseIterable {
        case all, agents, terminals, attention

        var title: String {
            switch self {
            case .all: "All Tabs"
            case .agents: "Agents"
            case .terminals: "Terminals"
            case .attention: "Needs Attention"
            }
        }

        /// What the list says when nothing is left.
        var emptyTitle: String {
            switch self {
            case .all: "No Open Tabs"
            case .agents: "No Agents"
            case .terminals: "No Terminals"
            case .attention: "Nothing Needs Attention"
            }
        }

        var image: String {
            switch self {
            case .all: "rectangle.stack"
            case .agents: "sparkles"
            case .terminals: "apple.terminal"
            case .attention: "exclamationmark.bubble"
            }
        }

        func admits(_ card: TabCard) -> Bool {
            switch self {
            case .all: true
            case .agents: card.panes.contains { if case .agent = $0.kind { true } else { false } }
            case .terminals: card.panes.contains { $0.kind == .terminal }
            case .attention: card.status == .attention || card.status == .error
            }
        }
    }
    private var shown = Shown.all
    /// The one Mac whose tabs show; nil for all of them.
    private var shownServer: ServerId?
    /// Shows a tab in the detail column.
    var onOpen: ((ServerModel, TabCard) -> Void)?
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
            configuration.headerMode = (self?.visibleServers.count ?? 0) > 1 ? .supplementary : .none
            configuration.trailingSwipeActionsConfigurationProvider = { path in self?.swipeActions(path) }
            // A hairline between cards, as wide as a card's fill, except beside
            // the selected one and after the last.
            configuration.itemSeparatorHandler = { path, separators in
                guard let self else { return separators }
                var separators = separators
                let next = IndexPath(item: path.item + 1, section: path.section)
                let selected = Set(self.collectionView.indexPathsForSelectedItems ?? [])
                let isLast = path.item + 1 >= self.collectionView.numberOfItems(inSection: path.section)
                if isLast || selected.contains(path) || selected.contains(next) { separators.bottomSeparatorVisibility = .hidden }
                separators.topSeparatorVisibility = .hidden
                let inset = TabCardCell.cardInset
                separators.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
                return separators
            }
            return .list(using: configuration, layoutEnvironment: environment)
        }
        collectionView.collectionViewLayout = layout
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.prefersLargeTitles = false
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
        navigationItem.largeTitleDisplayMode = .never
        // Clear, so an iPad's sidebar shows its own material.
        collectionView.backgroundColor = isPhone ? .systemBackground : .clear
        // Cards fade under the bar instead of meeting a hairline.
        collectionView.topEdgeEffect.style = .soft
        configureDataSource()
        let search = UISearchController()
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search"
        navigationItem.searchController = search
        // A phone searches from a field in the bottom bar, beside New Tab; an
        // iPad's sidebar keeps its bar buttons free.
        navigationItem.preferredSearchBarPlacement = isPhone ? .integrated : .stacked

        settingsButton.primaryAction = UIAction(image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.onSettings?()
        }
        settingsButton.accessibilityLabel = "Settings"
        filterButton.accessibilityLabel = "Filter"
        navigationItem.rightBarButtonItems = [settingsButton, filterButton]

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
        let servers = visibleServers
        if servers.count == 1, let server = servers.first {
            title = server.server.name
            navigationItem.subtitle = Self.describe(server.status)
        } else {
            title = "Tabs"
            navigationItem.subtitle = nil
        }
        let filtering = shown != .all || shownServer != nil
        filterButton.image = UIImage(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        filterButton.menu = filterMenu()
        if isPhone {
            toolbarItems = [navigationItem.searchBarPlacementBarButtonItem, .flexibleSpace(), newTabButton]
        } else {
            navigationItem.rightBarButtonItems = [newTabButton, .fixedSpace(0), settingsButton, filterButton]
        }
        newTabButton.isEnabled = app.servers.contains { $0.board != nil }
        for server in app.servers {
            server.isImage = { UIImage(data: $0) != nil }
        }
        apply(servers)
        updateHeaders()
    }

    /// Headers aren't items, so a snapshot never reconfigures them; their Mac's
    /// status is read here, where a change brings the next update.
    private func updateHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let header = collectionView.supplementaryView(forElementKind: kind, at: path) as? UICollectionViewListCell,
                  let id = dataSource.sectionIdentifier(for: path.section), let server = app.server(id) else { continue }
            configure(header, for: server)
        }
        // Also for headers scrolled out of view, so they're right when they return.
        for server in app.servers { _ = server.status }
    }

    private func configure(_ header: UICollectionViewListCell, for server: ServerModel) {
        var content = UIListContentConfiguration.header()
        content.text = server.server.name
        content.secondaryText = Self.describe(server.status)
        content.prefersSideBySideTextAndSecondaryText = true
        header.contentConfiguration = content
    }

    static func describe(_ status: ServerModel.Status) -> String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .offline: "Offline · retrying"
        case .needsPairing: "Not paired"
        }
    }

    /// The paired Macs the list shows: the chosen one, else all of them.
    private var visibleServers: [ServerModel] {
        let servers = app.servers
        guard let shownServer, let server = servers.first(where: { $0.id == shownServer }) else { return servers }
        return [server]
    }

    private func show(server: ServerId?) {
        shownServer = server
        // Headings come and go with the number of Macs shown.
        collectionView.collectionViewLayout.invalidateLayout()
        setNeedsUpdateProperties()
    }

    /// Which tabs show: by what runs in them and, with more than one, by Mac.
    private func filterMenu() -> UIMenu {
        let kinds = Shown.allCases.map { kind in
            UIAction(title: kind.title, image: UIImage(systemName: kind.image), state: shown == kind ? .on : .off) { [weak self] _ in
                self?.shown = kind
                self?.setNeedsUpdateProperties()
            }
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: kinds)]
        let servers = app.servers
        if servers.count > 1 {
            let all = UIAction(title: "All Macs", image: UIImage(systemName: "laptopcomputer.and.iphone"),
                               state: shownServer == nil ? .on : .off) { [weak self] _ in
                self?.show(server: nil)
            }
            let macs = servers.map { model in
                UIAction(title: model.server.name, subtitle: Self.describe(model.status),
                         image: UIImage(systemName: "laptopcomputer"),
                         state: shownServer == model.id ? .on : .off) { [weak self] _ in
                    self?.show(server: model.id)
                    model.retryNow()
                }
            }
            children.append(UIMenu(options: .displayInline, children: [all] + macs))
        }
        return UIMenu(title: "Show", children: children)
    }

    // MARK: New tabs

    /// Opens the New Tab sheet: the desktop's New in Project page as a form.
    private func makeNewTabButton() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"))
        item.primaryAction = UIAction(image: UIImage(systemName: "square.and.pencil")) { [weak self, weak item] _ in
            self?.showNewTab(kind: nil, source: item)
        }
        item.accessibilityLabel = "New Tab"
        return item
    }

    /// The New Tab sheet, on the chosen tab's Mac and in its project, else
    /// the first connected Mac's Home. `kind` nil opens the kind used last.
    func showNewTab(kind: MobilePaneKind?, source: UIBarButtonItem? = nil) {
        let current = selected.flatMap { cards[$0] }
        guard let server = current?.server ?? app.servers.first(where: { $0.board != nil }) else { return }
        let presenter = splitViewController ?? self
        guard presenter.presentedViewController == nil else { return }
        NewTabViewController.present(over: presenter, app: app, server: server, kind: kind,
                                     location: current?.card.project.id, source: source) { [weak self] server, tab in
            guard let card = server.cards.first(where: { $0.id == tab }) else { return }
            self?.open(card, on: server)
        }
    }

    /// A terminal or agent tab in Home at once, for ⌘T and ⌥⌘A.
    func newTab(_ kind: MobilePaneKind) {
        let current = selected.flatMap { cards[$0]?.server }
        guard let server = current ?? app.servers.first(where: { $0.board != nil }),
              let tab = try? server.newTab(kind, size: Size(cols: 80, rows: 24)),
              let card = server.cards.first(where: { $0.id == tab }) else { return }
        open(card, on: server)
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
            configure(header, for: server)
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
                guard shown.admits(card) else { return false }
                guard !query.isEmpty else { return true }
                let fields = [card.title, card.location, card.branch, card.projectName, server.server.name] + card.rows.map(\.title)
                return fields.compactMap { $0 }.contains { $0.lowercased().contains(query) }
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
            if empty && filter.isEmpty && shown != .all {
                var value = UIContentUnavailableConfiguration.empty()
                value.image = UIImage(systemName: shown.image)
                value.text = shown.emptyTitle
                var button = UIButton.Configuration.glass()
                button.title = "Show All Tabs"
                value.button = button
                value.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    self?.shown = .all
                    self?.setNeedsUpdateProperties()
                }
                configuration = value
            } else if empty && filter.isEmpty {
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
