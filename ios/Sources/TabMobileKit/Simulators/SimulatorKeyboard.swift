import Foundation
import TabProtocol

/// Turns typed text into USB keyboard usages (HID page 7) for a simulator's
/// hardware keyboard, as a US layout types them.
public enum SimulatorKeyboard {
    public static let returnKey: UInt32 = 0x28
    public static let backspace: UInt32 = 0x2A
    public static let leftShift: UInt32 = 0xE1

    /// The presses and releases that type `text`, with Shift where needed.
    /// Characters a US keyboard can't type are skipped.
    public static func input(typing text: String) -> [SimulatorInput] {
        strokes(for: text).flatMap { stroke -> [SimulatorInput] in
            let key: [SimulatorInput] = [.key(usage: stroke.usage, down: true), .key(usage: stroke.usage, down: false)]
            guard stroke.shift else { return key }
            return [.key(usage: leftShift, down: true)] + key + [.key(usage: leftShift, down: false)]
        }
    }

    /// One press and release of `usage`.
    public static func tap(_ usage: UInt32) -> [SimulatorInput] {
        [.key(usage: usage, down: true), .key(usage: usage, down: false)]
    }

    static func strokes(for text: String) -> [(usage: UInt32, shift: Bool)] {
        text.compactMap { character in
            if let usage = unshifted[character] { return (usage, false) }
            if let usage = shifted[character] { return (usage, true) }
            if character.isUppercase, let lower = character.lowercased().first, let usage = unshifted[lower] {
                return (usage, true)
            }
            return nil
        }
    }

    private static let unshifted: [Character: UInt32] = {
        var keys: [Character: UInt32] = [
            "1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21, "5": 0x22, "6": 0x23, "7": 0x24, "8": 0x25, "9": 0x26, "0": 0x27,
            "\n": returnKey, "\r": returnKey, "\r\n": returnKey, "\t": 0x2B, " ": 0x2C, "-": 0x2D, "=": 0x2E,
            "[": 0x2F, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38,
            // A phone's keyboard may still curl quotes.
            "‘": 0x34, "’": 0x34,
        ]
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { keys[letter] = 0x04 + UInt32(offset) }
        return keys
    }()

    private static let shifted: [Character: UInt32] = [
        "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27,
        "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31, ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37,
        "?": 0x38, "“": 0x34, "”": 0x34,
    ]
}
