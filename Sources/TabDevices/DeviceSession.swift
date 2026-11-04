import CoreGraphics
import Foundation
import IOSurface
import TabProtocol

/// One device pane's live link to a simulator or emulator: whether it runs,
/// its screen's surface while the pane is on screen, its input and its
/// controls. Screens stream only between `startScreen` and `stopScreen`.
@MainActor
public protocol DeviceSession: AnyObject {
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

extension DeviceOrientation {
    /// `panelPoint(x:y:)` for a point.
    public func panelPoint(_ upright: CGPoint) -> CGPoint {
        let point = panelPoint(x: upright.x, y: upright.y)
        return CGPoint(x: point.x, y: point.y)
    }
}

extension DeviceInput {
    /// A touch at a point on the panel's portrait screen.
    public static func touch(_ point: CGPoint, down: Bool) -> DeviceInput {
        .touch(x: point.x, y: point.y, down: down)
    }
}

extension SimulatorSession: DeviceSession {
    public var buttons: [DeviceButton] { [.home, .lock] }
    public var hasHardwareKeyboardSwitch: Bool { true }

    public func press(_ button: DeviceButton) {
        send(Self.buttonMessages(button))
    }

    public func boot() async throws { try await SimulatorControl.boot(udid) }
    public func shutDown() async throws { try await SimulatorControl.shutdown(udid) }
    public func isDark() async throws -> Bool { try await SimulatorControl.isDark(udid) }
    public func setDark(_ dark: Bool) async throws { try await SimulatorControl.setDark(udid, dark) }
    public func orientation() async throws -> DeviceOrientation { try await SimulatorControl.orientation(udid) }

    public func rotate(by turns: Int) async throws -> DeviceOrientation {
        let current = try await SimulatorControl.orientation(udid)
        return try await SimulatorControl.setOrientation(udid, DeviceOrientation(quarterTurns: current.quarterTurns + turns))
    }
}
