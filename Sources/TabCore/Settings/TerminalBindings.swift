import Foundation

/// What a built-in terminal key does while a terminal has the keyboard.
public enum TerminalAction: Hashable, Sendable {
    /// Sends bytes to the program, such as a line feed for Shift+Return.
    case text([UInt8])
    case paste
    case selectAll
    case clearScreen
    case scrollTop
    case scrollBottom
    case scrollPageUp
    case scrollPageDown
    case resetFontSize

    /// The keys terminals handle before app shortcuts.
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
}
