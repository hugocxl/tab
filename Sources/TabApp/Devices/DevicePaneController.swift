import AppKit
import CoreImage
import TabCore
import TabDevices
import TabProtocol

/// A device pane: an iOS simulator's or Android emulator's live screen you
/// can touch and type into, or the picker when it has none. Its devices
/// belong to the tab's server: this Mac's show their surfaces directly,
/// another computer's stream as video. The device keeps running when the
/// pane closes; its screen streams only while the pane is on screen.
@MainActor
final class DevicePaneController: PaneContentController {
    let pane: PaneId
    var titleDidChange: (() -> Void)?

    private enum Phase: Equatable {
        case loading
        case picking
        case starting
        case live
        case off
        case failed(String)
    }

    private weak var model: AppModel?
    private var state: DevicePane
    private var phase = Phase.loading
    private(set) var session: DeviceSession?
    private var shown = false
    private var dark: Bool?
    private var pickerLoad: Task<Void, Never>?

    private let root = DeviceRootView()
    private let screen = DeviceScreenView()
    private let picker = DevicePickerView()
    private let message = DeviceMessageView()

    /// The tab's server, which owns the pane's devices.
    private let server: ServerId

    init(pane: PaneId, state: DevicePane, model: AppModel, server: ServerId) {
        self.pane = pane
        self.state = state
        self.model = model
        self.server = server
        for child in [screen, picker, message] {
            child.theme = model.theme
            root.addSubview(child)
            child.pinEdges(to: root)
        }
        root.theme = model.theme
        screen.onInput = { [weak self] input in self?.session?.send(input) }
        screen.onResize = { [weak self] pixels in (self?.session as? ServerDeviceSession)?.maxPixels = pixels }
        picker.onChoose = { [weak self] device in self?.choose(device) }
        if state.isChosen {
            attach(state)
        } else {
            showPicker()
        }
    }

    var view: NSView { root }
    var title: String { phase == .picking ? "Choose Device" : state.name ?? "Device" }

    // MARK: Pane

    func focusContent() {
        root.window?.makeFirstResponder(phase == .live ? screen : root)
    }

    func willClose() async -> Bool { true }

    func didShow() {
        shown = true
        session?.startScreen()
    }

    func didHide() {
        shown = false
        session?.stopScreen()
    }

    func dispose() {
        pickerLoad?.cancel()
        session?.close()
        session = nil
    }

    var headerActions: [PaneAction] {
        var actions: [PaneAction] = []
        if phase == .live, let session {
            if session.buttons.contains(.back) {
                actions.append(PaneAction(id: "device.back", icon: .chevronLeft, label: "Back") { [weak self] in self?.press(.back) })
            }
            actions.append(PaneAction(id: "device.home", icon: .home, label: "Home") { [weak self] in self?.press(.home) })
            actions.append(PaneAction(id: "device.rotate", icon: .rotate, label: "Rotate Left") { [weak self] in self?.rotate(by: 1) })
            if session.hasHardwareKeyboardSwitch {
                actions.append(PaneAction(id: "device.keyboard", icon: .keyboard, label: "Simulate Hardware Keyboard",
                                          isActive: state.simulatesHardwareKeyboard) { [weak self] in self?.toggleHardwareKeyboard() })
            }
            actions.append(PaneAction(id: "device.appearance", icon: .appearance, label: "Toggle Dark Appearance",
                                      isActive: dark ?? false) { [weak self] in self?.toggleAppearance() })
            actions.append(PaneAction(id: "device.screenshot", icon: .camera, label: "Screenshot") { [weak self] in self?.screenshot() })
        }
        if phase != .picking {
            actions.append(PaneAction(id: "device.more", icon: .ellipsis, label: "More") { [weak self] in
                guard let self, let menu = contextMenu, let event = NSApp.currentEvent else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: root)
            })
        }
        return actions
    }

    var contextMenu: NSMenu? {
        var builder = MenuBuilder()
        if phase == .live, let session {
            for button in session.buttons {
                builder.add(Self.name(of: button)) { [weak self] in self?.press(button) }
            }
            builder.add("Rotate Left") { [weak self] in self?.rotate(by: 1) }
            builder.add("Rotate Right") { [weak self] in self?.rotate(by: -1) }
            if session.hasHardwareKeyboardSwitch {
                builder.add("Simulate Hardware Keyboard", checked: state.simulatesHardwareKeyboard) { [weak self] in
                    self?.toggleHardwareKeyboard()
                }
            }
            builder.add("Paste Text") { [weak self] in self?.pasteText() }
            builder.add("Screenshot") { [weak self] in self?.screenshot() }
            builder.section()
        }
        builder.add("Choose Another Device…") { [weak self] in self?.showPicker() }
        if phase == .live || phase == .starting {
            builder.add("Shut Down") { [weak self] in self?.shutDown() }
        } else if phase == .off {
            builder.add("Start") { [weak self] in self?.start() }
        }
        return builder.menu
    }

    private static func name(of button: DeviceButton) -> String {
        switch button {
        case .home: return "Home"
        case .back: return "Back"
        case .recents: return "Recent Apps"
        case .lock: return "Lock"
        }
    }

    /// Runs a shortcut the pane handles itself.
    func perform(_ id: ShortcutId) -> Bool {
        guard phase == .live, screen.window?.firstResponder === screen else { return false }
        switch id {
        case .paste:
            pasteText()
            return true
        default:
            return false
        }
    }

    // MARK: Choosing

    /// The tab's server, while connected.
    private var api: ServerAPI? { model?.connections[server]?.side }

    /// The server's name when it is another computer.
    private var host: String? { server.isLocal ? nil : model?.serverName(server) ?? "the server" }

    private func showPicker() {
        session?.close()
        session = nil
        screen.show(nil)
        phase = .picking
        render()
        loadPicker()
    }

    private func loadPicker() {
        pickerLoad?.cancel()
        guard let api else {
            phase = .failed("Reconnect to \(host ?? "this Mac's server") to choose a device.")
            render()
            return
        }
        pickerLoad = Task { [weak self] in
            let devices = (try? await api.listDevices()) ?? []
            guard let self, !Task.isCancelled, phase == .picking else { return }
            picker.show(devices.map(DeviceChoice.init), host: host)
        }
    }

    /// The server's devices changed, or it reconnected.
    func devicesChanged() {
        switch phase {
        case .picking:
            loadPicker()
        case .failed where session == nil:
            showPicker()
        default:
            guard let session = session as? ServerDeviceSession else { return }
            Task { [weak self] in
                do {
                    try await session.refresh()
                } catch {
                    guard let self, self.session === session else { return }
                    phase = .failed("\(error)")
                    render()
                }
            }
        }
    }

    private func choose(_ device: DeviceChoice) {
        state = device.pane
        let saved = state
        _ = model?.edit { try $0.setDevice(self.pane, saved) }
        attach(saved)
        if !device.isRunning { start() }
    }

    private func attach(_ device: DevicePane) {
        session?.close()
        let ref: DeviceRef
        if let udid = device.udid {
            ref = .simulator(udid)
        } else if let avd = device.avd {
            ref = .emulator(avd)
        } else {
            showPicker()
            return
        }
        let session: DeviceSession
        if server.isLocal {
            session = LocalDevices.session(for: ref)
        } else {
            let remote = ServerDeviceSession(device: ref) { [weak self] in self?.api }
            remote.maxPixels = screen.maxPixels
            session = remote
        }
        self.session = session
        screen.orientation = .portrait
        session.onSurface = { [weak self] surface in self?.screen.show(surface) }
        session.onFrame = { [weak self] in self?.screen.surfaceDidDraw() }
        session.onStateChange = { [weak self] booted in self?.stateChanged(booted) }
        session.onInputError = { [weak self] error in self?.model?.report(error) }
        phase = .loading
        render()
        Task { [weak self] in
            do {
                try await session.connect()
                guard let self, self.session === session else { return }
                stateChanged(session.isBooted)
            } catch {
                guard let self, self.session === session else { return }
                phase = .failed("\(error)")
                render()
            }
        }
    }

    private func stateChanged(_ booted: Bool) {
        if booted {
            phase = .live
            if shown { session?.startScreen() }
            loadAppearance()
            loadOrientation()
            applyHardwareKeyboard()
        } else if phase != .starting {
            phase = .off
            screen.show(nil)
        }
        render()
    }

    // MARK: Device

    /// Runs `work` against the current session, reporting failures, unless
    /// the pane switched devices meanwhile.
    private func run<Value>(_ work: @escaping (DeviceSession) async throws -> Value,
                            then: @escaping (DevicePaneController, Value) -> Void = { _, _ in }) {
        guard let session else { return }
        Task { [weak self] in
            do {
                let value = try await work(session)
                guard let self, self.session === session else { return }
                then(self, value)
            } catch {
                guard let self, self.session === session else { return }
                model?.report(error)
            }
        }
    }

    private func start() {
        guard let session else { return }
        phase = .starting
        render()
        Task { [weak self] in
            do {
                try await session.boot()
            } catch {
                guard let self, self.session === session else { return }
                phase = .failed("\(error)")
                render()
            }
        }
    }

    private func shutDown() {
        run { try await $0.shutDown() }
    }

    private func press(_ button: DeviceButton) {
        session?.press(button)
    }

    private func pasteText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        screen.type(text)
    }

    /// A device starts each boot with its own keyboard setting, so the
    /// pane's is applied whenever it boots.
    private func applyHardwareKeyboard() {
        guard session?.hasHardwareKeyboardSwitch == true else { return }
        let connected = state.simulatesHardwareKeyboard
        run { try await $0.setHardwareKeyboard(connected) }
    }

    private func toggleHardwareKeyboard() {
        state.hardwareKeyboard = !state.simulatesHardwareKeyboard
        let saved = state
        _ = model?.edit { try $0.setDevice(self.pane, saved) }
        titleDidChange?()
        applyHardwareKeyboard()
    }

    private func loadOrientation() {
        guard let session else { return }
        Task { [weak self] in
            guard let orientation = try? await session.orientation(), let self, self.session === session else { return }
            screen.orientation = orientation
        }
    }

    /// Turns the device a quarter counterclockwise for each of `turns`.
    private func rotate(by turns: Int) {
        run({ try await $0.rotate(by: turns) }, then: { controller, orientation in
            controller.screen.orientation = orientation
        })
    }

    private func loadAppearance() {
        guard let session else { return }
        Task { [weak self] in
            let dark = try? await session.isDark()
            guard let self, self.session === session else { return }
            self.dark = dark
            titleDidChange?()
        }
    }

    private func toggleAppearance() {
        let dark = !(self.dark ?? false)
        self.dark = dark
        titleDidChange?()
        run { try await $0.setDark(dark) }
    }

    /// Copies the screen as a PNG and saves it to the Desktop.
    private func screenshot() {
        guard let surface = session?.surface else { return }
        let image = CIImage(ioSurface: surface)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let stamp = Self.stampFormatter.string(from: Date())
        let name = "\(state.name ?? "Device") \(stamp).png".replacingOccurrences(of: "/", with: "-")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard let url = desktop?.appendingPathComponent(name) else { return }
        do {
            try png.write(to: url)
            model?.presenter?.showToast("Screenshot copied and saved to the Desktop", error: false)
        } catch {
            model?.presenter?.showToast("Screenshot copied", error: false)
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    // MARK: Showing

    private func render() {
        screen.isHidden = phase != .live
        picker.isHidden = phase != .picking
        message.isHidden = phase == .live || phase == .picking
        let name = state.name ?? "The device"
        switch phase {
        case .loading:
            message.show(title: "", busy: true)
        case .starting:
            message.show(title: "Starting \(name)…", busy: true)
        case .off:
            message.show(title: "\(name) is shut down", button: "Start") { [weak self] in self?.start() }
        case .failed(let reason):
            message.show(title: "Can't show the device", detail: reason, button: "Choose Another…") { [weak self] in
                self?.showPicker()
            }
            if api == nil, let host {
                message.show(title: "Reconnect to \(host)", detail: "Its devices show here once it is connected.")
            }
        case .live, .picking:
            break
        }
        if phase == .live, root.window?.firstResponder === root { root.window?.makeFirstResponder(screen) }
        titleDidChange?()
    }
}

/// The pane's root: takes the keyboard while the screen isn't shown.
private final class DeviceRootView: ThemedView {
    override var acceptsFirstResponder: Bool { true }
}
