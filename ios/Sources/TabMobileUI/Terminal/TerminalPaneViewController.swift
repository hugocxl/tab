import TabMobileKit
import TabProtocol
import UIKit

/// A terminal pane: the terminal above the keyboard, a glass button back to
/// live output while reading history, and the reason when the program ended.
final class TerminalPaneViewController: UIViewController {
    let controller: TerminalController
    private let server: ServerModel
    private var terminalView: TerminalView!
    private let liveButton = UIButton(configuration: .glass())
    private let statusPill = UIButton(configuration: .glass())
    private var lastAppearance: (CGFloat, String, Bool)?

    init(controller: TerminalController, server: ServerModel) {
        self.controller = controller
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let preferences = Preferences.shared
        let dark = traitCollection.userInterfaceStyle == .dark
        terminalView = TerminalView(controller: controller, fontSize: preferences.fontSize,
                                    scheme: preferences.scheme(dark: dark), dark: dark)
        terminalView.onFontSizeChange = { size in Preferences.shared.fontSize = size }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        liveButton.configuration?.image = UIImage(systemName: "arrow.down.to.line")
        liveButton.configuration?.title = "Live"
        liveButton.configuration?.imagePadding = 6
        liveButton.configuration?.cornerStyle = .capsule
        liveButton.addAction(UIAction { [weak self] _ in self?.controller.scrollToBottom() }, for: .primaryActionTriggered)
        liveButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(liveButton)

        statusPill.configuration?.cornerStyle = .capsule
        statusPill.configuration?.imagePadding = 8
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.isUserInteractionEnabled = false
        view.addSubview(statusPill)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            liveButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            liveButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            statusPill.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            statusPill.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
        view.keyboardLayoutGuide.usesBottomSafeArea = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: Self, _) in
            self.setNeedsUpdateProperties()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if UIDevice.current.userInterfaceIdiom == .phone || view.window?.windowScene?.keyWindow != nil {
            terminalView.becomeFirstResponder()
        }
    }

    /// Follows preferences and the terminal's state; runs again when they change.
    override func updateProperties() {
        super.updateProperties()
        let preferences = Preferences.shared
        let dark = traitCollection.userInterfaceStyle == .dark
        let appearance = (preferences.fontSize, dark ? preferences.darkTheme : preferences.lightTheme, dark)
        if lastAppearance.map({ $0 != appearance }) ?? false {
            terminalView.apply(fontSize: appearance.0, scheme: preferences.scheme(dark: dark), dark: dark)
        }
        lastAppearance = appearance
        view.backgroundColor = terminalView.backgroundColor
        server.terminalColors = terminalView.terminalColors

        liveButton.isHidden = !controller.scrolledBack
        switch controller.state {
        case .ended(let reason):
            statusPill.isHidden = false
            statusPill.configuration?.image = UIImage(systemName: "stop.circle")
            statusPill.configuration?.title = reason
        case .attaching where controller.grid == nil:
            statusPill.isHidden = false
            statusPill.configuration?.image = nil
            statusPill.configuration?.title = "Connecting…"
        case .detached where server.status != .connected:
            statusPill.isHidden = false
            statusPill.configuration?.image = UIImage(systemName: "wifi.exclamationmark")
            statusPill.configuration?.title = "Reconnecting…"
        default:
            statusPill.isHidden = true
        }
    }

    /// Focus the terminal, as when its pane is chosen.
    func focus() {
        terminalView.becomeFirstResponder()
    }
}
