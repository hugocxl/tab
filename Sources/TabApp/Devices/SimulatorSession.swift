import AppKit
import IOSurface

/// One pane's live link to a simulator: whether it is booted, its screen's
/// surface while the pane is on screen, and its input. Screen callbacks
/// arrive only while `streaming`, so a hidden pane costs nothing.
@MainActor
final class SimulatorSession {
    let udid: String
    /// The device booted or shut down.
    var onStateChange: ((Bool) -> Void)?
    /// The screen's surface was replaced, such as on first connect or a
    /// rotation.
    var onSurface: ((IOSurface) -> Void)?
    /// The screen drew into its current surface.
    var onFrame: (() -> Void)?

    private(set) var isBooted = false
    private(set) var surface: IOSurface?

    private let bridge = SimulatorBridge.shared
    private var device: AnyObject?
    private var hid: AnyObject?
    private var notifications: UInt?
    private var screens: [AnyObject] = []
    private var registration: UUID?
    private var expectedSize: CGSize?
    private var shownScreen: ObjectIdentifier?
    private var closed = false

    init(udid: String) {
        self.udid = udid
    }

    /// Finds the device and starts following its state.
    func connect() async throws {
        let bridge = bridge
        let udid = udid
        let (device, booted, size) = try await withCheckedThrowingContinuation { continuation in
            bridge.queue.async {
                do {
                    let device = try bridge.device(udid)
                    continuation.resume(returning: (device, SimulatorBridge.isBooted(device), SimulatorBridge.screenSize(device)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard !closed else { return }
        self.device = device
        expectedSize = size
        isBooted = booted
        notifications = bridge.registerNotifications(device) { [weak self] in
            MainActor.assumeIsolated { self?.stateMayHaveChanged() }
        }
    }

    private func stateMayHaveChanged() {
        guard let device, !closed else { return }
        let booted = SimulatorBridge.isBooted(device)
        guard booted != isBooted else { return }
        isBooted = booted
        if !booted {
            hid = nil
            surface = nil
        }
        let streaming = registration != nil
        if streaming {
            stopScreen()
            if booted { startScreen() }
        }
        onStateChange?(booted)
    }

    // MARK: Screen

    /// Starts receiving the screen, if booted.
    func startScreen() {
        guard registration == nil, isBooted, let device, !closed else { return }
        let id = UUID()
        registration = id
        let bridge = bridge
        bridge.queue.async { [weak self] in
            let screens = bridge.screens(device)
            for screen in screens {
                bridge.registerScreen(screen, id: id, surfaces: { [weak self] in
                    MainActor.assumeIsolated { self?.surfacesChanged(screen) }
                }, frame: { [weak self] in
                    MainActor.assumeIsolated { self?.screenDrew(screen) }
                })
            }
            DispatchQueue.main.async {
                guard let self, self.registration == id else {
                    bridge.queue.async { for screen in screens { bridge.unregisterScreen(screen, id: id) } }
                    return
                }
                self.screens = screens
            }
        }
    }

    /// Stops receiving the screen.
    func stopScreen() {
        guard let id = registration else { return }
        registration = nil
        let screens = screens
        self.screens = []
        shownScreen = nil
        let bridge = bridge
        bridge.queue.async { for screen in screens { bridge.unregisterScreen(screen, id: id) } }
    }

    /// A device has several screens; the one whose surface fits its display
    /// becomes the pane's. Reading a surface asks the simulator, so it
    /// happens only when they change, not per frame.
    private func surfacesChanged(_ screen: AnyObject) {
        guard registration != nil, let latest = SimulatorBridge.surface(of: screen), fitsDisplay(latest) else { return }
        shownScreen = ObjectIdentifier(screen)
        surface = latest
        onSurface?(latest)
    }

    private func screenDrew(_ screen: AnyObject) {
        guard registration != nil, shownScreen == ObjectIdentifier(screen) else { return }
        onFrame?()
    }

    private func fitsDisplay(_ surface: IOSurface) -> Bool {
        let size = CGSize(width: surface.width, height: surface.height)
        guard size.width > 0, size.height > 0 else { return false }
        guard let expectedSize else { return max(size.width, size.height) < 7680 }
        return size == expectedSize || size == CGSize(width: expectedSize.height, height: expectedSize.width)
    }

    // MARK: Input

    /// Sends input in order. Touches land on the panel's surface.
    func send(_ input: [DeviceInput]) {
        let size = surface.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        send(input.compactMap { item -> SimulatorBridge.HIDMessage? in
            switch item {
            case let .touch(point, down):
                guard size.width > 0 else { return nil }
                return .touch(point: CGPoint(x: point.x * size.width, y: point.y * size.height), size: size, down: down)
            case let .key(usage, down):
                return .key(usage, down: down)
            }
        })
    }

    /// Sends HID messages in order, connecting the HID client on first use.
    func send(_ messages: [SimulatorBridge.HIDMessage]) {
        guard isBooted, let device, !closed, !messages.isEmpty else { return }
        let bridge = bridge
        let existing = hid
        bridge.queue.async { [weak self] in
            let client: AnyObject
            if let existing {
                client = existing
            } else {
                do {
                    client = try bridge.hidClient(device)
                } catch {
                    DispatchQueue.main.async { self?.inputFailed(error) }
                    return
                }
                DispatchQueue.main.async { self?.hid = client }
            }
            bridge.send(messages, to: client)
        }
    }

    /// Connects or disconnects the device's hardware keyboard.
    func setHardwareKeyboard(_ connected: Bool) async throws {
        guard isBooted, let device, !closed else { return }
        let bridge = bridge
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.queue.async {
                continuation.resume(with: Result { try bridge.setHardwareKeyboard(device, connected: connected) })
            }
        }
    }

    var onInputError: ((Error) -> Void)?

    private func inputFailed(_ error: Error) {
        onInputError?(error)
    }

    /// Stops everything; the simulator keeps running.
    func close() {
        closed = true
        stopScreen()
        if let device, let notifications {
            bridge.unregisterNotifications(device, notifications)
        }
        notifications = nil
        hid = nil
        device = nil
    }
}
