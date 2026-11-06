import TabMobileKit
import TabProtocol
import UIKit

/// An agent pane: the conversation, and a glass composer riding the keyboard.
final class AgentPaneViewController: UIViewController, UICollectionViewDelegate {
    let controller: AgentChatController
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var rows: [String: TranscriptRow] = [:]
    private var order: [String] = []
    private var expandedTurns: Set<String> = []
    private var expandedItems: Set<String> = []
    /// Rendered Markdown by item id, redone only when the text changes.
    private var rendered: [String: (text: String, value: NSAttributedString)] = [:]
    private let composer = AgentComposerView()
    private let emptyView = UIContentUnavailableView(configuration: .empty())
    private var didInitialScroll = false

    init(controller: AgentChatController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.showsSeparators = false
        list.backgroundColor = .clear
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        configureDataSource()

        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "sparkles")
        empty.text = controller.provider.name
        empty.secondaryText = "Ask for anything in this project. It runs on your Mac."
        emptyView.configuration = empty
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.onSend = { [weak self] text in self?.controller.send(text) }
        composer.onStop = { [weak self] in self?.controller.interrupt() }
        view.addSubview(composer)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -40),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
            composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
        // The transcript scrolls under the composer, which blurs it as glass does.
        collectionView.contentInset.bottom = 8
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = view.bounds.maxY - composer.frame.minY - view.safeAreaInsets.bottom + 8
        if collectionView.contentInset.bottom != inset {
            let atBottom = isNearBottom
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
            if atBottom { scrollToBottom(animated: false) }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        controller.open()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        controller.close()
    }

    /// Runs whenever the observed chat changes.
    override func updateProperties() {
        super.updateProperties()
        let snapshot = controller.snapshot
        composer.update(running: controller.isRunning, busy: controller.busy, provider: controller.provider,
                        models: controller.models, snapshot: snapshot, controller: controller)
        apply(AgentTranscript.rows(snapshot, expanded: expandedTurns))
        emptyView.isHidden = !(snapshot?.items.isEmpty ?? false)
        if let error = controller.error { composer.show(error: error) }
    }

    // MARK: Transcript

    private func configureDataSource() {
        let user = UICollectionView.CellRegistration<UserMessageCell, String> { [weak self] cell, _, id in
            guard case .user(let item)? = self?.rows[id] else { return }
            cell.configure(item)
        }
        let assistant = UICollectionView.CellRegistration<AssistantMessageCell, String> { [weak self] cell, _, id in
            guard let self, case .assistant(let item)? = rows[id] else { return }
            cell.configure(render(item))
        }
        let tool = UICollectionView.CellRegistration<ToolCell, String> { [weak self] cell, _, id in
            guard let self, case .tool(let item)? = rows[id] else { return }
            cell.configure(item, expanded: expandedItems.contains(id))
        }
        let thinking = UICollectionView.CellRegistration<ThinkingCell, String> { [weak self] cell, _, id in
            guard let self, case .thinking(let item)? = rows[id] else { return }
            cell.configure(item, expanded: expandedItems.contains(id))
        }
        let approval = UICollectionView.CellRegistration<ApprovalCell, String> { [weak self] cell, _, id in
            guard let self, case .approval(let item)? = rows[id] else { return }
            cell.configure(item, busy: controller.busy)
            cell.onAnswer = { [weak self] allow in self?.controller.approve(item, allow: allow) }
        }
        let notice = UICollectionView.CellRegistration<NoticeCell, String> { [weak self] cell, _, id in
            guard case .notice(let item, let isError)? = self?.rows[id] else { return }
            cell.configure(item, isError: isError)
        }
        let work = UICollectionView.CellRegistration<WorkCell, String> { [weak self] cell, _, id in
            guard case .work(_, let steps, let duration, let expanded)? = self?.rows[id] else { return }
            cell.configure(steps: steps, duration: duration, expanded: expanded)
        }
        let working = UICollectionView.CellRegistration<WorkingCell, String> { [weak self] cell, _, id in
            guard case .working(let since)? = self?.rows[id] else { return }
            cell.configure(since: since)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, path, id in
            switch self?.rows[id] {
            case .user?: view.dequeueConfiguredReusableCell(using: user, for: path, item: id)
            case .assistant?: view.dequeueConfiguredReusableCell(using: assistant, for: path, item: id)
            case .tool?: view.dequeueConfiguredReusableCell(using: tool, for: path, item: id)
            case .thinking?: view.dequeueConfiguredReusableCell(using: thinking, for: path, item: id)
            case .approval?: view.dequeueConfiguredReusableCell(using: approval, for: path, item: id)
            case .work?: view.dequeueConfiguredReusableCell(using: work, for: path, item: id)
            case .working?: view.dequeueConfiguredReusableCell(using: working, for: path, item: id)
            case .notice?, nil: view.dequeueConfiguredReusableCell(using: notice, for: path, item: id)
            }
        }
    }

    private func render(_ item: AgentChatItem) -> NSAttributedString {
        if let cached = rendered[item.id], cached.text == item.text { return cached.value }
        let value = MarkdownRenderer.render(item.text)
        rendered[item.id] = (item.text, value)
        return value
    }

    /// Applies new rows, reconfiguring only the ones whose content changed.
    private func apply(_ next: [TranscriptRow]) {
        let wasAtBottom = isNearBottom || !didInitialScroll
        let previous = rows
        var nextRows: [String: TranscriptRow] = [:]
        var nextOrder: [String] = []
        for row in next where nextRows[row.id] == nil {
            nextRows[row.id] = row
            nextOrder.append(row.id)
        }
        rows = nextRows
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(nextOrder)
        let changed = nextOrder.filter { id in previous[id].map { $0 != nextRows[id] } ?? false }
        // Reconfiguring keeps the cell, so only rows that keep their kind may;
        // an answered approval becomes a notice and needs a new cell.
        let sameKind = changed.filter { previous[$0]?.kind == nextRows[$0]?.kind }
        snapshot.reconfigureItems(sameKind)
        snapshot.reloadItems(changed.filter { !sameKind.contains($0) })
        let structural = nextOrder != order
        order = nextOrder
        dataSource.apply(snapshot, animatingDifferences: didInitialScroll && structural) { [weak self] in
            guard let self, wasAtBottom, !nextOrder.isEmpty else { return }
            scrollToBottom(animated: didInitialScroll)
            didInitialScroll = true
        }
    }

    private var isNearBottom: Bool {
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return collectionView.contentSize.height - visibleBottom < 120
    }

    private func scrollToBottom(animated: Bool) {
        let height = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
        let offset = max(-collectionView.adjustedContentInset.top, height - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: animated)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch rows[id] {
        case .tool?, .thinking?:
            if expandedItems.contains(id) { expandedItems.remove(id) } else { expandedItems.insert(id) }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([id])
            dataSource.apply(snapshot, animatingDifferences: true)
        case .work(let turn, _, _, _)?:
            if expandedTurns.contains(turn) { expandedTurns.remove(turn) } else { expandedTurns.insert(turn) }
            apply(AgentTranscript.rows(controller.snapshot, expanded: expandedTurns))
        default:
            break
        }
        UISelectionFeedbackGenerator().selectionChanged()
        return false
    }
}

/// The message field in a glass capsule: settings, text, and Send that
/// turns into Stop while the agent works.
final class AgentComposerView: UIView, UITextViewDelegate {
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let text = UITextView()
    private let placeholder = UILabel()
    private let send = UIButton(configuration: .prominentGlass())
    private let options = UIButton(configuration: .plain())
    private var heightConstraint: NSLayoutConstraint!
    private var running = false
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .uniformCorners(radius: .fixed(24))
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.backgroundColor = .clear
        text.delegate = self
        text.textContainerInset = UIEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.accessibilityLabel = "Message"
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        options.configuration?.image = UIImage(systemName: "slider.horizontal.3")
        options.configuration?.baseForegroundColor = .secondaryLabel
        options.showsMenuAsPrimaryAction = true
        options.accessibilityLabel = "Model and access"
        options.translatesAutoresizingMaskIntoConstraints = false

        send.configuration?.image = UIImage(systemName: "arrow.up",
                                            withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
        send.configuration?.cornerStyle = .capsule
        send.translatesAutoresizingMaskIntoConstraints = false
        send.addAction(UIAction { [weak self] _ in self?.primary() }, for: .primaryActionTriggered)

        for view in [options, text, placeholder, send] { glass.contentView.addSubview(view) }
        heightConstraint = text.heightAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            options.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 4),
            options.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -2),
            options.widthAnchor.constraint(equalToConstant: 44),
            options.heightAnchor.constraint(equalToConstant: 44),
            text.leadingAnchor.constraint(equalTo: options.trailingAnchor),
            text.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -2),
            text.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -6),
            heightConstraint,
            placeholder.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: 5),
            placeholder.centerYAnchor.constraint(equalTo: options.centerYAnchor),
            send.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
            send.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6),
            send.widthAnchor.constraint(equalToConstant: 36),
            send.heightAnchor.constraint(equalToConstant: 36),
        ])
        refreshSend()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(running: Bool, busy: Bool, provider: AgentChatProvider, models: [AgentModelDescriptor],
                snapshot: AgentChatSnapshot?, controller: AgentChatController) {
        self.running = running
        placeholder.text = "Message \(provider.name)"
        options.menu = Self.menu(models: models, snapshot: snapshot, controller: controller)
        refreshSend()
    }

    func show(error: String) {
        placeholder.text = error
    }

    private static func menu(models: [AgentModelDescriptor], snapshot: AgentChatSnapshot?,
                             controller: AgentChatController) -> UIMenu {
        let current = snapshot?.model
        let modelActions = models.map { model in
            UIAction(title: model.title, state: (current ?? models.first(where: \.isDefault)?.id) == model.id ? .on : .off) { _ in
                controller.setModel(model.id, effort: snapshot?.reasoningEffort)
            }
        }
        let effortSource = models.first { $0.id == current } ?? models.first(where: \.isDefault)
        let efforts = (effortSource?.reasoningEfforts ?? []).map { effort in
            UIAction(title: effort.title, state: snapshot?.reasoningEffort == effort ? .on : .off) { _ in
                controller.setModel(snapshot?.model, effort: effort)
            }
        }
        let access = AgentAccessMode.allCases.map { mode in
            UIAction(title: mode.title, state: snapshot?.accessMode == mode ? .on : .off) { _ in
                controller.setAccess(mode)
            }
        }
        var children: [UIMenuElement] = []
        if !modelActions.isEmpty {
            children.append(UIMenu(title: "Model", image: UIImage(systemName: "cpu"), children: modelActions))
        }
        if !efforts.isEmpty {
            children.append(UIMenu(title: "Effort", image: UIImage(systemName: "gauge.with.dots.needle.50percent"),
                                   children: efforts))
        }
        children.append(UIMenu(title: "Access", image: UIImage(systemName: "lock.shield"), options: .displayInline,
                               children: access))
        return UIMenu(children: children)
    }

    private func primary() {
        if running, text.text.isEmpty {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            onStop?()
            return
        }
        let message = text.text ?? ""
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSend?(message)
        text.text = ""
        textViewDidChange(text)
    }

    private func refreshSend() {
        let stop = running && text.text.isEmpty
        send.configuration?.image = UIImage(systemName: stop ? "stop.fill" : "arrow.up",
                                            withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
        send.accessibilityLabel = stop ? "Stop" : "Send"
        send.isEnabled = stop || !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !text.text.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let maximum = (textView.font?.lineHeight ?? 20) * 6 + 22
        heightConstraint.constant = min(max(44, fitting), maximum)
        textView.isScrollEnabled = fitting > maximum
        refreshSend()
    }
}
