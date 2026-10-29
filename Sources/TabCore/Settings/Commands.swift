import Foundation

/// A command from Settings → Commands, run in a new terminal pane. Its
/// shortcut lives in the keymap as `command.<id>`.
public struct CustomCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var command: String

    public init(id: String = UUID().uuidString.lowercased(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    public var shortcutId: String { "command.\(id)" }

    public func validate() throws {
        guard Self.isValidId(id) else {
            throw SettingsError("commands", "command IDs must contain 1–64 letters, digits, hyphens, or underscores")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.utf8.count > 256 || name.hasControlCharacter {
            throw SettingsError("commands", "enter a name of 1–256 bytes without control characters")
        }
        if command.trimmingCharacters(in: .whitespaces).isEmpty || command.utf8.count >= 64 * 1024
            || command.hasControlCharacter
        {
            throw SettingsError(
                "commands",
                "enter a single-line command without control characters, shorter than 64 KiB"
            )
        }
    }

    static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }
}

extension String {
    var hasControlCharacter: Bool {
        unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

extension Settings {
    func validateCommands() throws {
        guard commands.count <= 256 else { throw SettingsError("commands", "at most 256 commands are supported") }
        var ids = Set<String>()
        for command in commands {
            try command.validate()
            guard ids.insert(command.id).inserted else {
                throw SettingsError("commands", "command IDs must be unique")
            }
        }
    }

    /// Refuses a command shortcut that a terminal key binding would hide.
    public func validateCommandShortcuts(terminal: TerminalSettings) throws {
        for command in commands {
            let id = command.shortcutId
            if let chord = keymap.binding(id), terminal.keybindings.bindings[chord] != nil {
                throw SettingsError(
                    "keymap.\(id)",
                    "\(chord) for command '\(command.name)' is also bound in terminal settings; choose a different shortcut"
                )
            }
        }
    }

    /// Writes the commands and the keymap together, since command shortcuts
    /// live in the keymap.
    public func saveCommands(to url: URL) throws {
        try validateCommands()
        var document = try SettingsDocument.read(url)
        try document.replace("commands", commands)
        try document.replace("keymap", keymap.overrides)
        try document.write(to: url)
    }
}
