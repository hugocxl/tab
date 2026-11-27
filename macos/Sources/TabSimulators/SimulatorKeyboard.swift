import Foundation
import TabProtocol

/// Turns Mac keys and text into USB keyboard usages (HID page 7) for a
/// simulator's hardware keyboard.
public enum SimulatorKeyboard {
    public static let leftShift: UInt32 = 0xE1

    /// The usage of a Mac virtual key code, by position on an ANSI keyboard.
    public static func usage(keyCode: UInt16) -> UInt32? {
        keyCodes[keyCode]
    }

    /// The key presses that type `text`, with Shift where needed.
    public static func input(typing text: String) -> [SimulatorInput] {
        var input: [SimulatorInput] = []
        for stroke in strokes(for: text) {
            if stroke.shift { input.append(.key(usage: leftShift, down: true)) }
            input.append(.key(usage: stroke.usage, down: true))
            input.append(.key(usage: stroke.usage, down: false))
            if stroke.shift { input.append(.key(usage: leftShift, down: false)) }
        }
        return input
    }

    /// The keys that type `text` on a US layout, with Shift where needed.
    /// Characters a US keyboard can't type are skipped.
    public static func strokes(for text: String) -> [(usage: UInt32, shift: Bool)] {
        text.unicodeScalars.compactMap { scalar in
            let character = Character(scalar)
            if let usage = unshifted[character] { return (usage, false) }
            if let usage = shifted[character] { return (usage, true) }
            if character.isUppercase, let usage = unshifted[Character(character.lowercased())] { return (usage, true) }
            return nil
        }
    }

    /// Whether every character of `text` is on a US keyboard.
    public static func canType(_ text: String) -> Bool {
        strokes(for: text).count == text.unicodeScalars.count
    }

    /// The presses of a key or chord such as `return`, `backspace`,
    /// `cmd+a` or `shift+tab`: modifiers down in order, the key, then
    /// modifiers up. `nil` for a name it doesn't know.
    public static func chord(_ name: String) -> [SimulatorInput]? {
        let parts = name.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty else {
            return name == "+" ? input(typing: "+") : nil
        }
        var modifiers: [UInt32] = []
        for part in parts.dropLast() {
            guard let modifier = Self.modifiers[part.lowercased()] else { return nil }
            modifiers.append(modifier)
        }
        let key: UInt32
        var shift = false
        if let named = keys[last.lowercased()] {
            key = named
        } else if last.count == 1, let stroke = strokes(for: last).first {
            key = stroke.usage
            shift = stroke.shift
        } else {
            return nil
        }
        if shift, !modifiers.contains(leftShift) { modifiers.append(leftShift) }
        return modifiers.map { .key(usage: $0, down: true) }
            + [.key(usage: key, down: true), .key(usage: key, down: false)]
            + modifiers.reversed().map { .key(usage: $0, down: false) }
    }

    private static let modifiers: [String: UInt32] = [
        "ctrl": 0xE0, "control": 0xE0, "shift": 0xE1, "alt": 0xE2, "option": 0xE2, "opt": 0xE2,
        "cmd": 0xE3, "command": 0xE3, "meta": 0xE3,
    ]

    private static let keys: [String: UInt32] = {
        var keys: [String: UInt32] = [
            "return": 0x28, "enter": 0x28, "escape": 0x29, "esc": 0x29, "backspace": 0x2A, "delete": 0x2A,
            "tab": 0x2B, "space": 0x2C, "forward-delete": 0x4C, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
            "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "page-up": 0x4B, "pagedown": 0x4E, "page-down": 0x4E,
        ]
        for number in 1 ... 12 { keys["f\(number)"] = 0x3A + UInt32(number - 1) }
        return keys
    }()

    private static let letters: [(Character, UInt32)] = "abcdefghijklmnopqrstuvwxyz".enumerated().map {
        ($0.element, UInt32(0x04 + $0.offset))
    }

    private static let unshifted: [Character: UInt32] = Dictionary(uniqueKeysWithValues: letters + [
        ("1", 0x1E), ("2", 0x1F), ("3", 0x20), ("4", 0x21), ("5", 0x22),
        ("6", 0x23), ("7", 0x24), ("8", 0x25), ("9", 0x26), ("0", 0x27),
        ("\n", 0x28), ("\r", 0x28), ("\t", 0x2B), (" ", 0x2C), ("-", 0x2D), ("=", 0x2E),
        ("[", 0x2F), ("]", 0x30), ("\\", 0x31), (";", 0x33), ("'", 0x34), ("`", 0x35),
        (",", 0x36), (".", 0x37), ("/", 0x38),
    ])

    private static let shifted: [Character: UInt32] = [
        "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22,
        "^": 0x23, "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27,
        "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31,
        ":": 0x33, "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38,
    ]

    private static let keyCodes: [UInt16: UInt32] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A,
        0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11,
        0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18,
        0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22,
        0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C,
        0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31,
        0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,
        0x39: 0x39, 0x75: 0x4C, 0x73: 0x4A, 0x77: 0x4D, 0x74: 0x4B, 0x79: 0x4E,
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52, 0x4C: 0x58,
    ]
}
