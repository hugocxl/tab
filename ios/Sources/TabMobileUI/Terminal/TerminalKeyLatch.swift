import Foundation
import TabProtocol

/// Shift, Control and Option tapped on the on-screen keys. One tap holds a
/// modifier for the next key; a second tap soon after locks it until tapped
/// again.
struct TerminalKeyLatch: Equatable {
    static let lockInterval: TimeInterval = 0.4

    private(set) var once: KeyModifiers = []
    private(set) var locked: KeyModifiers = []
    private var lastTap: (modifier: KeyModifiers, time: TimeInterval)?

    /// The modifiers the next key gets.
    var active: KeyModifiers { once.union(locked) }

    mutating func tap(_ modifier: KeyModifiers, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        defer { lastTap = (modifier, time) }
        if locked.contains(modifier) {
            locked.remove(modifier)
            return
        }
        guard once.contains(modifier) else {
            once.insert(modifier)
            return
        }
        once.remove(modifier)
        if let lastTap, lastTap.modifier == modifier, time - lastTap.time < Self.lockInterval {
            locked.insert(modifier)
        }
    }

    /// The modifiers for a key just pressed; one-tap modifiers are used up.
    mutating func consume() -> KeyModifiers {
        let modifiers = active
        once = []
        return modifiers
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.once == rhs.once && lhs.locked == rhs.locked
    }
}
