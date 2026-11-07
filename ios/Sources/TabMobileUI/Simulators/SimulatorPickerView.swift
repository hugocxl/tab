import TabProtocol
import UIKit

/// The server's simulators and emulators to choose from, iOS first, each
/// with its OS and whether it is running.
final class SimulatorPickerView: UIView, UICollectionViewDelegate {
    var onChoose: ((SimulatorInfo) -> Void)?
    var onRefresh: (() -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SimulatorPlatform, SimulatorRef>!
    private var simulators: [SimulatorRef: SimulatorInfo] = [:]
    private var chosen: SimulatorRef?

    override init(frame: CGRect) {
        super.init(frame: frame)
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.headerMode = .supplementary
        collectionView = UICollectionView(frame: bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in
            self?.onRefresh?()
        })
        addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, SimulatorRef> { [weak self] cell, _, ref in
            guard let self, let info = simulators[ref] else { return }
            var content = cell.defaultContentConfiguration()
            content.text = info.name
            content.secondaryText = info.booted ? [info.runtime, "Running"].filter { !$0.isEmpty }.joined(separator: " · ")
                : info.runtime
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: info.isTablet ? "ipad" : "iphone")
            content.imageProperties.tintColor = info.booted ? .tintColor : .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = ref == chosen ? [.checkmark()] : []
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, index in
            guard let platform = self?.dataSource.sectionIdentifier(for: index.section) else { return }
            var content = UIListContentConfiguration.header()
            content.text = platform == .iOS ? "iOS Simulators" : "Android Emulators"
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, index, ref in
            view.dequeueConfiguredReusableCell(using: cell, for: index, item: ref)
        }
        dataSource.supplementaryViewProvider = { view, _, index in
            view.dequeueConfiguredReusableSupplementary(using: header, for: index)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lists `simulators`, running ones first, with `chosen` checked.
    func show(_ list: [SimulatorInfo], chosen: SimulatorRef?) {
        collectionView.refreshControl?.endRefreshing()
        let changed = list.filter { simulators[$0.simulator] != $0 || $0.simulator == chosen || $0.simulator == self.chosen }
        simulators = Dictionary(list.map { ($0.simulator, $0) }, uniquingKeysWith: { first, _ in first })
        self.chosen = chosen
        var snapshot = NSDiffableDataSourceSnapshot<SimulatorPlatform, SimulatorRef>()
        for platform in [SimulatorPlatform.iOS, .android] {
            let items = list.filter { $0.simulator.platform == platform }
                .sorted { ($0.booted ? 0 : 1, $0.name) < ($1.booted ? 0 : 1, $1.name) }
            guard !items.isEmpty else { continue }
            snapshot.appendSections([platform])
            snapshot.appendItems(items.map(\.simulator), toSection: platform)
        }
        let shown = Set(snapshot.itemIdentifiers)
        snapshot.reconfigureItems(changed.map(\.simulator).filter { shown.contains($0) && dataSource.indexPath(for: $0) != nil })
        dataSource.apply(snapshot, animatingDifferences: window != nil)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let ref = dataSource.itemIdentifier(for: indexPath), let info = simulators[ref] else { return }
        onChoose?(info)
    }
}
