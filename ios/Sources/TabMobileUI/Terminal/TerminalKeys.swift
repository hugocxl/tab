import TabProtocol
import UIKit

/// Turns keys into the `KeyEvent`s the server encodes with Ghostty, using the
/// same key names as the desktop app, so every program sees the same keys.
enum TerminalKeys {
    /// A hardware key press, or nil for keys the system should handle
    /// (Command shortcuts) or that mean nothing to a terminal.
    static func event(for key: UIKey, action: KeyAction = .press) -> KeyEvent? {
        let flags = key.modifierFlags
        guard !flags.contains(.command) else { return nil }
        let usage = key.keyCode.rawValue
        let unshifted = key.charactersIgnoringModifiers
        guard let name = named[usage] ?? characterNames[unshifted.lowercased()] ?? physical[usage] else { return nil }

        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.alt) }
        if flags.contains(.alphaShift) { modifiers.insert(.capsLock) }
        if flags.contains(.numericPad) { modifiers.insert(.numLock) }

        // Option acts as Alt, as on a US Mac keyboard: it never composes.
        let composing = !flags.contains(.control) && !flags.contains(.alternate)
        var text = composing ? key.characters : (flags.contains(.shift) ? unshifted.uppercased() : unshifted)
        if !isPrintable(text) { text = "" }
        var consumed: KeyModifiers = []
        if !text.isEmpty, composing, flags.contains(.shift) { consumed.insert(.shift) }
        let scalars = unshifted.unicodeScalars
        let codepoint = scalars.count == 1 && isPrintable(unshifted) ? scalars.first?.value ?? 0 : 0
        return KeyEvent(key: name, action: action, modifiers: modifiers, consumedModifiers: consumed,
                        text: action == .release ? "" : text, unshiftedCodepoint: codepoint,
                        optionAsAlt: flags.contains(.alternate))
    }

    /// A character typed with sticky Control or Alt from the accessory bar.
    static func event(for character: String, modifiers: KeyModifiers) -> KeyEvent? {
        let lower = character.lowercased()
        guard let name = characterNames[lower] ?? (character == " " ? "space" : nil) else { return nil }
        let codepoint = lower.unicodeScalars.count == 1 ? lower.unicodeScalars.first?.value ?? 0 : 0
        return KeyEvent(key: name, modifiers: modifiers, text: lower, unshiftedCodepoint: codepoint,
                        optionAsAlt: modifiers.contains(.alt))
    }

    static func isPrintable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.properties.generalCategory != .control && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    /// Keys named by position (HID usage), never by the text they type.
    static let named: [Int: String] = {
        var table: [Int: String] = [
            40: "enter", 41: "escape", 42: "backspace", 43: "tab", 44: "space", 73: "insert", 74: "home",
            75: "page_up", 76: "delete", 77: "end", 78: "page_down", 79: "arrow_right", 80: "arrow_left",
            81: "arrow_down", 82: "arrow_up", 88: "numpad_enter", 84: "numpad_divide", 85: "numpad_multiply",
            86: "numpad_subtract", 87: "numpad_add", 99: "numpad_decimal", 103: "numpad_equal", 101: "context_menu",
        ]
        for index in 0..<12 { table[58 + index] = "f\(index + 1)" }
        for index in 0..<12 { table[104 + index] = "f\(index + 13)" }
        for index in 0..<9 { table[89 + index] = "numpad_\(index + 1)" }
        table[98] = "numpad_0"
        return table
    }()

    static let characterNames: [String: String] = {
        var table: [String: String] = [
            "`": "backquote", "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
            "\\": "backslash", ";": "semicolon", "'": "quote", ",": "comma", ".": "period", "/": "slash",
        ]
        for letter in "abcdefghijklmnopqrstuvwxyz" { table[String(letter)] = String(letter) }
        for digit in 0...9 { table["\(digit)"] = "digit_\(digit)" }
        return table
    }()

    /// ANSI positions, for layouts whose keys type other characters.
    static let physical: [Int: String] = {
        var table: [Int: String] = [
            45: "minus", 46: "equal", 47: "bracket_left", 48: "bracket_right", 49: "backslash", 51: "semicolon",
            52: "quote", 53: "backquote", 54: "comma", 55: "period", 56: "slash",
        ]
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { table[4 + index] = String(letter) }
        for index in 0..<9 { table[30 + index] = "digit_\(index + 1)" }
        table[39] = "digit_0"
        return table
    }()
}
