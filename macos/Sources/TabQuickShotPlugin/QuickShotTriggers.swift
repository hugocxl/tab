import AppKit
import Carbon
import IOKit.hidsystem
import TabCore

/// Whether the active trigger can fire from any app.
public enum QuickShotTriggerStatus: Equatable, Sendable {
    case starting
    case ready
    /// macOS pauses keyboard listeners while a password field has Secure Keyboard Entry.
    case secureInput
    /// Tab lacks Input Monitoring, which both Command keys need.
    case inputMonitoringDenied
    case unavailable(String)

    public var title: String {
        switch self {
        case .starting: return "Starting…"
        case .ready: return "Ready"
        case .secureInput: return "Paused by Secure Keyboard Entry"
        case .inputMonitoringDenied: return "Needs Input Monitoring"
        case .unavailable(let reason): return reason
        }
    }

    /// Whether the trigger can't fire until the user acts.
    public var needsAttention: Bool { self != .ready && self != .starting }
}

/// Fires once when both Command keys are held. Release both to re-arm.
struct CommandChordDetector {
    private var blocked = false

    mutating func cancel() { blocked = true }

    /// Never treats keys held across a listener interruption as a fresh press.
    mutating func resynchronize(leftDown: Bool, rightDown: Bool) {
        blocked = leftDown || rightDown
    }

    mutating func update(leftDown: Bool, rightDown: Bool, otherModifierDown: Bool) -> Bool {
        if !leftDown && !rightDown {
            blocked = false
            return false
        }
        if otherModifierDown { blocked = true }
        guard leftDown && rightDown && !blocked else { return false }
        blocked = true
        return true
    }
}

// MARK: - Both Command keys

/// Listens for Left ⌘ + Right ⌘ from any app through a listen-only event tap
/// on its own thread, so a busy main thread never delays or drops the press.
@MainActor
final class CommandKeysMonitor {
    private var worker: CommandKeysWorker?

    func start(onPress: @escaping @MainActor () -> Void, onStatus: @escaping @MainActor (QuickShotTriggerStatus) -> Void) {
        guard worker == nil else { return }
        let worker = CommandKeysWorker(
            onPress: { Task { @MainActor in onPress() } },
            onStatus: { status in Task { @MainActor in onStatus(status) } }
        )
        self.worker = worker
        worker.start()
    }

    /// Reconnects after a permission grant, wake or a disabled tap.
    func refresh(reset: Bool) { worker?.refresh(reset: reset) }

    func stop() {
        worker?.stop()
        worker = nil
    }
}

/// The tap and detector are confined to the worker's thread. Only the run
/// loop handle and shutdown cross threads, under `controlLock`.
private final class CommandKeysWorker: @unchecked Sendable {
    private static let leftCommandKey: CGKeyCode = 55
    private static let rightCommandKey: CGKeyCode = 54

    private let onPress: @Sendable () -> Void
    private let onStatus: @Sendable (QuickShotTriggerStatus) -> Void
    private let controlLock = NSLock()
    private var loop: CFRunLoop?
    private var stopped = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = CommandChordDetector()
    private var lastStatus: QuickShotTriggerStatus?

    init(onPress: @escaping @Sendable () -> Void, onStatus: @escaping @Sendable (QuickShotTriggerStatus) -> Void) {
        self.onPress = onPress
        self.onStatus = onStatus
    }

    func start() {
        let thread = Thread { [self] in
            autoreleasepool {
                let current = CFRunLoopGetCurrent()
                controlLock.lock()
                if stopped {
                    controlLock.unlock()
                    return
                }
                loop = current
                controlLock.unlock()
                // Keeps the run loop alive for refresh and stop blocks even
                // while macOS refuses the tap. It never fires on its own.
                var context = CFRunLoopSourceContext(
                    version: 0, info: nil, retain: nil, release: nil, copyDescription: nil,
                    equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in }
                )
                let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
                CFRunLoopAddSource(current, keepAlive, .commonModes)
                connect()
                CFRunLoopRun()
                disconnect()
                CFRunLoopRemoveSource(current, keepAlive, .commonModes)
                controlLock.lock()
                loop = nil
                controlLock.unlock()
            }
        }
        thread.name = "QuickShot keyboard monitor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func refresh(reset: Bool) {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard !stopped, let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if reset { synchronizeKeys() }
            connect()
        }
        CFRunLoopWakeUp(loop)
    }

    func stop() {
        controlLock.lock()
        defer { controlLock.unlock() }
        stopped = true
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
        CFRunLoopWakeUp(loop)
    }

    private func synchronizeKeys() {
        detector.resynchronize(
            leftDown: CGEventSource.keyState(.combinedSessionState, key: Self.leftCommandKey),
            rightDown: CGEventSource.keyState(.combinedSessionState, key: Self.rightCommandKey)
        )
    }

    private func disconnect() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    private func connect() {
        // An enabled tap without the grant only sees Tab's own key presses.
        guard CGPreflightListenEventAccess() else {
            disconnect()
            report(.inputMonitoringDenied)
            return
        }
        if let tap, CFMachPortIsValid(tap) {
            if !CGEvent.tapIsEnabled(tap: tap) {
                synchronizeKeys()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if CGEvent.tapIsEnabled(tap: tap) {
                reportReady()
                return
            }
        }
        disconnect()
        synchronizeKeys()
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue))
        let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    Unmanaged<CommandKeysWorker>.fromOpaque(context).takeUnretainedValue().receive(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let created else {
            report(CGPreflightListenEventAccess() ? .unavailable("Keyboard monitor unavailable") : .inputMonitoringDenied)
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            report(.unavailable("Couldn't attach the keyboard monitor"))
            return
        }
        tap = created
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        if CGEvent.tapIsEnabled(tap: created) {
            reportReady()
        } else {
            report(.unavailable("Keyboard monitor unavailable"))
        }
    }

    private func reportReady() {
        report(IsSecureEventInputEnabled() ? .secureInput : .ready)
    }

    private func report(_ status: QuickShotTriggerStatus) {
        if lastStatus == .secureInput && status == .ready { synchronizeKeys() }
        guard lastStatus != status else { return }
        lastStatus = status
        onStatus(status)
    }

    /// The key path: no image work, AppKit or main-thread waits.
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            synchronizeKeys()
            connect()
            return
        }
        if type == .keyDown {
            if event.flags.contains(.maskCommand) { detector.cancel() }
            return
        }
        guard type == .flagsChanged else { return }
        let others: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        let fired = detector.update(
            leftDown: event.flags.rawValue & UInt64(NX_DEVICELCMDKEYMASK) != 0,
            rightDown: event.flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0,
            otherModifierDown: !event.flags.intersection(others).isEmpty
        )
        if fired { onPress() }
    }
}

// MARK: - Recorded shortcut

/// A system-wide shortcut registered with Carbon's hot key API, which needs
/// no privacy permission.
@MainActor
final class GlobalShortcut {
    private static let signature: OSType = 0x5153_4854 // "QSHT"
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?
    private static var nextId: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var id: UInt32 = 0

    /// Registers `chord`; returns why it can't be used, or `nil`.
    func register(_ chord: KeyChord, onPress: @escaping @MainActor () -> Void) -> String? {
        unregister()
        guard let keyCode = KeyCodes.virtualKeyCode(for: chord.key) else {
            return "\(chord.display) uses a key QuickShot can't listen for."
        }
        guard !chord.modifiers.contains(.function) else {
            return "Shortcuts with fn can't be used system-wide."
        }
        guard Self.installHandler() else { return "macOS refused the shortcut listener." }
        let id = Self.nextId
        Self.nextId += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(chord.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return "\(chord.display) is already taken by another shortcut."
        }
        hotKey = ref
        self.id = id
        Self.handlers[id] = onPress
        return nil
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        Self.handlers[id] = nil
        id = 0
    }

    private static func carbonModifiers(_ modifiers: ChordModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func installHandler() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyId = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyId
            )
            guard read == noErr, hotKeyId.signature == GlobalShortcut.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyId.id
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { GlobalShortcut.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        return status == noErr
    }
}

/// Maps a `KeyChord` key name to the virtual key code that types it on the
/// current keyboard layout.
enum KeyCodes {
    static let named: [String: UInt16] = [
        "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "delete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126, "insert": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
        "f18": 79, "f19": 80, "f20": 90,
    ]

    /// The US ANSI positions, used when the current layout can't be read.
    static let ansi: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    static func virtualKeyCode(for key: String) -> UInt16? {
        if let code = named[key] { return code }
        return layoutKeyCode(for: key) ?? ansi[key]
    }

    private static func layoutKeyCode(for key: String) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> UInt16? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in UInt16(0)..<128 where named.values.contains(code) == false {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
                )
                guard status == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: characters, count: length).lowercased() == key { return code }
            }
            return nil
        }
    }
}
