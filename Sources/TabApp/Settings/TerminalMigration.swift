import Foundation
import TabCore

/// Moving to Tab from another terminal: an agent reads that terminal's
/// configuration and writes Tab's, guided by a prompt that lists what Tab can
/// set and how its files are written.
public enum TerminalMigration {
    public struct Source: Equatable, Sendable {
        public let id: String
        public let name: String
        /// Configuration files, relative to the home folder.
        public let files: [String]
        /// Words for what the agent should bring over besides keys and colors.
        public var notes: String = ""
    }

    public static let sources: [Source] = [
        Source(id: "ghostty", name: "Ghostty", files: [
            ".config/ghostty/config",
            "Library/Application Support/com.mitchellh.ghostty/config",
        ], notes: "Ghostty themes are already in Tab's theme format; copy a custom theme file as it is."),
        Source(id: "iterm2", name: "iTerm2", files: ["Library/Preferences/com.googlecode.iterm2.plist"],
               notes: "Read the property list with `plutil -convert json -o - FILE` or `defaults read com.googlecode.iterm2`; use the default profile."),
        Source(id: "kitty", name: "kitty", files: [".config/kitty/kitty.conf"]),
        Source(id: "wezterm", name: "WezTerm", files: [".wezterm.lua", ".config/wezterm/wezterm.lua"]),
        Source(id: "alacritty", name: "Alacritty", files: [
            ".config/alacritty/alacritty.toml", ".config/alacritty/alacritty.yml", ".alacritty.toml",
        ]),
        Source(id: "warp", name: "Warp", files: [".warp/keybindings.yaml", ".warp/themes"]),
        Source(id: "tmux", name: "tmux", files: [".tmux.conf", ".config/tmux/tmux.conf"],
               notes: "Tab has no prefix key: map a tmux binding only when a single chord makes sense, such as splits and pane focus, and list the rest as having no equivalent."),
        Source(id: "terminal", name: "Terminal", files: ["Library/Preferences/com.apple.Terminal.plist"],
               notes: "Read the property list with `defaults read com.apple.Terminal`; use the default profile."),
    ]

    /// The sources with a configuration file in `home`.
    public static func available(home: URL) -> [Source] {
        sources.filter { source in
            source.files.contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
        }
    }

    /// What the agent is asked to do.
    static func prompt(for source: Source, home: URL, dirs: TabDirs) -> String {
        let files = source.files.map { home.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        let actions = ShortcutCatalog.keymapActions.compactMap { ShortcutCatalog.find($0.rawValue) }.map { shortcut in
            "- `\(shortcut.name)`: \(shortcut.label)" + (shortcut.defaultChord.map { " (default `\($0.rawValue)`)" } ?? "")
        }
        func choices<T: RawRepresentable & CaseIterable>(_ type: T.Type) -> String where T.RawValue == String {
            T.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")
        }
        return """
        Migrate my \(source.name) setup to Tab, the terminal app this conversation runs in. Read my \
        \(source.name) configuration (\(files.map { "`\($0)`" }.joined(separator: ", "))) and bring over \
        what Tab supports: key bindings, font, cursor, and colors. Don't change \(source.name)'s files.
        \(source.notes.isEmpty ? "" : "\n\(source.notes)\n")
        ## Tab's files

        - `\(dirs.settings.path)`: app settings, JSON. Its `keymap` object maps an action ID below to a \
        key chord, such as `"keymap": {"new_tab": "cmd-t"}`; `""` unbinds an action. Its `appearance` \
        object picks colors with `darkTheme` and `lightTheme`, each a theme name. Keep every other key \
        in the file as it is.
        - `\(dirs.terminalSettings.path)`: terminal settings, JSON, including `fontFamily`, \
        `fontSize`, `lineHeight` (percent added to the font's), `ligatures`, `cursorStyle` \
        (\(choices(CursorStyle.self))), `cursorBlink` (\(choices(CursorBlink.self))), `optionKey` \
        (\(choices(OptionKey.self))) and `copyOnSelect`. Keep the other keys as they are.
        - `\(dirs.themes.path)`: custom color themes, one file per theme, named as the theme, in \
        Ghostty's theme format: `background = #rrggbb`, `foreground`, `cursor-color`, \
        `selection-background`, `selection-foreground`, and `palette = N=#rrggbb` for colors 0 to 15.

        A key chord names its modifiers in the order `cmd`, `ctrl`, `alt`, `shift`, `fn`, each followed \
        by `-`, then the key in lowercase: `cmd-shift-p`, `ctrl-alt-left`, `cmd-enter`, `cmd-plus`. Two \
        actions can't share a chord.

        ## Actions Tab can bind

        \(actions.joined(separator: "\n"))

        ## When you're done

        Check that both JSON files still parse. Then report what you changed, which \(source.name) \
        settings have no equivalent in Tab, and tell me to quit and reopen Tab so it reads the new settings.
        """
    }
}
