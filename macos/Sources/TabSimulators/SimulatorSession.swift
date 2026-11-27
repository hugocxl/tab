import CoreGraphics
import Foundation
import IOSurface
import TabProtocol

/// One simulator pane's live link to a simulator or emulator: whether it runs,
/// its screen's surface while the pane is on screen, its input and its
/// controls. Screens stream only between `startScreen` and `stopScreen`.
@MainActor
public protocol SimulatorSession: AnyObject {
    var isBooted: Bool { get }
    var surface: IOSurface? { get }
    /// The simulator started or stopped.
    var onStateChange: ((Bool) -> Void)? { get set }
    /// The screen's surface was replaced.
    var onSurface: ((IOSurface) -> Void)? { get set }
    /// The screen drew into its current surface.
    var onFrame: (() -> Void)? { get set }
    var onInputError: ((Error) -> Void)? { get set }

    /// The buttons the header and menu offer.
    var buttons: [SimulatorButton] { get }
    /// Whether the simulator can connect and disconnect a hardware keyboard.
    var hasHardwareKeyboardSwitch: Bool { get }

    /// Finds the simulator and starts following its state.
    func connect() async throws
    func startScreen()
    func stopScreen()
    func send(_ input: [SimulatorInput])
    func press(_ button: SimulatorButton)
    func boot() async throws
    func shutDown() async throws
    func isDark() async throws -> Bool
    func setDark(_ dark: Bool) async throws
    /// Connects or disconnects the hardware keyboard, if it has the switch.
    func setHardwareKeyboard(_ connected: Bool) async throws
    /// How the screen view turns the surface to show it upright.
    func orientation() async throws -> SimulatorOrientation
    /// Turns the simulator a quarter counterclockwise per turn; returns how
    /// the screen view turns the surface now.
    func rotate(by turns: Int) async throws -> SimulatorOrientation
    /// Stops everything; the simulator keeps running.
    func close()
}

extension SimulatorOrientation {
    /// `panelPoint(x:y:)` for a point.
    public func panelPoint(_ upright: CGPoint) -> CGPoint {
        let point = panelPoint(x: upright.x, y: upright.y)
        return CGPoint(x: point.x, y: point.y)
    }
}

extension SimulatorInput {
    /// A touch at a point on the panel's portrait screen.
    public static func touch(_ point: CGPoint, down: Bool) -> SimulatorInput {
        .touch(x: point.x, y: point.y, down: down)
    }
}

extension IOSSimulatorSession: SimulatorSession {
    public var buttons: [SimulatorButton] { [.home, .lock] }
    public var hasHardwareKeyboardSwitch: Bool { true }

    public func press(_ button: SimulatorButton) {
        send(Self.buttonMessages(button))
    }

    public func boot() async throws { try await IOSSimulatorControl.boot(udid) }
    public func shutDown() async throws { try await IOSSimulatorControl.shutdown(udid) }
    public func isDark() async throws -> Bool { try await IOSSimulatorControl.isDark(udid) }
    public func setDark(_ dark: Bool) async throws { try await IOSSimulatorControl.setDark(udid, dark) }
    public func orientation() async throws -> SimulatorOrientation { try await IOSSimulatorControl.orientation(udid) }

    public func rotate(by turns: Int) async throws -> SimulatorOrientation {
        let current = try await IOSSimulatorControl.orientation(udid)
        return try await IOSSimulatorControl.setOrientation(udid, SimulatorOrientation(quarterTurns: current.quarterTurns + turns))
    }
}
