import AppKit
import TabCore
import TabProtocol

/// Turns AppKit key events into the engine's `KeyEvent`s (Ghostty key names,
/// modifiers, consumed modifiers, text, unshifted code point) and into
/// `KeyChord`s for bindings.
public enum KeyMapping {
    /// The device-dependent bits AppKit sets for the left and right Option keys.
    static let leftOption: UInt = 0x20
    static let rightOption: UInt = 0x40

    /// The key event for `event`, as a press, repeat or release.
    public static func keyEvent(_ event: NSEvent, optionAsAlt: OptionAsAlt, release: Bool = false) -> KeyEvent {
        keyEvent(keyCode: event.keyCode, characters: event.characters ?? "",
                 unshifted: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "",
                 shifted: event.characters(byApplyingModifiers: .shift), flags: event.modifierFlags,
                 isRepeat: event.type == .keyDown && event.isARepeat,
                 optionAsAlt: optionAsAlt, release: release)
    }

    /// The key event for a key code, the text it typed, the text it types with
    /// no modifiers, and the modifier flags.
    public static func keyEvent(keyCode: UInt16, characters: String, unshifted: String, shifted: String? = nil,
                                flags: NSEvent.ModifierFlags,
                                isRepeat: Bool = false, optionAsAlt: OptionAsAlt, release: Bool = false) -> KeyEvent {
        let modifiers = keyModifiers(flags)
        let alt = treatsOptionAsAlt(flags, optionAsAlt)
        let logical = keyCode == 49 ? " " : named[keyCode] == nil && unshifted.count == 1 ? unshifted : nil
        var text: String
        if modifiers.contains(.control) || (modifiers.contains(.alt) && alt) {
            text = logical.map { modifiers.contains(.shift) ? shifted ?? $0.uppercased() : $0 } ?? ""
        } else {
            text = characters.isEmpty ? logical ?? "" : characters
        }
        if !printable(text) { text = "" }
        var consumed: KeyModifiers = []
        if !text.isEmpty {
            if modifiers.contains(.shift) { consumed.insert(.shift) }
            if modifiers.contains(.alt) && !alt { consumed.insert(.alt) }
        }
        let unshiftedCodepoint: UInt32
        if keyCode == 49 {
            unshiftedCodepoint = 0x20
        } else if let logical, let scalar = logical.unicodeScalars.first, logical.unicodeScalars.count == 1,
                  printable(logical) {
            unshiftedCodepoint = scalar.value
        } else {
            unshiftedCodepoint = 0
        }
        return KeyEvent(key: keyName(keyCode: keyCode, unshifted: unshifted),
                        action: release ? .release : isRepeat ? .repeat : .press,
                        modifiers: modifiers, consumedModifiers: release ? [] : consumed, text: release ? "" : text,
                        unshiftedCodepoint: unshiftedCodepoint, optionAsAlt: alt)
    }

    public static func keyModifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.super) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        return modifiers
    }

    /// Whether Option acts as Alt for this event, per the setting and which
    /// Option key is down.
    public static func treatsOptionAsAlt(_ flags: NSEvent.ModifierFlags, _ setting: OptionAsAlt) -> Bool {
        guard flags.contains(.option) else { return setting != .none }
        let raw = flags.rawValue
        let left = raw & leftOption != 0
        let right = raw & rightOption != 0
        if !left && !right { return setting.enabled(left: true, right: true) }
        return setting.enabled(left: left, right: right)
    }

    /// Whether the key types text through the input method rather than going
    /// to the engine as a key: no Command or Control, Option not acting as
    /// Alt, and printable text.
    public static func usesTextInput(_ event: NSEvent, optionAsAlt: OptionAsAlt) -> Bool {
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) { return false }
        if flags.contains(.option) && treatsOptionAsAlt(flags, optionAsAlt) { return false }
        if named[event.keyCode] != nil && event.keyCode != 49 { return false }
        guard let text = event.characters, !text.isEmpty else { return false }
        return printable(text)
    }

    /// The key in Ghostty's vocabulary: named keys by key code, character
    /// keys by what the layout types without modifiers, falling back to the
    /// physical ANSI position.
    public static func keyName(keyCode: UInt16, unshifted: String) -> String {
        if let name = named[keyCode] { return name }
        if unshifted.count == 1, let name = characterNames[unshifted.lowercased()] { return name }
        return physical[keyCode] ?? unshifted.lowercased()
    }

    /// The chord a key event matches in key bindings and shortcuts, such as
    /// `cmd-shift-g` or `shift-enter`.
    public static func chord(_ event: NSEvent) -> KeyChord? {
        chord(keyCode: event.keyCode,
              unshifted: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "",
              flags: event.modifierFlags)
    }

    public static func chord(keyCode: UInt16, unshifted: String, flags: NSEvent.ModifierFlags) -> KeyChord? {
        let key: String
        if let name = chordNames[keyCode] {
            key = name
        } else if unshifted.count == 1, printable(unshifted) {
            key = unshifted.lowercased()
        } else if let name = physical[keyCode], name.count == 1 {
            key = name
        } else {
            return nil
        }
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.function), chordNames[keyCode] == nil { parts.append("fn") }
        parts.append(key == "-" ? "minus" : key == "+" ? "plus" : key)
        return try? KeyChord(parts.joined(separator: "-"))
    }

    static func printable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.generalCategory != .control && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    /// Keys named by position, never by the text they type.
    static let named: [UInt16: String] = {
        var table: [UInt16: String] = [
            36: "enter", 76: "numpad_enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape",
            117: "delete", 114: "insert", 115: "home", 119: "end", 116: "page_up", 121: "page_down",
            123: "arrow_left", 124: "arrow_right", 125: "arrow_down", 126: "arrow_up",
            82: "numpad_0", 83: "numpad_1", 84: "numpad_2", 85: "numpad_3", 86: "numpad_4", 87: "numpad_5",
            88: "numpad_6", 89: "numpad_7", 91: "numpad_8", 92: "numpad_9", 65: "numpad_decimal",
            67: "numpad_multiply", 69: "numpad_add", 75: "numpad_divide", 78: "numpad_subtract", 81: "numpad_equal",
            110: "context_menu",
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106,
                                      64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() { table[code] = "f\(index + 1)" }
        return table
    }()

    /// Named keys in `KeyChord` syntax.
    static let chordNames: [UInt16: String] = {
        var table: [UInt16: String] = [
            36: "enter", 76: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape", 117: "delete",
            114: "insert", 115: "home", 119: "end", 116: "pageup", 121: "pagedown", 123: "left", 124: "right",
            125: "down", 126: "up",
        ]
        for (code, name) in named where name.hasPrefix("f") && Int(name.dropFirst()) != nil { table[code] = name }
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

    /// ANSI key positions, for layouts whose keys type other characters.
    static let physical: [UInt16: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l",
        46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
        16: "y", 6: "z", 29: "digit_0", 18: "digit_1", 19: "digit_2", 20: "digit_3", 21: "digit_4", 23: "digit_5",
        22: "digit_6", 26: "digit_7", 28: "digit_8", 25: "digit_9", 27: "minus", 24: "equal", 33: "bracket_left",
        30: "bracket_right", 42: "backslash", 41: "semicolon", 39: "quote", 43: "comma", 47: "period", 44: "slash",
        50: "backquote",
    ]
}
