import TabMobileKit
import TabProtocol
import UIKit

/// A simulator pane: an iOS simulator's or Android emulator's live screen on
/// the Mac, to touch and type into, with its buttons and controls below; or
/// the Mac's simulators to choose one. The screen streams only while the
/// pane is on screen, and the simulator keeps running when it closes.
final class SimulatorPaneViewController: UIViewController {
    let controller: SimulatorController
    private let server: ServerModel
    private let screen = SimulatorScreenView()
    private let picker = SimulatorPickerView()
    private let message = UIContentUnavailableView(configuration: .empty())
    private let controls = UIStackView()
    private let backButton = SimulatorPaneViewController.control("chevron.backward", label: "Back")
    private let homeButton = SimulatorPaneViewController.control("house", label: "Home")
    private let rotateButton = SimulatorPaneViewController.control("rotate.left", label: "Rotate Left")
    private let keyboardButton = SimulatorPaneViewController.control("keyboard", label: "Keyboard")
    private let cancelButton = UIButton(configuration: .glass())
    private let moreButton = SimulatorPaneViewController.control("ellipsis", label: "More")

    init(controller: SimulatorController, server: ServerModel) {
        self.controller = controller
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func control(_ symbol: String, label: String) -> UIButton {
        let button = UIButton(configuration: .glass())
        button.configuration?.image = UIImage(systemName: symbol)
        button.configuration?.cornerStyle = .capsule
        button.accessibilityLabel = label
        button.largeContentTitle = label
        button.showsLargeContentViewer = true
        button.addInteraction(UILargeContentViewerInteraction())
        return button
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        for child in [screen, picker, message, controls] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        controller.display = screen
        screen.onInput = { [weak self] input in self?.controller.send(input) }
        screen.onFrameShown = { [weak self] in self?.controller.frameShown() }
        screen.onNeedsKeyframe = { [weak self] in self?.controller.needsKeyframe() }
        screen.onWindowChange = { [weak self] onScreen in self?.screenMoved(onScreen) }
        picker.onChoose = { [weak self] simulator in self?.controller.choose(simulator) }
        picker.onRefresh = { [weak self] in self?.controller.refresh() }
        controller.onError = { [weak self] error in self?.report(error) }

        cancelButton.configuration?.title = "Cancel"
        cancelButton.configuration?.cornerStyle = .capsule
        backButton.addAction(UIAction { [weak self] _ in self?.controller.press(.back) }, for: .primaryActionTriggered)
        homeButton.addAction(UIAction { [weak self] _ in self?.controller.press(.home) }, for: .primaryActionTriggered)
        rotateButton.addAction(UIAction { [weak self] _ in self?.controller.rotate(by: 1) }, for: .primaryActionTriggered)
        keyboardButton.addAction(UIAction { [weak self] _ in self?.toggleKeyboard() }, for: .primaryActionTriggered)
        cancelButton.addAction(UIAction { [weak self] _ in self?.controller.cancelChoosing() }, for: .primaryActionTriggered)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreItems() ?? [])
        }])
        for button in [backButton, homeButton, rotateButton, keyboardButton, cancelButton, moreButton] {
            controls.addArrangedSubview(button)
        }
        controls.spacing = 10
        controls.alignment = .center

        view.keyboardLayoutGuide.usesBottomSafeArea = true
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            screen.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            screen.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            screen.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            screen.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            controls.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            controls.heightAnchor.constraint(equalToConstant: 48),
            controls.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            picker.topAnchor.constraint(equalTo: view.topAnchor),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            message.topAnchor.constraint(equalTo: guide.topAnchor),
            message.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: controls.topAnchor),
        ])
        view.bringSubviewToFront(controls)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        controller.maxPixels = screen.maxPixels
    }

    private func screenMoved(_ onScreen: Bool) {
        if onScreen {
            controller.maxPixels = screen.maxPixels
            controller.startScreen()
        } else {
            controller.stopScreen()
            screen.clear()
        }
    }

    // MARK: State

    /// Follows the simulator's state; runs again when it changes.
    override func updateProperties() {
        super.updateProperties()
        let phase = controller.phase
        let live = phase == .live
        screen.isHidden = !live
        screen.orientation = controller.orientation
        picker.isHidden = phase != .picking || controller.simulators?.isEmpty != false
        message.isHidden = live || !picker.isHidden
        if phase == .picking, let simulators = controller.simulators {
            picker.show(simulators, chosen: controller.simulator)
        }
        if !live, screen.isFirstResponder { _ = screen.resignFirstResponder() }
        updateMessage(phase)

        let buttons = controller.info?.buttons ?? []
        backButton.isHidden = !live || !buttons.contains(.back)
        homeButton.isHidden = !live
        rotateButton.isHidden = !live
        keyboardButton.isHidden = !live
        cancelButton.isHidden = phase != .picking || !controller.canCancelChoosing
        moreButton.isHidden = phase == .picking || phase == .unsupported
        view.bringSubviewToFront(controls)
    }

    private func updateMessage(_ phase: SimulatorController.Phase) {
        let name = controller.choice.name ?? "The simulator"
        var configuration: UIContentUnavailableConfiguration
        switch phase {
        case .loading, .live:
            configuration = .loading()
        case .picking where controller.simulators == nil:
            configuration = .loading()
            configuration.text = "Finding Simulators…"
        case .picking:
            configuration = .empty()
            configuration.image = UIImage(systemName: "iphone.slash")
            configuration.text = "No Simulators"
            configuration.secondaryText = "Add iOS simulators in Xcode, or Android emulators in Android Studio, on \(server.server.name)."
            configuration.button = .borderedTinted()
            configuration.button.title = "Check Again"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.controller.refresh() }
        case .starting:
            configuration = .loading()
            configuration.text = "Starting \(name)…"
        case .off:
            configuration = .empty()
            configuration.image = UIImage(systemName: "power")
            configuration.text = "\(name) is shut down"
            configuration.button = .prominentGlass()
            configuration.button.title = "Start"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.controller.start() }
        case .failed(let reason):
            configuration = .empty()
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            configuration.text = "Can't show the simulator"
            configuration.secondaryText = reason
            configuration.button = .glass()
            configuration.button.title = "Choose Another…"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.controller.choose() }
        case .offline:
            configuration = .empty()
            configuration.image = UIImage(systemName: "wifi.exclamationmark")
            configuration.text = "Reconnect to \(server.server.name)"
            configuration.secondaryText = "Its simulators show here once it is connected."
        case .unsupported:
            configuration = .empty()
            configuration.image = UIImage(systemName: "iphone.slash")
            configuration.text = "Update Tab on \(server.server.name)"
            configuration.secondaryText = "Its version of Tab doesn't share simulators with this app."
        }
        message.configuration = configuration
    }

    // MARK: Controls

    private func toggleKeyboard() {
        screen.setSoftwareKeyboard(!screen.showsSoftwareKeyboard)
    }

    private func moreItems() -> [UIMenuElement] {
        var sections: [UIMenuElement] = []
        if controller.phase == .live, let info = controller.info {
            let buttons = info.buttons.filter { $0 != .back && $0 != .home }.map { button in
                UIAction(title: Self.name(of: button), image: UIImage(systemName: Self.symbol(of: button))) { [weak self] _ in
                    self?.controller.press(button)
                }
            }
            var settings: [UIMenuElement] = [
                UIAction(title: "Rotate Right", image: UIImage(systemName: "rotate.right")) { [weak self] _ in
                    self?.controller.rotate(by: -1)
                },
                UIAction(title: "Dark Appearance", image: UIImage(systemName: "circle.lefthalf.filled"),
                         state: controller.dark == true ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    controller.setDark(controller.dark != true)
                },
            ]
            if info.hardwareKeyboardSwitch {
                settings.append(UIAction(title: "Simulate Hardware Keyboard", image: UIImage(systemName: "keyboard"),
                                         state: controller.simulatesHardwareKeyboard ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    controller.setHardwareKeyboard(!controller.simulatesHardwareKeyboard)
                })
            }
            let sharing: [UIMenuElement] = [
                UIAction(title: "Paste Text", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                    guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                    self?.controller.type(text)
                },
                UIAction(title: "Screenshot", image: UIImage(systemName: "camera")) { [weak self] _ in self?.screenshot() },
            ]
            sections.append(UIMenu(options: .displayInline, children: buttons + settings))
            sections.append(UIMenu(options: .displayInline, children: sharing))
        }
        var simulator: [UIMenuElement] = [
            UIAction(title: "Choose Another Simulator…", image: UIImage(systemName: "iphone.gen3")) { [weak self] _ in
                self?.controller.choose()
            },
        ]
        switch controller.phase {
        case .live, .starting:
            simulator.append(UIAction(title: "Shut Down", image: UIImage(systemName: "power"), attributes: .destructive) {
                [weak self] _ in self?.controller.shutDown()
            })
        case .off:
            simulator.append(UIAction(title: "Start", image: UIImage(systemName: "power")) { [weak self] _ in
                self?.controller.start()
            })
        default:
            break
        }
        sections.append(UIMenu(options: .displayInline, children: simulator))
        return sections
    }

    private static func name(of button: SimulatorButton) -> String {
        switch button {
        case .home: "Home"
        case .back: "Back"
        case .recents: "Recent Apps"
        case .lock: "Lock"
        }
    }

    private static func symbol(of button: SimulatorButton) -> String {
        switch button {
        case .home: "house"
        case .back: "chevron.backward"
        case .recents: "square.stack"
        case .lock: "lock"
        }
    }

    /// Shares the screen as a PNG from the Mac, at its full size.
    private func screenshot() {
        Task {
            do {
                let png = try await controller.screenshot()
                guard let image = UIImage(data: png) else { return }
                let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = moreButton
                present(share, animated: true)
            } catch {
                report((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        }
    }

    private func report(_ error: String) {
        guard presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(title: "The simulator didn't respond", message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
