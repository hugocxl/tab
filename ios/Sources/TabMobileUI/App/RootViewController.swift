import SwiftUI
import TabMobileKit
import TabProtocol
import UIKit

/// The app's window content: the welcome screen until a Mac is paired, then
/// the tab list beside the chosen tab.
public final class RootViewController: UIViewController {
    private let app: AppModel
    private var split: UISplitViewController?
    private var list: TabListViewController?
    private var welcome: WelcomeViewController?
    /// Whether the detail column shows a tab; until then a phone shows the list.
    private var showsDetail = false
    private lazy var pairing: PairingFlow = {
        let flow = PairingFlow(app: app, presenter: self)
        flow.onPaired = { [weak self] server in self?.paired(server) }
        return flow
    }()

    public init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }

    public override func updateProperties() {
        super.updateProperties()
        let style = Preferences.shared.appearance.style
        if view.window?.overrideUserInterfaceStyle != style { view.window?.overrideUserInterfaceStyle = style }
        if app.servers.isEmpty {
            showWelcome()
        } else {
            showTabs()
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateProperties()
    }

    // MARK: Hardware keyboard

    /// The desktop's shortcuts for tabs, so an iPad with a keyboard works the same.
    public override var keyCommands: [UIKeyCommand]? {
        guard split != nil else { return nil }
        var commands = [
            UIKeyCommand(title: "New Terminal Tab", action: #selector(newTerminalTab), input: "t", modifierFlags: .command),
            UIKeyCommand(title: "New Agent Tab", action: #selector(newAgentTab), input: "a", modifierFlags: [.command, .alternate]),
            UIKeyCommand(title: "Next Tab", action: #selector(nextTab), input: "]", modifierFlags: .command),
            UIKeyCommand(title: "Previous Tab", action: #selector(previousTab), input: "[", modifierFlags: .command),
            UIKeyCommand(title: "Filter Tabs", action: #selector(filterTabs), input: "f", modifierFlags: .command),
            UIKeyCommand(title: "Toggle Sidebar", action: #selector(toggleSidebarCommand), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Settings", action: #selector(settingsCommand), input: ",", modifierFlags: .command),
        ]
        for number in 1...9 {
            // One entry in the shortcut overlay stands for all nine.
            commands.append(UIKeyCommand(title: number == 1 ? "Tab 1…9" : "", action: #selector(selectNumberedTab),
                                         input: "\(number)", modifierFlags: .command))
        }
        return commands
    }

    @objc private func newTerminalTab() { list?.newTab(.terminal) }
    @objc private func newAgentTab() { list?.newTab(.agent(.claude)) }
    @objc private func nextTab() { list?.selectAdjacentTab(1) }
    @objc private func previousTab() { list?.selectAdjacentTab(-1) }
    @objc private func filterTabs() { list?.focusFilter() }
    @objc private func settingsCommand() { showSettings() }

    @objc private func selectNumberedTab(_ command: UIKeyCommand) {
        guard let number = command.input.flatMap(Int.init) else { return }
        list?.selectTab(number: number)
    }

    @objc private func toggleSidebarCommand() {
        guard let split else { return }
        let hidden = split.displayMode == .secondaryOnly
        split.preferredDisplayMode = hidden ? .oneBesideSecondary : .secondaryOnly
    }

    /// Pairs from a `tab://pair` link the system opened.
    public func open(_ url: URL) {
        guard url.scheme == "tab", url.host() == "pair" else { return }
        let link = url.absoluteString
        let presentAlert = { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: "Pair with this Mac?",
                                          message: "This \(UIDevice.current.model) will see its tabs, terminals and agents.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            let pair = UIAlertAction(title: "Pair", style: .default) { [weak self] _ in self?.pairing.pair(link: link) }
            alert.addAction(pair)
            alert.preferredAction = pair
            topPresenter.present(alert, animated: true)
        }
        if presentedViewController != nil { dismiss(animated: true, completion: presentAlert) } else { presentAlert() }
    }

    private var topPresenter: UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private func showWelcome() {
        guard welcome == nil else { return }
        let controller = WelcomeViewController()
        controller.onScan = { [weak self] in self?.pairing.scan() }
        controller.onPaste = { [weak self] in self?.pairing.askForLink(message: nil) }
        swap(to: controller)
        welcome = controller
        split = nil
        list = nil
    }

    private func showTabs() {
        guard split == nil else { return }
        let list = TabListViewController(app: app)
        list.onOpen = { [weak self] server, card in self?.show(card, on: server) }
        list.onOpenProject = { [weak self] server, project in self?.open(project, on: server) }
        list.onSettings = { [weak self] in self?.showSettings() }
        list.onPair = { [weak self] in self?.pairing.scan() }
        let split = UISplitViewController(style: .doubleColumn)
        split.delegate = self
        split.preferredDisplayMode = .oneBesideSecondary
        split.preferredSplitBehavior = .tile
        split.primaryBackgroundStyle = .sidebar
        split.preferredPrimaryColumnWidthFraction = 0.32
        split.minimumPrimaryColumnWidth = 340
        split.maximumPrimaryColumnWidth = 400
        split.setViewController(list, for: .primary)
        split.setViewController(PlaceholderViewController(), for: .secondary)
        split.show(.primary)
        swap(to: split)
        self.split = split
        self.list = list
        welcome = nil
    }

    private func swap(to controller: UIViewController) {
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
    }

    private func show(_ card: TabCard, on server: ServerModel) {
        guard let split else { return }
        showsDetail = true
        server.watchGit(card.project.id)
        // The same tab when the detail already shows it: refocus, no reload.
        if let current = (split.viewController(for: .secondary) as? UINavigationController)?.viewControllers.first
            as? TabViewController, current.server === server, current.tabId == card.tab.id {
            split.show(.secondary)
            return
        }
        split.setViewController(UINavigationController(rootViewController: TabViewController(server: server, tab: card.tab.id)),
                                for: .secondary)
        split.show(.secondary)
    }

    /// A project with no tab: start a terminal in it and show it.
    private func open(_ project: ProjectDescriptor, on server: ServerModel) {
        guard (try? server.newPane(.terminal, project: project.id, beside: nil, size: Size(cols: 80, rows: 24))) != nil,
              let card = server.cards.first(where: { $0.project.id == project.id }) else { return }
        list?.open(card, on: server)
    }

    private func showSettings() {
        let settings = SettingsView(app: app, preferences: Preferences.shared) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.pairing.scan() }
        }
        let host = UIHostingController(rootView: settings)
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    private func paired(_ server: ServerModel) {
        setNeedsUpdateProperties()
        updatePropertiesIfNeeded()
    }
}

extension RootViewController: UISplitViewControllerDelegate {
    public func splitViewController(_ split: UISplitViewController,
                                    topColumnForCollapsingToProposedTopColumn proposed: UISplitViewController.Column)
        -> UISplitViewController.Column {
        showsDetail ? proposed : .primary
    }
}

/// What the detail column shows before a tab is chosen.
final class PlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "sidebar.left")
        configuration.text = "Choose a Tab"
        configuration.secondaryText = "Pick a tab from the list, or start a new one."
        let content = UIContentUnavailableView(configuration: configuration)
        content.frame = view.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content)
    }
}
