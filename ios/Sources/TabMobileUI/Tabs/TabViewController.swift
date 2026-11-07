import TabMobileKit
import TabProtocol
import UIKit

/// One tab's panes. With room (iPad), the tab's split layout as on the Mac,
/// panes as rounded cards; on a phone, one pane at a time, switched with a
/// segmented control under the navigation bar.
final class TabViewController: UIViewController {
    let server: ServerModel
    let tabId: TabId
    private var panes: [PaneId: UIViewController] = [:]
    private var focused: PaneId?
    private var shownLayout: [(PaneId, UnitRect)] = []
    private let paneGap: CGFloat = 8
    private let emptyView = UIContentUnavailableView(configuration: .empty())
    private let paneSwitcher = UISegmentedControl()
    /// Glass under the switcher, so content scrolling beneath stays out of its way.
    private let switcherGlass = UIVisualEffectView(effect: UIGlassEffect())
    /// The panes the switcher shows, in order, with their labels.
    private var switcherPanes: [(id: PaneId, label: String)] = []

    init(server: ServerModel, tab: TabId, focus: PaneId? = nil) {
        self.server = server
        tabId = tab
        focused = focus
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.style = .editor
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        switcherGlass.isHidden = true
        switcherGlass.cornerConfiguration = .capsule()
        switcherGlass.translatesAutoresizingMaskIntoConstraints = false
        paneSwitcher.apportionsSegmentWidthsByContent = true
        paneSwitcher.translatesAutoresizingMaskIntoConstraints = false
        paneSwitcher.addAction(UIAction { [weak self] _ in self?.switcherChanged() }, for: .valueChanged)
        switcherGlass.contentView.addSubview(paneSwitcher)
        view.addSubview(switcherGlass)
        NSLayoutConstraint.activate([
            // Above the panes' own safe area, so their content scrolls under it.
            switcherGlass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                               constant: -Self.switcherSpace + 4),
            switcherGlass.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            switcherGlass.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            switcherGlass.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            paneSwitcher.topAnchor.constraint(equalTo: switcherGlass.contentView.topAnchor, constant: 4),
            paneSwitcher.bottomAnchor.constraint(equalTo: switcherGlass.contentView.bottomAnchor, constant: -4),
            paneSwitcher.leadingAnchor.constraint(equalTo: switcherGlass.contentView.leadingAnchor, constant: 4),
            paneSwitcher.trailingAnchor.constraint(equalTo: switcherGlass.contentView.trailingAnchor, constant: -4),
            paneSwitcher.heightAnchor.constraint(equalToConstant: 34),
        ])
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.setNeedsUpdateProperties()
        }
    }

    private var isCompact: Bool { traitCollection.horizontalSizeClass == .compact }

    override func updateProperties() {
        super.updateProperties()
        guard let (project, tab) = server.tab(tabId) else {
            showClosed()
            return
        }
        emptyView.isHidden = true
        let layout = tab.layout.rects
        if focused == nil || !tab.panes.contains(where: { $0.id == focused }) {
            focused = tab.panes.first { $0.content.isTerminal || $0.content.agentSession != nil }?.id ?? tab.panes.first?.id
        }
        syncChildren(tab, project: project)
        let visible: [(PaneId, UnitRect)] = isCompact
            ? focused.map { [($0, UnitRect(x: 0, y: 0, width: 1, height: 1))] } ?? []
            : layout
        shownLayout = visible
        for (id, controller) in panes {
            let shown = visible.contains { $0.0 == id }
            if shown, controller.view.superview == nil {
                view.insertSubview(controller.view, belowSubview: switcherGlass)
            } else if !shown, controller.view.superview != nil {
                controller.view.removeFromSuperview()
            }
        }
        view.setNeedsLayout()
        updateNavigation(tab, project: project)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compact = isCompact
        let area = compact ? view.bounds : view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: paneGap, dy: paneGap)
        for (id, unit) in shownLayout {
            guard let controller = panes[id] else { continue }
            var frame = CGRect(x: area.minX + unit.x * area.width, y: area.minY + unit.y * area.height,
                               width: unit.width * area.width, height: unit.height * area.height)
            if !compact { frame = frame.insetBy(dx: paneGap / 2, dy: paneGap / 2) }
            controller.view.frame = frame.integral
            let card = !compact && shownLayout.count > 1
            controller.view.layer.cornerRadius = card ? 16 : 0
            controller.view.layer.cornerCurve = .continuous
            controller.view.layer.masksToBounds = card
            controller.view.layer.borderWidth = card && id == focused ? 2 : 0
            controller.view.layer.borderColor = UIColor.tintColor.withAlphaComponent(0.6).cgColor
        }
    }

    // MARK: Panes

    private func syncChildren(_ tab: Tab, project: ProjectId) {
        let ids = Set(tab.panes.map(\.id))
        for (id, controller) in panes where !ids.contains(id) {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            panes[id] = nil
        }
        for pane in tab.panes {
            if let existing = panes[pane.id], matches(existing, pane.content) { continue }
            if let stale = panes[pane.id] {
                stale.willMove(toParent: nil)
                stale.view.removeFromSuperview()
                stale.removeFromParent()
            }
            let controller = makeController(pane, project: project)
            addChild(controller)
            controller.didMove(toParent: self)
            let tap = UITapGestureRecognizer(target: self, action: #selector(paneTapped))
            tap.cancelsTouchesInView = false
            controller.view.addGestureRecognizer(tap)
            controller.view.accessibilityIdentifier = pane.id.description
            panes[pane.id] = controller
        }
        server.pruneControllers()
    }

    private func matches(_ controller: UIViewController, _ content: PaneContent) -> Bool {
        switch content {
        case .terminal(let session?): (controller as? TerminalPaneViewController)?.controller.session == session
        case .terminal(nil): controller is StartingPaneViewController
        case .agent(let session, _): (controller as? AgentPaneViewController)?.controller.session == session
        default: controller is UnsupportedPaneViewController
        }
    }

    private func makeController(_ pane: Pane, project: ProjectId) -> UIViewController {
        switch pane.content {
        case .terminal(let session?):
            return TerminalPaneViewController(controller: server.terminal(session), server: server)
        case .terminal(nil):
            return StartingPaneViewController()
        case .agent(let session, let provider):
            return AgentPaneViewController(controller: server.agent(session, project: project, provider: provider))
        default:
            return UnsupportedPaneViewController(title: pane.content.defaultTitle)
        }
    }

    @objc private func paneTapped(_ gesture: UITapGestureRecognizer) {
        guard let id = panes.first(where: { $0.value.view === gesture.view })?.key, id != focused else { return }
        focused = id
        view.setNeedsLayout()
        setNeedsUpdateProperties()
    }

    private func focus(_ pane: PaneId) {
        focused = pane
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
        (panes[pane] as? TerminalPaneViewController)?.focus()
    }

    // MARK: Navigation bar

    private func updateNavigation(_ tab: Tab, project: ProjectId) {
        let summaries = tab.panes.map { server.summary(of: $0) }
        let current = summaries.first { $0.id == focused }
        let projectName = server.project(project).map { $0.home ? nil : $0.name } ?? nil
        title = tab.customTitle ?? current?.title ?? projectName ?? "Tab"
        navigationItem.subtitle = summaries.count > 1 ? "\(summaries.count) panes" : projectName

        updateSwitcher(isCompact && summaries.count > 1 ? summaries : [])

        let add = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: UIMenu(title: "New Pane", children: [
            UIAction(title: "Terminal", image: UIImage(systemName: "apple.terminal")) { [weak self] _ in
                self?.addPane(.terminal, project: project)
            },
            UIAction(title: "Agent", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.addPane(.agent(.claude), project: project)
            },
        ]))
        add.accessibilityLabel = "New Pane"
        var more: [UIMenuElement] = []
        if let focused, tab.panes.count > 1 {
            more.append(UIAction(title: "Close Pane", image: UIImage(systemName: "xmark.square")) { [weak self] _ in
                try? self?.server.closePane(focused)
            })
        }
        more.append(UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
            self?.confirmCloseTab()
        })
        let menu = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: more))
        menu.accessibilityLabel = "More"
        navigationItem.rightBarButtonItems = [menu, add]
    }

    // MARK: Pane switcher

    /// Room the switcher takes above the panes' content.
    private static let switcherSpace: CGFloat = 48

    /// One segment per pane on a phone, rebuilt only when the panes or their
    /// names change.
    private func updateSwitcher(_ summaries: [PaneSummary]) {
        let labels = PaneSummary.shortLabels(summaries)
        let next = zip(summaries, labels).map { (id: $0.id, label: $1) }
        if next.map(\.id) != switcherPanes.map(\.id) || next.map(\.label) != switcherPanes.map(\.label) {
            switcherPanes = next
            paneSwitcher.removeAllSegments()
            for (index, label) in labels.enumerated() {
                paneSwitcher.insertSegment(withTitle: label, at: index, animated: false)
            }
        }
        paneSwitcher.selectedSegmentIndex = switcherPanes.firstIndex { $0.id == focused } ?? UISegmentedControl.noSegment
        let shown = !switcherPanes.isEmpty
        guard shown == switcherGlass.isHidden else { return }
        switcherGlass.isHidden = !shown
        // The panes' content starts under the switcher and scrolls beneath it.
        additionalSafeAreaInsets.top = shown ? Self.switcherSpace : 0
    }

    private func switcherChanged() {
        let index = paneSwitcher.selectedSegmentIndex
        guard switcherPanes.indices.contains(index) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        focus(switcherPanes[index].id)
    }

    static func symbol(_ kind: PaneSummary.Kind) -> String {
        switch kind {
        case .terminal: "apple.terminal"
        case .agent: "sparkles"
        case .other: "macwindow"
        }
    }

    private func addPane(_ kind: MobilePaneKind, project: ProjectId) {
        let size = Size(cols: 80, rows: 24)
        let edge: Direction = view.bounds.width > view.bounds.height ? .right : .down
        guard let id = try? server.newPane(kind, project: project, beside: focused, edge: edge, size: size) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        focus(id)
    }

    private func confirmCloseTab() {
        let alert = UIAlertController(title: "Close this tab?", message: "Its terminals end and its agents stop, on every device.",
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Close Tab", style: .destructive) { [weak self] _ in
            guard let self else { return }
            try? server.closeTab(tabId)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceItem = navigationItem.rightBarButtonItems?.first
        present(alert, animated: true)
    }

    // MARK: Hardware keyboard

    /// The desktop's pane shortcuts. In Home, new terminals and agents are
    /// tabs, which the root handles when these leave ⌘T and ⌘⌥A alone.
    override var keyCommands: [UIKeyCommand]? {
        guard let (project, tab) = server.tab(tabId) else { return nil }
        var commands = [
            UIKeyCommand(title: tab.panes.count > 1 ? "Close Pane" : "Close Tab", action: #selector(closeCommand),
                         input: "w", modifierFlags: .command),
            UIKeyCommand(title: "Close Tab", action: #selector(closeTabCommand), input: "w", modifierFlags: [.command, .shift]),
        ]
        if server.project(project)?.home == false {
            commands += [
                UIKeyCommand(title: "New Terminal Pane", action: #selector(newTerminalPane), input: "t", modifierFlags: .command),
                UIKeyCommand(title: "New Agent Pane", action: #selector(newAgentPane), input: "a",
                             modifierFlags: [.command, .alternate]),
            ]
        }
        if tab.panes.count > 1 {
            commands += [
                UIKeyCommand(title: "Next Pane", action: #selector(nextPane), input: "]", modifierFlags: [.command, .shift]),
                UIKeyCommand(title: "Previous Pane", action: #selector(previousPane), input: "[", modifierFlags: [.command, .shift]),
            ]
        }
        return commands
    }

    @objc private func closeCommand() {
        guard let focused, let tab = server.tab(tabId)?.tab, tab.panes.count > 1 else {
            confirmCloseTab()
            return
        }
        try? server.closePane(focused)
    }

    @objc private func closeTabCommand() { confirmCloseTab() }

    @objc private func newTerminalPane() {
        guard let project = server.tab(tabId)?.project else { return }
        addPane(.terminal, project: project)
    }

    @objc private func newAgentPane() {
        guard let project = server.tab(tabId)?.project else { return }
        addPane(.agent(.claude), project: project)
    }

    @objc private func nextPane() { focusAdjacentPane(1) }
    @objc private func previousPane() { focusAdjacentPane(-1) }

    private func focusAdjacentPane(_ offset: Int) {
        guard let tab = server.tab(tabId)?.tab, !tab.panes.isEmpty else { return }
        let ids = tab.panes.map(\.id)
        let current = ids.firstIndex { $0 == focused } ?? 0
        focus(ids[(current + offset + ids.count) % ids.count])
    }

    private func showClosed() {
        for controller in panes.values {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        panes = [:]
        shownLayout = []
        title = nil
        navigationItem.subtitle = nil
        navigationItem.rightBarButtonItems = nil
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "rectangle.on.rectangle.slash")
        configuration.text = "Tab Closed"
        configuration.secondaryText = "This tab was closed. Choose another from the list."
        emptyView.configuration = configuration
        emptyView.isHidden = false
        view.bringSubviewToFront(emptyView)
    }
}

/// A terminal pane whose session the server is still starting.
final class StartingPaneViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let loading = UIContentUnavailableView(configuration: .loading())
        loading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loading)
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

/// Browser, simulator, editor and diff panes live on the Mac.
final class UnsupportedPaneViewController: UIViewController {
    private let paneTitle: String

    init(title: String) {
        paneTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "macwindow")
        configuration.text = paneTitle
        configuration.secondaryText = "This pane opens on your Mac."
        let content = UIContentUnavailableView(configuration: configuration)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
