import AppKit
import IOSurface
import ObjectiveC
import TabCore

/// Calls into Xcode's private CoreSimulator and SimulatorKit frameworks,
/// loaded at runtime from the selected Xcode: the device's live screen as
/// IOSurfaces and its touch, button and keyboard input as Indigo HID
/// messages. Listing, booting and settings go through `simctl` instead.
/// Everything here runs on `queue`, except the screen callbacks, which run on
/// the main queue.
final class SimulatorBridge: @unchecked Sendable {
    static let shared = SimulatorBridge()

    /// Serializes calls into CoreSimulator and the HID clients.
    let queue = DispatchQueue(label: "com.hugocorta.tab.simulator")

    private var loaded: Result<Loaded, SimulatorError>?

    private struct Loaded {
        let deviceSet: AnyObject
        let simulatorKit: UnsafeMutableRawPointer
    }

    /// The frameworks and the default device set, loaded on first use.
    private func load() throws -> Loaded {
        dispatchPrecondition(condition: .onQueue(queue))
        if let loaded { return try loaded.get() }
        let result = Result { try Self.loadFrameworks() }.mapError { $0 as? SimulatorError ?? .unavailable("\($0)") }
        loaded = result
        return try result.get()
    }

    private static func loadFrameworks() throws -> Loaded {
        let developer = try SimulatorControl.developerDirectory()
        let coreSimulator = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(developer)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
        ]
        let simulatorKit = [
            "\(developer)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(developer)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
        ]
        guard coreSimulator.contains(where: { dlopen($0, RTLD_NOW) != nil }) else {
            throw SimulatorError.unavailable("CoreSimulator could not be loaded")
        }
        guard let kit = simulatorKit.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else {
            throw SimulatorError.unavailable("SimulatorKit could not be loaded from \(developer)")
        }
        guard let contextClass = NSClassFromString("SimServiceContext") else {
            throw SimulatorError.unavailable("CoreSimulator has no service context")
        }
        typealias ContextFunction = @convention(c) (AnyClass, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let contextMethod = class_getClassMethod(contextClass, contextSelector) else {
            throw SimulatorError.unavailable("CoreSimulator changed its service context")
        }
        var error: NSError?
        let shared = unsafeBitCast(method_getImplementation(contextMethod), to: ContextFunction.self)
        guard let context = shared(contextClass, contextSelector, developer as NSString, &error) else {
            throw SimulatorError.unavailable(error?.localizedDescription ?? "no simulator service")
        }
        typealias SetFunction = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let setMethod = class_getMethodImplementation(type(of: context), setSelector),
              let deviceSet = unsafeBitCast(setMethod, to: SetFunction.self)(context, setSelector, &error) else {
            throw SimulatorError.unavailable(error?.localizedDescription ?? "no simulator device set")
        }
        return Loaded(deviceSet: deviceSet, simulatorKit: kit)
    }

    /// The `SimDevice` with `udid`.
    func device(_ udid: String) throws -> AnyObject {
        let set = try load().deviceSet
        let devices = Self.call(set, "devices") as? [AnyObject] ?? []
        guard let device = devices.first(where: { (Self.call($0, "UDID") as? NSUUID)?.uuidString == udid }) else {
            throw SimulatorError.notFound
        }
        return device
    }

    // MARK: State

    /// Calls `handler` on the main queue whenever `device` changes state.
    /// Returns the registration to pass to `unregisterNotifications`.
    func registerNotifications(_ device: AnyObject, handler: @escaping () -> Void) -> UInt? {
        let selector = NSSelectorFromString("registerNotificationHandlerOnQueue:handler:")
        guard device.responds(to: selector), let method = class_getMethodImplementation(type(of: device), selector) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector, DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> UInt
        return unsafeBitCast(method, to: Function.self)(device, selector, .main) { _ in handler() }
    }

    func unregisterNotifications(_ device: AnyObject, _ registration: UInt) {
        let selector = NSSelectorFromString("unregisterNotificationHandler:error:")
        guard device.responds(to: selector), let method = class_getMethodImplementation(type(of: device), selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, UInt, UnsafeMutablePointer<NSError?>?) -> Bool
        _ = unsafeBitCast(method, to: Function.self)(device, selector, registration, nil)
    }

    static func isBooted(_ device: AnyObject) -> Bool {
        call(device, "stateString") as? String == "Booted"
    }

    // MARK: Screen

    private static let registerScreen = NSSelectorFromString(
        "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
    )
    private static let unregisterScreen = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
    private static let framebufferSurface = NSSelectorFromString("framebufferSurface")

    /// The device's screens: IO port descriptors that render to IOSurfaces.
    /// A device has several; only the one showing its display sends frames.
    func screens(_ device: AnyObject) -> [AnyObject] {
        guard let io = Self.call(device, "io") else { return [] }
        let ports = Self.call(io, "ioPorts") as? [AnyObject] ?? []
        return ports.compactMap { port in
            guard let descriptor = Self.call(port, "descriptor"), descriptor.responds(to: Self.registerScreen) else { return nil }
            return descriptor
        }
    }

    /// Calls `surfaces` on the main queue when `screen` gets new surfaces,
    /// including once on registering, and `frame` whenever it draws.
    func registerScreen(_ screen: AnyObject, id: UUID, surfaces: @escaping () -> Void, frame: @escaping () -> Void) {
        guard let method = class_getMethodImplementation(type(of: screen), Self.registerScreen) else { return }
        typealias Function = @convention(c) (
            AnyObject, Selector, NSUUID, DispatchQueue,
            @escaping @convention(block) () -> Void,
            @escaping @convention(block) (AnyObject?, AnyObject?) -> Void,
            @escaping @convention(block) (AnyObject?) -> Void
        ) -> Void
        unsafeBitCast(method, to: Function.self)(screen, Self.registerScreen, id as NSUUID, .main, frame, { _, _ in surfaces() }, { _ in })
    }

    func unregisterScreen(_ screen: AnyObject, id: UUID) {
        guard screen.responds(to: Self.unregisterScreen) else { return }
        _ = screen.perform(Self.unregisterScreen, with: id as NSUUID)
    }

    /// The surface `screen` draws into now.
    static func surface(of screen: AnyObject) -> IOSurface? {
        guard screen.responds(to: framebufferSurface) else { return nil }
        return screen.perform(framebufferSurface)?.takeUnretainedValue() as? IOSurface
    }

    /// The device type's screen size in pixels, to tell its display from the
    /// other surfaces it renders.
    static func screenSize(_ device: AnyObject) -> CGSize? {
        guard let type = call(device, "deviceType") else { return nil }
        let selector = NSSelectorFromString("mainScreenSize")
        guard type.responds(to: selector), let method = class_getMethodImplementation(Swift.type(of: type), selector) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector) -> CGSize
        let size = unsafeBitCast(method, to: Function.self)(type, selector)
        return size.width > 0 && size.height > 0 ? size : nil
    }

    // MARK: Input

    /// A HID client sending input to `device`.
    func hidClient(_ device: AnyObject) throws -> AnyObject {
        _ = try load()
        guard let hidClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            throw SimulatorError.unavailable("SimulatorKit has no HID client")
        }
        let selector = NSSelectorFromString("initWithDevice:error:")
        guard let method = class_getMethodImplementation(hidClass, selector),
              let allocated = (hidClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
            throw SimulatorError.unavailable("SimulatorKit changed its HID client")
        }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        var error: NSError?
        guard let client = unsafeBitCast(method, to: Function.self)(allocated, selector, device, &error) else {
            throw SimulatorError.unavailable(error?.localizedDescription ?? "no HID client")
        }
        return client
    }

    /// Connects or disconnects `device`'s hardware keyboard. While it is
    /// disconnected the device ignores keyboard input and shows its
    /// on-screen keyboard instead.
    func setHardwareKeyboard(_ device: AnyObject, connected: Bool) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let selector = NSSelectorFromString("setHardwareKeyboardEnabled:keyboardType:error:")
        guard device.responds(to: selector), let method = class_getMethodImplementation(type(of: device), selector) else {
            throw SimulatorError.unavailable("CoreSimulator can't connect a hardware keyboard")
        }
        typealias Function = @convention(c) (AnyObject, Selector, Bool, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool
        var error: NSError?
        // Keyboard type 0 is the device's default layout.
        guard unsafeBitCast(method, to: Function.self)(device, selector, connected, 0, &error) else {
            throw SimulatorError.unavailable(error?.localizedDescription ?? "the hardware keyboard didn't change")
        }
    }

    /// Sends `messages` in order. Each message is freed once sent.
    func send(_ messages: [HIDMessage], to client: AnyObject) {
        dispatchPrecondition(condition: .onQueue(queue))
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let method = class_getMethodImplementation(type(of: client), selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue?, (@convention(block) (NSError?) -> Void)?) -> Void
        let send = unsafeBitCast(method, to: Function.self)
        for message in messages {
            guard let pointer = build(message) else { continue }
            send(client, selector, pointer, true, nil, nil)
        }
    }

    /// One Indigo HID message, before SimulatorKit builds it.
    enum HIDMessage {
        /// A finger at `point` within a screen of `size` pixels; `down` is
        /// false for the lift.
        case touch(point: CGPoint, size: CGSize, down: Bool)
        case button(HardwareButton, down: Bool)
        /// A USB keyboard usage, page 7.
        case key(UInt32, down: Bool)
    }

    enum HardwareButton: Int32 {
        case home = 0x0
        case lock = 0x1
        case side = 0xbb8
    }

    private enum Target {
        static let digitizer: UInt32 = 0x32
        static let hardware: Int32 = 0x33
    }

    private enum Direction {
        static let down: UInt32 = 1
        static let up: UInt32 = 2
    }

    private func build(_ message: HIDMessage) -> UnsafeMutableRawPointer? {
        guard let kit = try? load().simulatorKit else { return nil }
        switch message {
        case let .touch(point, size, down):
            typealias Function = @convention(c) (UnsafePointer<CGPoint>?, UnsafePointer<CGPoint>?, UInt32, UInt, Double, Double, UInt32) -> UnsafeMutableRawPointer?
            guard let symbol = dlsym(kit, "IndigoHIDMessageForMouseNSEvent") else { return nil }
            var point = point
            let type = UInt(down ? Direction.down : Direction.up)
            return unsafeBitCast(symbol, to: Function.self)(&point, nil, Target.digitizer, type, size.width, size.height, 0)
        case let .button(button, down):
            typealias Function = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?
            guard let symbol = dlsym(kit, "IndigoHIDMessageForButton") else { return nil }
            return unsafeBitCast(symbol, to: Function.self)(button.rawValue, Int32(down ? Direction.down : Direction.up), Target.hardware)
        case let .key(usage, down):
            typealias Function = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
            guard let symbol = dlsym(kit, "IndigoHIDMessageForKeyboardArbitrary") else { return nil }
            return unsafeBitCast(symbol, to: Function.self)(usage, down ? Direction.down : Direction.up)
        }
    }

    private static func call(_ object: AnyObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
}

/// Why a simulator can't be shown.
enum SimulatorError: Error, Equatable, CustomStringConvertible {
    /// Xcode or its simulator frameworks are missing or changed.
    case unavailable(String)
    /// No simulator has the pane's UDID any more.
    case notFound

    var description: String {
        switch self {
        case .unavailable(let reason): return reason
        case .notFound: return "This simulator no longer exists"
        }
    }
}
