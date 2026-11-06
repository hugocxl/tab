import Foundation
import IOSurface
import TabProtocol

/// One pane's live link to a simulator: whether it is booted, its screen's
/// surface while the pane is on screen, and its input. Screen callbacks
/// arrive only while `streaming`, so a hidden pane costs nothing.
@MainActor
public final class IOSSimulatorSession {
    public let udid: String
    /// The simulator booted or shut down.
    public var onStateChange: ((Bool) -> Void)?
    /// The screen's surface was replaced, such as on first connect or a
    /// rotation.
    public var onSurface: ((IOSurface) -> Void)?
    /// The screen drew into its current surface.
    public var onFrame: (() -> Void)?

    public private(set) var isBooted = false
    public private(set) var surface: IOSurface?

    private let bridge = IOSSimulatorBridge.shared
    private var simulator: AnyObject?
    private var hid: AnyObject?
    private var notifications: UInt?
    private var screens: [AnyObject] = []
    private var registration: UUID?
    private var expectedSize: CGSize?
    private var shownScreen: ObjectIdentifier?
    private var closed = false

    public init(udid: String) {
        self.udid = udid
    }

    /// Finds the simulator and starts following its state.
    public func connect() async throws {
        let bridge = bridge
        let udid = udid
        let (simulator, booted, size) = try await withCheckedThrowingContinuation { continuation in
            bridge.queue.async {
                do {
                    let simulator = try bridge.simulator(udid)
                    continuation.resume(returning: (simulator, IOSSimulatorBridge.isBooted(simulator), IOSSimulatorBridge.screenSize(simulator)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard !closed else { return }
        self.simulator = simulator
        expectedSize = size
        isBooted = booted
        notifications = bridge.registerNotifications(simulator, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.stateMayHaveChanged() }
        }
    }

    private func stateMayHaveChanged() {
        guard let simulator, !closed else { return }
        let booted = IOSSimulatorBridge.isBooted(simulator)
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
    public func startScreen() {
        guard registration == nil, isBooted, let simulator, !closed else { return }
        let id = UUID()
        registration = id
        let bridge = bridge
        bridge.queue.async { [weak self] in
            let screens = bridge.screens(simulator)
            for screen in screens {
                bridge.registerScreen(screen, id: id, queue: .main, surfaces: { [weak self] in
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
    public func stopScreen() {
        guard let id = registration else { return }
        registration = nil
        let screens = screens
        self.screens = []
        shownScreen = nil
        let bridge = bridge
        bridge.queue.async { for screen in screens { bridge.unregisterScreen(screen, id: id) } }
    }

    /// A simulator has several screens; the one whose surface fits its display
    /// becomes the pane's. Reading a surface asks the simulator, so it
    /// happens only when they change, not per frame.
    private func surfacesChanged(_ screen: AnyObject) {
        guard registration != nil, let latest = IOSSimulatorBridge.surface(of: screen), fitsDisplay(latest) else { return }
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
    public func send(_ input: [SimulatorInput]) {
        let size = surface.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        var messages: [IOSSimulatorBridge.HIDMessage] = []
        for item in input {
            switch item {
            case let .touch(x, y, down):
                guard size.width > 0 else { continue }
                messages.append(.touch(point: CGPoint(x: x * size.width, y: y * size.height), size: size, down: down))
            case let .key(usage, down):
                messages.append(.key(usage, down: down))
            case .button(let button):
                messages += Self.buttonMessages(button)
            case .unknown:
                continue
            }
        }
        send(messages)
    }

    static func buttonMessages(_ button: SimulatorButton) -> [IOSSimulatorBridge.HIDMessage] {
        let hardware: IOSSimulatorBridge.HardwareButton = button == .lock ? .lock : .home
        return [.button(hardware, down: true), .button(hardware, down: false)]
    }

    /// Sends HID messages in order, connecting the HID client on first use.
    func send(_ messages: [IOSSimulatorBridge.HIDMessage]) {
        guard isBooted, let simulator, !closed, !messages.isEmpty else { return }
        let bridge = bridge
        let existing = hid
        bridge.queue.async { [weak self] in
            let client: AnyObject
            if let existing {
                client = existing
            } else {
                do {
                    client = try bridge.hidClient(simulator)
                } catch {
                    DispatchQueue.main.async { self?.inputFailed(error) }
                    return
                }
                DispatchQueue.main.async { self?.hid = client }
            }
            bridge.send(messages, to: client)
        }
    }

    /// Connects or disconnects the simulator's hardware keyboard.
    public func setHardwareKeyboard(_ connected: Bool) async throws {
        guard isBooted, let simulator, !closed else { return }
        let bridge = bridge
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.queue.async {
                continuation.resume(with: Result { try bridge.setHardwareKeyboard(simulator, connected: connected) })
            }
        }
    }

    public var onInputError: ((Error) -> Void)?

    private func inputFailed(_ error: Error) {
        onInputError?(error)
    }

    /// Stops everything; the simulator keeps running.
    public func close() {
        closed = true
        stopScreen()
        if let simulator, let notifications {
            bridge.unregisterNotifications(simulator, notifications)
        }
        notifications = nil
        hid = nil
        simulator = nil
    }
}
