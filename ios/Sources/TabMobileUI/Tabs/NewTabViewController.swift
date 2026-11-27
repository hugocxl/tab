import TabMobileKit
import TabProtocol
import UIKit

/// The New Tab sheet: the desktop's New Terminal and New Agent in Project
/// pages as a short form. Pick what opens and where, and for a Git project
/// whether it opens in the checkout or a new worktree; the choices come back
/// the next time.
final class NewTabViewController: UICollectionViewController {
    private let app: AppModel
    private let form: NewTabForm
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let kindControl = UISegmentedControl()
    private let checkoutControl = UISegmentedControl()
    private let branchField = UITextField()
    private let remoteSwitch = UISwitch()
    private var kindsShown: [MobilePaneKind] = []
    private lazy var createButton = UIBarButtonItem(title: "Create", style: .prominent, target: self,
                                                    action: #selector(createCommand))
    /// What each row showed when last configured, so only rows that change
    /// are configured again and an open menu stays open.
    private var shown: [Item: [String]] = [:]
    /// Called with the new tab, after the sheet closes.
    var onCreated: ((ServerModel, TabId) -> Void)?

    private enum Item: Hashable {
        case kinds, provider, mac, location, checkout, repository, branch, base, remote
    }

    /// Opens the sheet over `presenter`, from `source` when it's a bar button.
    /// `kind` and `checkout` nil start from the ones used last.
    static func present(over presenter: UIViewController, app: AppModel, server: ServerModel, kind: MobilePaneKind?,
                        location: ProjectId?, checkout: NewTabForm.Checkout? = nil, source: UIBarButtonItem?,
                        onCreated: @escaping (ServerModel, TabId) -> Void) {
        let remembered = Remembered.load()
        guard let form = NewTabForm(server: server, kind: kind ?? remembered.kind(on: server), location: location,
                                    checkout: checkout ?? NewTabForm.Checkout(rawValue: remembered.checkout) ?? .current)
        else { return }
        let controller = NewTabViewController(app: app, form: form)
        controller.onCreated = onCreated
        let navigation = UINavigationController(rootViewController: controller)
        if let source, presenter.traitCollection.horizontalSizeClass == .regular {
            navigation.modalPresentationStyle = .popover
            navigation.popoverPresentationController?.sourceItem = source
            navigation.preferredContentSize = CGSize(width: 420, height: 560)
        } else {
            navigation.modalPresentationStyle = .pageSheet
        }
        if let sheet = navigation.sheetPresentationController ?? navigation.popoverPresentationController?.adaptiveSheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        presenter.present(navigation, animated: true)
    }

    private init(app: AppModel, form: NewTabForm) {
        self.app = app
        self.form = form
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = .clear
        configuration.footerMode = .supplementary
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Tab"
        // Clear, so the sheet's glass shows through.
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.topEdgeEffect.style = .soft
        collectionView.keyboardDismissMode = .interactive
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        configureControls()
        configureDataSource()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Create", action: #selector(createCommand), input: "\r", modifierFlags: .command)]
    }

    @objc private func createCommand() { create() }

    // MARK: Controls

    private func configureControls() {
        checkoutControl.insertSegment(action: UIAction(title: "Current Checkout") { [weak self] _ in
            self?.form.checkout = .current
        }, at: 0, animated: false)
        checkoutControl.insertSegment(action: UIAction(title: "New Worktree") {
            [weak self] _ in self?.form.checkout = .worktree
        }, at: 1, animated: false)
        checkoutControl.accessibilityLabel = "Open In"

        branchField.placeholder = "Branch name or #PR"
        branchField.autocapitalizationType = .none
        branchField.autocorrectionType = .no
        branchField.spellCheckingType = .no
        branchField.smartDashesType = .no
        branchField.returnKeyType = .go
        branchField.clearButtonMode = .whileEditing
        branchField.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        branchField.adjustsFontForContentSizeCategory = true
        branchField.accessibilityLabel = "Branch"
        branchField.addAction(UIAction { [weak self] _ in
            self?.form.name = self?.branchField.text ?? ""
        }, for: .editingChanged)
        branchField.addAction(UIAction { [weak self] _ in self?.create() }, for: .editingDidEndOnExit)

        remoteSwitch.addAction(UIAction { [weak self] _ in
            self?.form.fromRemote = self?.remoteSwitch.isOn ?? true
        }, for: .valueChanged)
    }

    /// One segment per kind the Mac opens, rebuilt when that changes.
    private func updateKindControl() {
        var kinds: [MobilePaneKind] = [.terminal, .agent(.claude)]
        if form.server.sharesSimulators { kinds.append(.simulator) }
        if kinds != kindsShown {
            kindsShown = kinds
            kindControl.removeAllSegments()
            for (index, kind) in kinds.enumerated() {
                kindControl.insertSegment(action: UIAction(title: Self.title(kind)) {
                    [weak self] _ in self?.choose(kind)
                }, at: index, animated: false)
            }
            kindControl.accessibilityLabel = "Kind"
        }
        kindControl.selectedSegmentIndex = kinds.firstIndex { Self.sameSegment($0, form.kind) } ?? 0
    }

    private func choose(_ kind: MobilePaneKind) {
        guard !Self.sameSegment(kind, form.kind) else { return }
        // An agent keeps the provider chosen last.
        form.kind = kind == .agent(.claude) ? .agent(Remembered.load().provider) : kind
    }

    private static func title(_ kind: MobilePaneKind) -> String {
        switch kind {
        case .terminal: "Terminal"
        case .agent: "Agent"
        case .simulator: "Simulator"
        }
    }

    private static func sameSegment(_ left: MobilePaneKind, _ right: MobilePaneKind) -> Bool {
        switch (left, right) {
        case (.terminal, .terminal), (.agent, .agent), (.simulator, .simulator): true
        default: false
        }
    }

    // MARK: Updating

    override func updateProperties() {
        super.updateProperties()
        updateKindControl()
        checkoutControl.selectedSegmentIndex = form.checkout == .worktree ? 1 : 0
        if branchField.text != form.name { branchField.text = form.name }
        remoteSwitch.isOn = form.fromRemote

        createButton.isEnabled = form.canCreate
        if form.isCreating {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        } else {
            navigationItem.rightBarButtonItem = createButton
        }
        isModalInPresentation = form.isCreating
        collectionView.isUserInteractionEnabled = !form.isCreating

        // One list, in the order the choices are made.
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(form.kind == .terminal || form.kind == .simulator ? [.kinds] : [.kinds, .provider])
        if app.servers.count > 1 { snapshot.appendItems([.mac]) }
        snapshot.appendItems([.location])
        switch form.repository {
        case .none: break
        case .loading, .failed: snapshot.appendItems([.checkout, .repository])
        case .loaded:
            snapshot.appendItems([.checkout])
            if form.checkout == .worktree {
                snapshot.appendItems([.branch])
                if form.choosesBase { snapshot.appendItems([.base]) }
                if form.choosesBase, case .loaded(_, _, _?) = form.repository { snapshot.appendItems([.remote]) }
            }
        }
        let next = Dictionary(uniqueKeysWithValues: snapshot.itemIdentifiers.map { ($0, signature($0)) })
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { shown[$0] != nil && shown[$0] != next[$0] })
        shown = next
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        // The footer isn't an item, so a snapshot never reconfigures it.
        let kind = UICollectionView.elementKindSectionFooter
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let footer = collectionView.supplementaryView(forElementKind: kind, at: path) as? UICollectionViewListCell else {
                continue
            }
            configureFooter(footer)
        }
    }

    // MARK: Cells

    private func configureDataSource() {
        let control = UICollectionView.CellRegistration<ControlCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .kinds: cell.host(kindControl)
            case .checkout: cell.host(checkoutControl)
            case .branch: cell.host(branchField)
            default: break
            }
        }
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter) { [weak self] footer, _, _ in
            self?.configureFooter(footer)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, item in
            switch item {
            case .kinds, .checkout, .branch: view.dequeueConfiguredReusableCell(using: control, for: path, item: item)
            default: view.dequeueConfiguredReusableCell(using: row, for: path, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: footer, for: path)
        }
    }

    /// The footer says what Create does.
    private func configureFooter(_ footer: UICollectionViewListCell) {
        var content = UIListContentConfiguration.footer()
        content.text = form.summary
        footer.contentConfiguration = content
    }

    /// Everything a row shows, read here so the update follows it.
    private func signature(_ item: Item) -> [String] {
        switch item {
        case .provider: ["\(form.kind)"]
        case .mac: [form.server.id.description, TabListViewController.describe(form.server.status)]
        case .location: [form.location.description, form.locationProject?.name ?? ""]
        case .repository: ["\(form.repository)"]
        case .base: [form.effectiveBase ?? ""] + form.branches.map(\.name)
        case .remote: ["\(form.repository)"]
        case .kinds, .checkout, .branch: []
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = UIListContentConfiguration.valueCell()
        cell.accessories = []
        switch item {
        case .provider:
            guard case .agent(let provider) = form.kind else { return }
            content.text = "Agent"
            content.secondaryText = provider.name
            cell.accessories = [.popUpMenu(UIMenu(children: AgentChatProvider.allCases.map { option in
                UIAction(title: option.name, state: option == provider ? .on : .off) { [weak self] _ in
                    self?.form.kind = .agent(option)
                }
            }))]
        case .mac:
            content.image = UIImage(systemName: "laptopcomputer")
            content.text = form.server.server.name
            content.secondaryText = TabListViewController.describe(form.server.status)
            // Without the other Macs' statuses, so their reconnecting doesn't update the sheet.
            cell.accessories = [.popUpMenu(UIMenu(children: app.servers.map { server in
                UIAction(title: server.server.name, attributes: server.home == nil ? .disabled : [],
                         state: server === form.server ? .on : .off) { [weak self] _ in self?.form.choose(server: server) }
            }))]
        case .location:
            content = .subtitleCell()
            let project = form.locationProject
            content.image = UIImage(systemName: Self.symbol(project))
            content.text = project?.home == false ? project?.name : "Home"
            content.secondaryText = project.map { ServerModel.abbreviate($0.directory) }
            content.secondaryTextProperties.color = .secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .repository:
            if case .failed(let message) = form.repository {
                content = .cell()
                content.text = "Couldn't read the project's Git state"
                content.secondaryText = message
                content.secondaryTextProperties.color = .secondaryLabel
            } else {
                content = .cell()
                content.text = "Reading Git…"
                content.textProperties.color = .secondaryLabel
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
            }
        case .base:
            content.text = "From"
            content.secondaryText = form.effectiveBase ?? "Default Branch"
            let current = form.effectiveBase
            cell.accessories = [.popUpMenu(UIMenu(children: form.branches.map { branch in
                UIAction(title: branch.name, subtitle: branch.isDefault ? "Default branch" : nil,
                         state: branch.name == current ? .on : .off) { [weak self] _ in
                    self?.form.base = branch.name
                }
            }))]
        case .remote:
            guard case .loaded(_, _, let remote?) = form.repository else { return }
            content = .cell()
            content.text = "Fetch from \(remote) First"
            cell.accessories = [.customView(configuration: .init(customView: remoteSwitch, placement: .trailing()))]
        case .kinds, .checkout, .branch:
            break
        }
        cell.contentConfiguration = content
    }

    static func symbol(_ project: ProjectDescriptor?) -> String {
        guard let project, !project.home else { return "house" }
        return project.parentId != nil ? "arrow.triangle.branch" : "folder"
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        // Menu rows open their menu on selection.
        [.location, .provider, .mac, .base].contains(dataSource.itemIdentifier(for: indexPath))
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .location else { return }
        navigationController?.pushViewController(LocationPickerViewController(form: form), animated: true)
    }

    // MARK: Creating

    private func create() {
        guard form.canCreate else { return }
        view.endEditing(true)
        let server = form.server
        Remembered(form).save()
        Task {
            let tab = await form.create(size: Size(cols: 80, rows: 24)) { hooks in
                await self.approve(hooks)
            }
            guard let tab else {
                showFailure()
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let onCreated = onCreated
            dismiss(animated: true) { onCreated?(server, tab) }
        }
    }

    private func showFailure() {
        guard let failure = form.failure else { return }
        let alert = UIAlertController(title: "Couldn't Open the Tab", message: failure, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Asks before a new worktree runs its setup commands, as the desktop
    /// does, and remembers the answer until they change.
    private func approve(_ hooks: [WorktreeHook]) async -> Bool {
        let commands = hooks.map(\.command)
        guard case .loaded(let repository, _, _) = form.repository else { return false }
        let key = "newTab.approvedSetup.\(repository)"
        if UserDefaults.standard.stringArray(forKey: key) == commands { return true }
        let list = hooks.map { "[\($0.project ? "Project" : "Per-machine")] \($0.command)" }.joined(separator: "\n")
        let run = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(
                title: "Run Setup Commands?",
                message: "The new worktree can run these setup commands in its terminal:\n\(list)\n\n"
                    + "Tab remembers your choice until they change. Skip creates it without them.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Skip", style: .cancel) { _ in continuation.resume(returning: false) })
            let run = UIAlertAction(title: "Run", style: .default) { _ in continuation.resume(returning: true) }
            alert.addAction(run)
            alert.preferredAction = run
            present(alert, animated: true)
        }
        if run { UserDefaults.standard.set(commands, forKey: key) }
        return run
    }

    /// The kind, agent and checkout choice the sheet opens with next time.
    private struct Remembered: Codable {
        var kind = "terminal"
        var provider = AgentChatProvider.claude
        var checkout = NewTabForm.Checkout.current.rawValue

        static let key = "newTab.choices"

        init() {}

        @MainActor
        init(_ form: NewTabForm) {
            self = Self.load()
            switch form.kind {
            case .terminal: kind = "terminal"
            case .agent(let provider):
                kind = "agent"
                self.provider = provider
            case .simulator: kind = "simulator"
            }
            if case .loaded = form.repository { checkout = form.checkout.rawValue }
        }

        static func load() -> Remembered {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let value = try? JSONDecoder().decode(Remembered.self, from: data) else { return Remembered() }
            return value
        }

        func save() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }

        @MainActor
        func kind(on server: ServerModel) -> MobilePaneKind {
            switch kind {
            case "agent": .agent(provider)
            case "simulator" where server.sharesSimulators: .simulator
            default: .terminal
            }
        }
    }
}

/// A list cell that shows one control across its width.
private final class ControlCell: UICollectionViewListCell {
    private weak var hosted: UIView?

    func host(_ control: UIView) {
        guard hosted !== control else { return }
        hosted?.removeFromSuperview()
        hosted = control
        control.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(control)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            control.topAnchor.constraint(equalTo: margins.topAnchor),
            control.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }
}

/// Every project and worktree of the form's Mac, then Home, to search and pick
/// where the new tab opens.
private final class LocationPickerViewController: UICollectionViewController, UISearchResultsUpdating {
    private let form: NewTabForm
    private var dataSource: UICollectionViewDiffableDataSource<Int, ProjectId>!
    private var query = ""

    init(form: NewTabForm) {
        self.form = form
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = .clear
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Location"
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.topEdgeEffect.style = .soft
        collectionView.keyboardDismissMode = .onDrag
        let search = UISearchController()
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search projects and worktrees"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, ProjectId> { [weak self] cell, _, id in
            guard let self, let project = form.server.project(id) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.image = UIImage(systemName: NewTabViewController.symbol(project))
            content.text = project.home ? "Home" : project.name
            content.secondaryText = ServerModel.abbreviate(project.directory)
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            // Worktrees sit under their repository, unless a search lists them alone.
            cell.indentationLevel = project.parentId != nil && query.isEmpty ? 1 : 0
            cell.accessories = id == form.location ? [.checkmark()] : []
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, id in
            view.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
    }

    override func updateProperties() {
        super.updateProperties()
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = form.locations.filter { project in
            needle.isEmpty || [project.home ? "Home" : project.name, project.directory.rawValue]
                .contains { $0.lowercased().contains(needle) }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, ProjectId>()
        snapshot.appendSections([0])
        snapshot.appendItems(shown.map(\.id))
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        setNeedsUpdateProperties()
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        form.choose(location: id)
        navigationController?.popViewController(animated: true)
    }
}
