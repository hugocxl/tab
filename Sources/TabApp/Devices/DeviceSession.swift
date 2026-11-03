import AppKit
import IOSurface

/// The device platforms a device pane shows.
enum DevicePlatform: String, Sendable {
    case iOS
    case android
}

/// A hardware or navigation button a device has.
enum DeviceButton: Sendable {
    case home, back, recents, lock
}

/// One device pane's live link to a simulator or emulator: whether it runs,
/// its screen's surface while the pane is on screen, its input and its
/// controls. Screens stream only between `startScreen` and `stopScreen`.
@MainActor
protocol DeviceSession: AnyObject {
    var isBooted: Bool { get }
    var surface: IOSurface? { get }
    /// The device started or stopped.
    var onStateChange: ((Bool) -> Void)? { get set }
    /// The screen's surface was replaced.
    var onSurface: ((IOSurface) -> Void)? { get set }
    /// The screen drew into its current surface.
    var onFrame: (() -> Void)? { get set }
    var onInputError: ((Error) -> Void)? { get set }

    /// The buttons the header and menu offer.
    var buttons: [DeviceButton] { get }
    /// Whether the device can connect and disconnect a hardware keyboard.
    var hasHardwareKeyboardSwitch: Bool { get }

    /// Finds the device and starts following its state.
    func connect() async throws
    func startScreen()
    func stopScreen()
    func send(_ input: [DeviceInput])
    func press(_ button: DeviceButton)
    func boot() async throws
    func shutDown() async throws
    func isDark() async throws -> Bool
    func setDark(_ dark: Bool) async throws
    /// Connects or disconnects the hardware keyboard, if it has the switch.
    func setHardwareKeyboard(_ connected: Bool) async throws
    /// How the screen view turns the surface to show it upright.
    func orientation() async throws -> DeviceOrientation
    /// Turns the device a quarter counterclockwise per turn; returns how
    /// the screen view turns the surface now.
    func rotate(by turns: Int) async throws -> DeviceOrientation
    /// Stops everything; the device keeps running.
    func close()
}

extension SimulatorSession: DeviceSession {
    var buttons: [DeviceButton] { [.home, .lock] }
    var hasHardwareKeyboardSwitch: Bool { true }

    func press(_ button: DeviceButton) {
        let hardware: SimulatorBridge.HardwareButton
        switch button {
        case .home, .back, .recents: hardware = .home
        case .lock: hardware = .lock
        }
        send([SimulatorBridge.HIDMessage.button(hardware, down: true), .button(hardware, down: false)])
    }

    func boot() async throws { try await SimulatorControl.boot(udid) }
    func shutDown() async throws { try await SimulatorControl.shutdown(udid) }
    func isDark() async throws -> Bool { try await SimulatorControl.isDark(udid) }
    func setDark(_ dark: Bool) async throws { try await SimulatorControl.setDark(udid, dark) }
    func orientation() async throws -> DeviceOrientation { try await SimulatorControl.orientation(udid) }

    func rotate(by turns: Int) async throws -> DeviceOrientation {
        let current = try await SimulatorControl.orientation(udid)
        return try await SimulatorControl.setOrientation(udid, DeviceOrientation(quarterTurns: current.quarterTurns + turns))
    }
}
