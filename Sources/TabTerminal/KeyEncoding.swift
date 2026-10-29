import CGhosttyVT
import Foundation
import TabProtocol

/// Encodes key events with the engine's key encoder, following the
/// terminal's live keyboard modes (cursor keys, keypad, kitty protocol...).
final class Keyboard {
    private let encoder: GhosttyKeyEncoder
    private let event: GhosttyKeyEvent
    private var buffer = [CChar](repeating: 0, count: 128)

    init() throws {
        var encoder: GhosttyKeyEncoder?
        var event: GhosttyKeyEvent?
        try Ghostty.check(ghostty_key_encoder_new(nil, &encoder), .create)
        guard let encoder else { throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue)) }
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS, let event else {
            ghostty_key_encoder_free(encoder)
            throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue))
        }
        self.encoder = encoder
        self.event = event
    }

    deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
    }

    func encode(_ key: KeyEvent, terminal: GhosttyTerminal) throws -> Data {
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
        var optionAsAlt = key.optionAsAlt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)
        ghostty_key_event_set_action(event, Self.action(key.action))
        ghostty_key_event_set_key(event, KeyNames.key(key.key))
        ghostty_key_event_set_mods(event, Self.mods(key.modifiers))
        ghostty_key_event_set_consumed_mods(event, Self.mods(key.consumedModifiers))
        ghostty_key_event_set_composing(event, false)
        ghostty_key_event_set_unshifted_codepoint(event, key.unshiftedCodepoint)
        var text = key.text
        defer { ghostty_key_event_set_utf8(event, nil, 0) }
        return try text.withUTF8 { utf8 in
            utf8.withMemoryRebound(to: CChar.self) { chars in
                ghostty_key_event_set_utf8(event, chars.isEmpty ? nil : chars.baseAddress, chars.count)
            }
            return try encodeEvent()
        }
    }

    private func encodeEvent() throws -> Data {
        var length = 0
        var result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &length)
        if result == GHOSTTY_OUT_OF_SPACE {
            buffer = [CChar](repeating: 0, count: max(length, buffer.count * 2))
            result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &length)
        }
        try Ghostty.check(result, .input)
        return buffer.withUnsafeBytes { Data($0.prefix(length)) }
    }

    private static func action(_ action: KeyAction) -> GhosttyKeyAction {
        switch action {
        case .press: GHOSTTY_KEY_ACTION_PRESS
        case .release: GHOSTTY_KEY_ACTION_RELEASE
        case .repeat: GHOSTTY_KEY_ACTION_REPEAT
        }
    }

    static func mods(_ modifiers: KeyModifiers) -> GhosttyMods {
        var mods: Int32 = 0
        if modifiers.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT }
        if modifiers.contains(.control) { mods |= GHOSTTY_MODS_CTRL }
        if modifiers.contains(.alt) { mods |= GHOSTTY_MODS_ALT }
        if modifiers.contains(.super) { mods |= GHOSTTY_MODS_SUPER }
        if modifiers.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS_LOCK }
        if modifiers.contains(.numLock) { mods |= GHOSTTY_MODS_NUM_LOCK }
        return GhosttyMods(mods)
    }
}

/// Key names in Ghostty's vocabulary (`arrow_up`, `page_down`, `numpad_1`),
/// plus the short names Codesh clients used (`up`, `pageup`, `numpad1`).
enum KeyNames {
    static func key(_ name: String) -> GhosttyKey {
        if let key = table[name] { return key }
        if let key = table[name.lowercased()] { return key }
        return GHOSTTY_KEY_UNIDENTIFIED
    }

    private static let table: [String: GhosttyKey] = {
        var table: [String: GhosttyKey] = [:]
        let letters: [GhosttyKey] = [
            GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D, GHOSTTY_KEY_E, GHOSTTY_KEY_F,
            GHOSTTY_KEY_G, GHOSTTY_KEY_H, GHOSTTY_KEY_I, GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L,
            GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O, GHOSTTY_KEY_P, GHOSTTY_KEY_Q, GHOSTTY_KEY_R,
            GHOSTTY_KEY_S, GHOSTTY_KEY_T, GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X,
            GHOSTTY_KEY_Y, GHOSTTY_KEY_Z,
        ]
        for (offset, key) in letters.enumerated() {
            let letter = String(UnicodeScalar(UInt8(ascii: "a") + UInt8(offset)))
            table[letter] = key
            table[letter.uppercased()] = key
        }
        let digits: [GhosttyKey] = [
            GHOSTTY_KEY_DIGIT_0, GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3, GHOSTTY_KEY_DIGIT_4,
            GHOSTTY_KEY_DIGIT_5, GHOSTTY_KEY_DIGIT_6, GHOSTTY_KEY_DIGIT_7, GHOSTTY_KEY_DIGIT_8, GHOSTTY_KEY_DIGIT_9,
        ]
        let numpad: [GhosttyKey] = [
            GHOSTTY_KEY_NUMPAD_0, GHOSTTY_KEY_NUMPAD_1, GHOSTTY_KEY_NUMPAD_2, GHOSTTY_KEY_NUMPAD_3,
            GHOSTTY_KEY_NUMPAD_4, GHOSTTY_KEY_NUMPAD_5, GHOSTTY_KEY_NUMPAD_6, GHOSTTY_KEY_NUMPAD_7,
            GHOSTTY_KEY_NUMPAD_8, GHOSTTY_KEY_NUMPAD_9,
        ]
        for (digit, key) in digits.enumerated() {
            table["\(digit)"] = key
            table["digit_\(digit)"] = key
        }
        for (digit, key) in numpad.enumerated() {
            table["numpad\(digit)"] = key
            table["numpad_\(digit)"] = key
        }
        for (shifted, digit) in zip(")!@#$%^&*(", 0...) {
            table[String(shifted)] = digits[digit]
        }
        let functionKeys: [GhosttyKey] = [
            GHOSTTY_KEY_F1, GHOSTTY_KEY_F2, GHOSTTY_KEY_F3, GHOSTTY_KEY_F4, GHOSTTY_KEY_F5, GHOSTTY_KEY_F6,
            GHOSTTY_KEY_F7, GHOSTTY_KEY_F8, GHOSTTY_KEY_F9, GHOSTTY_KEY_F10, GHOSTTY_KEY_F11, GHOSTTY_KEY_F12,
            GHOSTTY_KEY_F13, GHOSTTY_KEY_F14, GHOSTTY_KEY_F15, GHOSTTY_KEY_F16, GHOSTTY_KEY_F17, GHOSTTY_KEY_F18,
            GHOSTTY_KEY_F19, GHOSTTY_KEY_F20, GHOSTTY_KEY_F21, GHOSTTY_KEY_F22, GHOSTTY_KEY_F23, GHOSTTY_KEY_F24,
            GHOSTTY_KEY_F25,
        ]
        for (index, key) in functionKeys.enumerated() {
            table["f\(index + 1)"] = key
        }
        let named: [(String, GhosttyKey)] = [
            ("`", GHOSTTY_KEY_BACKQUOTE), ("~", GHOSTTY_KEY_BACKQUOTE), ("backquote", GHOSTTY_KEY_BACKQUOTE),
            ("\\", GHOSTTY_KEY_BACKSLASH), ("|", GHOSTTY_KEY_BACKSLASH), ("backslash", GHOSTTY_KEY_BACKSLASH),
            ("[", GHOSTTY_KEY_BRACKET_LEFT), ("{", GHOSTTY_KEY_BRACKET_LEFT), ("bracket_left", GHOSTTY_KEY_BRACKET_LEFT),
            ("]", GHOSTTY_KEY_BRACKET_RIGHT), ("}", GHOSTTY_KEY_BRACKET_RIGHT),
            ("bracket_right", GHOSTTY_KEY_BRACKET_RIGHT),
            (",", GHOSTTY_KEY_COMMA), ("<", GHOSTTY_KEY_COMMA), ("comma", GHOSTTY_KEY_COMMA),
            ("=", GHOSTTY_KEY_EQUAL), ("+", GHOSTTY_KEY_EQUAL), ("equal", GHOSTTY_KEY_EQUAL),
            ("-", GHOSTTY_KEY_MINUS), ("_", GHOSTTY_KEY_MINUS), ("minus", GHOSTTY_KEY_MINUS),
            (".", GHOSTTY_KEY_PERIOD), (">", GHOSTTY_KEY_PERIOD), ("period", GHOSTTY_KEY_PERIOD),
            ("'", GHOSTTY_KEY_QUOTE), ("\"", GHOSTTY_KEY_QUOTE), ("quote", GHOSTTY_KEY_QUOTE),
            (";", GHOSTTY_KEY_SEMICOLON), (":", GHOSTTY_KEY_SEMICOLON), ("semicolon", GHOSTTY_KEY_SEMICOLON),
            ("/", GHOSTTY_KEY_SLASH), ("?", GHOSTTY_KEY_SLASH), ("slash", GHOSTTY_KEY_SLASH),
            (" ", GHOSTTY_KEY_SPACE), ("space", GHOSTTY_KEY_SPACE),
            ("enter", GHOSTTY_KEY_ENTER), ("return", GHOSTTY_KEY_ENTER),
            ("tab", GHOSTTY_KEY_TAB), ("backspace", GHOSTTY_KEY_BACKSPACE),
            ("escape", GHOSTTY_KEY_ESCAPE), ("delete", GHOSTTY_KEY_DELETE), ("insert", GHOSTTY_KEY_INSERT),
            ("home", GHOSTTY_KEY_HOME), ("end", GHOSTTY_KEY_END),
            ("pageup", GHOSTTY_KEY_PAGE_UP), ("page_up", GHOSTTY_KEY_PAGE_UP),
            ("pagedown", GHOSTTY_KEY_PAGE_DOWN), ("page_down", GHOSTTY_KEY_PAGE_DOWN),
            ("up", GHOSTTY_KEY_ARROW_UP), ("arrow_up", GHOSTTY_KEY_ARROW_UP),
            ("down", GHOSTTY_KEY_ARROW_DOWN), ("arrow_down", GHOSTTY_KEY_ARROW_DOWN),
            ("left", GHOSTTY_KEY_ARROW_LEFT), ("arrow_left", GHOSTTY_KEY_ARROW_LEFT),
            ("right", GHOSTTY_KEY_ARROW_RIGHT), ("arrow_right", GHOSTTY_KEY_ARROW_RIGHT),
            ("numpadenter", GHOSTTY_KEY_NUMPAD_ENTER), ("numpad_enter", GHOSTTY_KEY_NUMPAD_ENTER),
            ("numpadadd", GHOSTTY_KEY_NUMPAD_ADD), ("numpad_add", GHOSTTY_KEY_NUMPAD_ADD),
            ("numpadsubtract", GHOSTTY_KEY_NUMPAD_SUBTRACT), ("numpad_subtract", GHOSTTY_KEY_NUMPAD_SUBTRACT),
            ("numpadmultiply", GHOSTTY_KEY_NUMPAD_MULTIPLY), ("numpad_multiply", GHOSTTY_KEY_NUMPAD_MULTIPLY),
            ("numpaddivide", GHOSTTY_KEY_NUMPAD_DIVIDE), ("numpad_divide", GHOSTTY_KEY_NUMPAD_DIVIDE),
            ("numpaddecimal", GHOSTTY_KEY_NUMPAD_DECIMAL), ("numpad_decimal", GHOSTTY_KEY_NUMPAD_DECIMAL),
            ("numpadequal", GHOSTTY_KEY_NUMPAD_EQUAL), ("numpad_equal", GHOSTTY_KEY_NUMPAD_EQUAL),
            ("context_menu", GHOSTTY_KEY_CONTEXT_MENU), ("help", GHOSTTY_KEY_HELP),
        ]
        for (name, key) in named {
            table[name] = key
        }
        return table
    }()
}

enum PasteEncoding {
    /// Encodes pasted text for the PTY: CRLF becomes one line break, 8-bit
    /// CSI and unsafe controls become spaces, and the text is wrapped in
    /// bracketed paste markers when the program asked for them.
    static func encode(_ text: Data, bracketed: Bool) throws -> Data {
        guard !text.isEmpty else { return Data() }
        var input = [UInt8]()
        input.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let byte = text[index]
            let next = text.index(after: index)
            if byte == 0x0d, next < text.endIndex, text[next] == 0x0a {
                index = next
                continue
            }
            if byte == 0xc2, next < text.endIndex, text[next] == 0x9b {
                input.append(UInt8(ascii: " "))
                index = text.index(after: next)
                continue
            }
            input.append(byte)
            index = next
        }
        var output = [CChar](repeating: 0, count: input.count + 12)
        var written = 0
        let result = input.withUnsafeMutableBytes { data in
            ghostty_paste_encode(
                data.baseAddress?.assumingMemoryBound(to: CChar.self), data.count, bracketed,
                &output, output.count, &written)
        }
        try Ghostty.check(result, .input)
        return output.withUnsafeBytes { Data($0.prefix(written)) }
    }
}
