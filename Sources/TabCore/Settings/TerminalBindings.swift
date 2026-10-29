import Foundation

/// What a terminal key binding does, in Ghostty's action names.
public enum TerminalAction: Hashable, Sendable, CustomStringConvertible {
    /// Sends bytes to the program, such as a line feed for Shift+Return.
    case text([UInt8])
    case ignore
    case unbind
    case copy
    case paste
    case selectAll
    case reload
    case clearScreen
    case scrollTop
    case scrollBottom
    case scrollPageUp
    case scrollPageDown
    case increaseFontSize(Double)
    case decreaseFontSize(Double)
    case resetFontSize

    /// Parses `text:\n`, `csi:A`, `clear_screen`, `increase_font_size:2`…
    public init(_ value: String) throws {
        switch try Self.parse(value) {
        case .supported(let action): self = action
        case .unsupported(let warning): throw SettingsError("keybind", warning)
        }
    }

    public var description: String {
        switch self {
        case .text(let bytes): return "text:\(Self.escape(bytes))"
        case .ignore: return "ignore"
        case .unbind: return "unbind"
        case .copy: return "copy_to_clipboard"
        case .paste: return "paste_from_clipboard"
        case .selectAll: return "select_all"
        case .reload: return "reload_config"
        case .clearScreen: return "clear_screen"
        case .scrollTop: return "scroll_to_top"
        case .scrollBottom: return "scroll_to_bottom"
        case .scrollPageUp: return "scroll_page_up"
        case .scrollPageDown: return "scroll_page_down"
        case .increaseFontSize(let amount): return "increase_font_size:\(Self.number(amount))"
        case .decreaseFontSize(let amount): return "decrease_font_size:\(Self.number(amount))"
        case .resetFontSize: return "reset_font_size"
        }
    }

    enum Parsed {
        case supported(TerminalAction)
        case unsupported(String)
    }

    static func parse(_ action: String) throws -> Parsed {
        let name: String
        let parameter: String
        if let colon = action.firstIndex(of: ":") {
            name = action[..<colon].trimmingCharacters(in: .whitespaces)
            parameter = String(action[action.index(after: colon)...])
        } else {
            name = action.trimmingCharacters(in: .whitespaces)
            parameter = ""
        }
        let parameterized = ["text", "esc", "csi", "increase_font_size", "decrease_font_size"]
        if !parameter.trimmingCharacters(in: .whitespaces).isEmpty && !parameterized.contains(name) {
            return .unsupported("keybind action \"\(name)\" with parameters is not supported by Tab")
        }
        switch name {
        case "text": return .supported(.text(try unescape(parameter)))
        case "esc": return .supported(.text([0x1B] + Array(parameter.utf8)))
        case "csi": return .supported(.text([0x1B, 0x5B] + Array(parameter.utf8)))
        case "ignore": return .supported(.ignore)
        case "unbind": return .supported(.unbind)
        case "copy_to_clipboard": return .supported(.copy)
        case "paste_from_clipboard": return .supported(.paste)
        case "select_all": return .supported(.selectAll)
        case "reload_config": return .supported(.reload)
        case "clear_screen": return .supported(.clearScreen)
        case "scroll_to_top": return .supported(.scrollTop)
        case "scroll_to_bottom": return .supported(.scrollBottom)
        case "scroll_page_up": return .supported(.scrollPageUp)
        case "scroll_page_down": return .supported(.scrollPageDown)
        case "increase_font_size":
            return .supported(.increaseFontSize(try fontAmount(parameter.trimmingCharacters(in: .whitespaces))))
        case "decrease_font_size":
            return .supported(.decreaseFontSize(try fontAmount(parameter.trimmingCharacters(in: .whitespaces))))
        case "reset_font_size": return .supported(.resetFontSize)
        default: return .unsupported("keybind action \"\(name)\" is not supported by Tab")
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func fontAmount(_ value: String) throws -> Double {
        let amount: Double
        if value.isEmpty {
            amount = 1
        } else if let parsed = Double(value) {
            amount = parsed
        } else {
            throw SettingsError("font size", "invalid number \"\(value)\"")
        }
        guard amount.isFinite, (0...256).contains(amount) else {
            throw SettingsError("font size", "expected a finite amount between 0 and 256")
        }
        return amount
    }

    static func escape(_ bytes: [UInt8]) -> String {
        var text = ""
        for (index, byte) in bytes.enumerated() {
            switch byte {
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x09: text += "\\t"
            case 0x1B: text += "\\e"
            case 0x5C: text += "\\\\"
            case 0x20 where index + 1 < bytes.count: text += " "
            case 0x21...0x7E: text.append(Character(Unicode.Scalar(byte)))
            default: text += String(format: "\\x%02x", byte)
            }
        }
        return text
    }

    static func unescape(_ value: String) throws -> [UInt8] {
        var result: [UInt8] = []
        var iterator = value.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\\" else {
                result += Array(String(scalar).utf8)
                continue
            }
            switch iterator.next() {
            case "n": result.append(0x0A)
            case "r": result.append(0x0D)
            case "t": result.append(0x09)
            case "e": result.append(0x1B)
            case "\\": result.append(0x5C)
            case "\"": result.append(0x22)
            case "x":
                var byte: UInt8 = 0
                for _ in 0..<2 {
                    guard let digit = iterator.next(), let value = UInt8(String(digit), radix: 16) else {
                        throw SettingsError("text", "expected two hex digits after \\x")
                    }
                    byte = byte << 4 | value
                }
                result.append(byte)
            default:
                throw SettingsError("text", "invalid escape sequence")
            }
        }
        return result
    }
}

/// Terminal key bindings from `terminal.json`, which win over app shortcuts
/// while a terminal has the keyboard, on top of the built-in ones unless
/// those are cleared. Stored as Ghostty `keybind` values, such as
/// `cmd+k=clear_screen`, with `clear` first to drop the built-ins.
public struct TerminalBindings: Codable, Equatable, Sendable {
    public var bindings: [KeyChord: TerminalAction]
    /// Drops the built-in bindings.
    public var clearDefaults: Bool

    public init(bindings: [KeyChord: TerminalAction] = [:], clearDefaults: Bool = false) {
        self.bindings = bindings
        self.clearDefaults = clearDefaults
    }

    /// The built-in bindings.
    public static let defaults: [KeyChord: TerminalAction] = {
        let entries: [(String, TerminalAction)] = [
            ("shift-enter", .text([0x0A])),
            ("cmd-shift-v", .paste),
            ("alt-left", .text([0x1B, 0x62])),
            ("alt-right", .text([0x1B, 0x66])),
            ("cmd-backspace", .text([0x15])),
            ("cmd-left", .text([0x01])),
            ("cmd-right", .text([0x05])),
            ("cmd-k", .clearScreen),
            ("cmd-a", .selectAll),
            ("cmd-home", .scrollTop),
            ("cmd-end", .scrollBottom),
            ("cmd-pageup", .scrollPageUp),
            ("cmd-pagedown", .scrollPageDown),
            ("cmd-0", .resetFontSize),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { (KeyChord.defaultBinding($0.0), $0.1) })
    }()

    /// What `chord` does in a terminal, if anything.
    public func action(for chord: KeyChord) -> TerminalAction? {
        if let action = bindings[chord] { return action }
        return clearDefaults ? nil : Self.defaults[chord]
    }

    /// Every chord that runs `action`, the user's first.
    public func chords(for action: TerminalAction) -> [KeyChord] {
        let own = bindings.filter { $0.value == action }.keys.sorted()
        guard !clearDefaults else { return own }
        let builtIn = Self.defaults.filter { $0.value == action && bindings[$0.key] == nil }.keys.sorted()
        return own + builtIn
    }

    /// The bindings as Ghostty `keybind` values.
    public var lines: [String] {
        var lines = [clearDefaults ? "clear" : ""]
        lines += bindings.sorted { $0.key < $1.key }.map { "\(Self.trigger($0.key))=\($0.value)" }
        return lines
    }

    /// Reads one `keybind` value, returning a warning for one Tab can't use.
    public mutating func read(_ value: String) throws -> String? {
        if value == "clear" || value.isEmpty {
            bindings.removeAll()
            clearDefaults = value == "clear"
            return value == "clear" ? "keybind = clear clears terminal bindings; Tab's app shortcuts remain in settings.json" : nil
        }
        guard let equals = value.firstIndex(of: "=") else {
            throw SettingsError("keybind", "expected trigger=action")
        }
        let trigger = String(value[..<equals])
        let action = String(value[value.index(after: equals)...])
        if trigger.contains(":") || trigger.contains(">") || trigger == "chain" || trigger.contains("catch_all") {
            return "keybind requires a single logical key without prefixes, sequences, or chains"
        }
        let key = try Self.chord(trigger.trimmingCharacters(in: .whitespaces))
        switch try TerminalAction.parse(action) {
        case .supported(let action):
            bindings[key] = action
            return nil
        case .unsupported(let warning):
            return warning
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([String].self)
        var bindings = TerminalBindings()
        for value in values {
            do {
                if let warning = try bindings.read(value), value != "clear" {
                    throw SettingsError("terminal keybindings", warning)
                }
            } catch {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
            }
        }
        self = bindings
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(lines)
    }

    /// A chord in Ghostty's trigger syntax, such as `cmd+shift+equal`.
    static func trigger(_ chord: KeyChord) -> String {
        var rest = Substring(chord.rawValue)
        var trigger = ""
        while let dash = rest.firstIndex(of: "-"), ["cmd", "ctrl", "alt", "shift"].contains(rest[..<dash]) {
            trigger += rest[..<dash] + "+"
            rest = rest[rest.index(after: dash)...]
        }
        switch rest {
        case "=": trigger += "equal"
        case "+": trigger += "plus"
        case "-": trigger += "minus"
        default: trigger += rest
        }
        return trigger
    }

    /// Parses a Ghostty trigger, such as `super+arrow_left`.
    static func chord(_ value: String) throws -> KeyChord {
        let aliases: [String: String] = [
            "super": "cmd", "command": "cmd", "control": "ctrl", "option": "alt", "opt": "alt",
            "arrow_left": "left", "ArrowLeft": "left", "arrow_right": "right", "ArrowRight": "right",
            "arrow_up": "up", "ArrowUp": "up", "arrow_down": "down", "ArrowDown": "down",
            "page_up": "pageup", "PageUp": "pageup", "page_down": "pagedown", "PageDown": "pagedown",
            "left_bracket": "[", "right_bracket": "]", "backslash": "\\", "slash": "/", "comma": ",",
            "period": ".", "equal": "=", "semicolon": ";", "quote": "'", "grave_accent": "`",
        ]
        var modifiers: [String] = []
        var key: String?
        for raw in value.split(separator: "+", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let part = aliases[trimmed] ?? trimmed
            if ["cmd", "ctrl", "alt", "shift"].contains(part) {
                modifiers.append(part)
            } else if key != nil {
                throw SettingsError("keybind", "expected one key per trigger")
            } else {
                key = part
            }
        }
        guard let key else { throw SettingsError("keybind", "missing key") }
        do {
            return try KeyChord((modifiers + [key]).joined(separator: "-"))
        } catch {
            throw SettingsError("keybind", "\(error)")
        }
    }
}
