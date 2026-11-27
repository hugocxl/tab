import AppKit
import Carbon.HIToolbox

/// The current keyboard layout, for Option's automatic setting: U.S.
/// layouts send Alt, the others type their special characters.
@MainActor
enum KeyboardLayout {
    /// Layouts whose Option characters people rarely type.
    static let usLayouts: Set<String> = [
        "com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.USInternational-PC",
        "com.apple.keylayout.Dvorak", "com.apple.keylayout.Colemak",
    ]

    private static var cached: Bool?
    private static var observer: NSObjectProtocol?

    /// Whether the selected input source is a U.S. layout, read once and
    /// again whenever it changes.
    static var isUS: Bool {
        if let cached { return cached }
        observe()
        let value = currentIsUS()
        cached = value
        return value
    }

    private static func observe() {
        guard observer == nil else { return }
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { cached = nil }
        }
    }

    private static func currentIsUS() -> Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return true }
        let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return usLayouts.contains(id)
    }
}
