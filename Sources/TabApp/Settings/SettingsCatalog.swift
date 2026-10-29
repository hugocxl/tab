import AppKit
import TabCore

/// A page of the Settings window, in sidebar order.
public enum SettingsCategory: String, CaseIterable, Sendable {
    case general, appearance, terminal, keyboard, commands, browser, server, mobile, ai, backup

    public var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .keyboard: return "Keyboard"
        case .commands: return "Commands"
        case .browser: return "Browser"
        case .server: return "Server"
        case .mobile: return "Mobile"
        case .ai: return "AI"
        case .backup: return "Backup & Restore"
        }
    }

    /// The glyph and fill of the category's tile.
    var tile: (icon: AppIcon, fill: UInt32, glyph: UInt32) {
        switch self {
        case .general: return (.settings, 0x77777C, 0xFFFFFF)
        case .appearance: return (.palette, 0x3478F6, 0xFFFFFF)
        case .terminal: return (.terminal, 0x203B26, 0x79F58B)
        case .keyboard: return (.keyboard, 0x77777C, 0xFFFFFF)
        case .commands: return (.code, 0xE98224, 0xFFFFFF)
        case .browser: return (.globe, 0x268DEC, 0xFFFFFF)
        case .server: return (.network, 0x299FA3, 0xFFFFFF)
        case .mobile: return (.appWindow, 0x38A455, 0xFFFFFF)
        case .ai: return (.sparkles, 0xA34DE0, 0xFFFFFF)
        case .backup: return (.history, 0x77777C, 0xFFFFFF)
        }
    }

    /// Categories that start a new group in the sidebar, with a gap above.
    var startsGroup: Bool { [.terminal, .browser, .backup].contains(self) }

    /// The sections the sidebar lists under the category when expanded.
    public var sections: [String] {
        switch self {
        case .general: return ["Closing terminals", "Files", "Window size", "Worktrees", "Voice"]
        case .appearance: return ["Themes", "Interface", "Agents Panel"]
        case .terminal:
            return ["Font", "Background", "Colors", "Cursor", "Selection", "Scrolling", "Input", "Key bindings", "Migration", "Reset"]
        case .keyboard: return ["Shortcuts"]
        case .commands: return []
        case .browser: return ["General", "Browsing", "Profiles"]
        case .server: return ["Connection", "Sessions", "Server control"]
        case .mobile: return ["Access", "Pairing", "Devices"]
        case .ai: return ["Commit", "Create Pull Request"]
        case .backup: return ["Backup & Restore", "Configuration"]
        }
    }

    /// The file behind the page, for "Edit in …". Mobile access is managed
    /// only here.
    public var configurationFile: String? {
        switch self {
        case .server: return "server.json"
        case .terminal: return "terminal.json"
        case .mobile: return nil
        default: return "settings.json"
        }
    }
}

/// One setting as Settings lists and searches it.
public struct SettingItem: Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String
    public let category: SettingsCategory
    public let section: String

    public init(_ id: String, _ label: String, _ description: String, _ category: SettingsCategory, _ section: String) {
        self.id = id
        self.label = label
        self.description = description
        self.category = category
        self.section = section
    }

    /// Whether every word of `query` (lowercased) appears in the item's
    /// category, section, id, label or description.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = [category.title, section, id, label, description].joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}

/// Every setting the Settings window shows, in page order. Keyboard
/// shortcuts and custom commands are added from the shortcut catalog and
/// the user's commands.
public enum SettingsCatalog {
    public static let items: [SettingItem] = [
        // General
        SettingItem("close-behavior", "When closing tabs or panes", "Close sessions unused by other panes, or detach to keep them running and reopen them from Existing Terminals.", .general, "Closing terminals"),
        SettingItem("confirm-process", "Confirm before closing a running process", "Ask before ending a running command. Detaching never requires confirmation.", .general, "Closing terminals"),
        SettingItem("file-opener", "Open files with", "Opens files you click in a terminal. Files open in the Tab editor or another application.", .general, "Files"),
        SettingItem("width", "Default window width", "Width in points for a new workspace window when no saved bounds exist.", .general, "Window size"),
        SettingItem("height", "Default window height", "Height in points for a new workspace window when no saved bounds exist.", .general, "Window size"),
        SettingItem("worktree-template", "Default worktree path template", "For example ../{base-dir}.{branch}. Must include {branch}; also supports {project-name}. Relative paths start in the project folder. Overrides the default folder.", .general, "Worktrees"),
        SettingItem("worktree-folder", "Default worktree folder", "Worktrees go in <folder>/<project>/<name>. Leave both location settings empty to use ~/.tab/worktrees.", .general, "Worktrees"),
        SettingItem("voice-auto-send", "Send after recording", "Press Return after inserting standalone voice dictation into the terminal.", .general, "Voice"),
        SettingItem("voice-language", "Dictation language", "Choose an installed on-device speech language.", .general, "Voice"),
        SettingItem("voice-model", "Offline voice model", "Path to a local multilingual Whisper model. Used by Linux dictation. macOS uses the system recognizer.", .general, "Voice"),
        // Appearance
        SettingItem("light-theme", "Light theme", "Colors for the interface and terminals when macOS uses light appearance.", .appearance, "Themes"),
        SettingItem("dark-theme", "Dark theme", "Colors for the interface and terminals when macOS uses dark appearance.", .appearance, "Themes"),
        SettingItem("sidebar", "Expand sidebar", "Show project names alongside their icons in the workspace sidebar.", .appearance, "Interface"),
        SettingItem("sidebar-width", "Sidebar width", "Width of the expanded sidebar in points.", .appearance, "Interface"),
        SettingItem("auto-expand-worktrees", "Expand worktrees when switching projects", "Reveal worktrees when selecting a project.", .appearance, "Interface"),
        SettingItem("worktree-unread", "Show unread worktree indicators", "Show unread completion counts beside worktrees.", .appearance, "Interface"),
        SettingItem("worktree-recent-order", "Order the worktree switcher by recent use", "List the current worktree first, then the most recently used. Off, the project comes first, then its worktrees.", .appearance, "Interface"),
        SettingItem("agents-panel", "Show agents panel", "Show the agents panel, or its button when the sidebar is collapsed.", .appearance, "Agents Panel"),
        SettingItem("agents-panel-grouping", "Agents panel rows", "List each agent and open its pane, or each project and worktree running agents and open it.", .appearance, "Agents Panel"),
        // Terminal
        SettingItem("font-family", "Font family", "The typeface used to render text in every terminal pane.", .terminal, "Font"),
        SettingItem("font-fallbacks", "Fallback fonts", "Fonts used, in order, for characters the main font lacks.", .terminal, "Font"),
        SettingItem("font-size", "Font size (points)", "Default terminal text size. Individual panes can still be zoomed independently.", .terminal, "Font"),
        SettingItem("adjust-cell-height", "Line spacing", "Add space between terminal lines using pixels or a percentage, such as 10%.", .terminal, "Font"),
        SettingItem("adjust-cell-width", "Character spacing", "Adjust character spacing by pixels or a percentage, such as 10%.", .terminal, "Font"),
        SettingItem("font-family-bold", "Bold font", "Font for bold text. Default uses the main font's bold style.", .terminal, "Font"),
        SettingItem("font-family-italic", "Italic font", "Font for italic text. Default uses the main font's italic style.", .terminal, "Font"),
        SettingItem("font-family-bold-italic", "Bold italic font", "Font for bold italic text. Default uses the main font's bold italic style.", .terminal, "Font"),
        SettingItem("font-feature", "Font features", "OpenType features separated by commas, such as ss01 or zero. Put a minus before one to turn it off, such as -calt.", .terminal, "Font"),
        SettingItem("font-ligatures", "Font ligatures", "Combine programming symbols when the selected font supports ligatures.", .terminal, "Font"),
        SettingItem("font-codepoint-map", "Codepoint fonts", "Use a specific font for a Unicode range, such as U+E000-U+F8FF for icons.", .terminal, "Font"),
        SettingItem("font-thicken", "Thicken font", "Draw terminal text with a heavier stroke.", .terminal, "Font"),
        SettingItem("font-thicken-strength", "Thicken strength", "How much heavier text is drawn when Thicken font is on.", .terminal, "Font"),
        SettingItem("bold-is-bright", "Bright colors for bold text", "Use bright ANSI colors for bold text in the first eight palette colors.", .terminal, "Font"),
        SettingItem("background-transparency", "Terminal transparency", "Let the desktop show through the terminal background. Off while Reduce Transparency or Increase Contrast is on.", .terminal, "Background"),
        SettingItem("background-vibrancy", "Background vibrancy", "Reveal the native macOS material by reducing the solid background tint.", .terminal, "Background"),
        SettingItem("background-opacity-cells", "Apply opacity to colored cells", "Also make backgrounds drawn by terminal programs translucent.", .terminal, "Background"),
        SettingItem("window-padding-x", "Horizontal padding (points)", "Adjust the space to the left and right of terminal text.", .terminal, "Background"),
        SettingItem("window-padding-y", "Vertical padding (points)", "Adjust the space above and below terminal text.", .terminal, "Background"),
        SettingItem("window-padding-balance", "Balance padding", "Distribute unused cell space equally around the terminal grid.", .terminal, "Background"),
        SettingItem("window-padding-color", "Padding color", "Fill padding with the background color, or extend the color of the nearest cells.", .terminal, "Background"),
        SettingItem("background", "Background color", "Replaces the theme's terminal background, such as #1e1e2e. Leave empty to use the theme.", .terminal, "Colors"),
        SettingItem("foreground", "Text color", "Replaces the theme's terminal text color. Leave empty to use the theme.", .terminal, "Colors"),
        SettingItem("cursor-color", "Cursor color", "A color, cell-foreground, or cell-background. Leave empty to use the theme.", .terminal, "Colors"),
        SettingItem("cursor-text", "Cursor text color", "Color of the character under a block cursor. Leave empty to use the theme.", .terminal, "Colors"),
        SettingItem("selection-foreground", "Selection text color", "A color, cell-foreground, or cell-background. Leave empty to use the theme.", .terminal, "Colors"),
        SettingItem("selection-background", "Selection color", "A color, cell-foreground, or cell-background. Leave empty to use the theme.", .terminal, "Colors"),
        SettingItem("palette", "ANSI colors", "Replaces the 16 ANSI colors. Leave a color empty to use the theme.", .terminal, "Colors"),
        SettingItem("cursor-style", "Cursor shape", "Choose the initial cursor shape. Terminal programs can change it.", .terminal, "Cursor"),
        SettingItem("cursor-style-blink", "Cursor blinking", "Choose the initial blink behavior. Terminal programs can change it.", .terminal, "Cursor"),
        SettingItem("adjust-cursor-thickness", "Cursor thickness", "Thicken bar, underline, and outlined cursors. Use 1 for one extra physical pixel, or 100% to double thickness.", .terminal, "Cursor"),
        SettingItem("cursor-opacity", "Cursor opacity", "How opaque the cursor is.", .terminal, "Cursor"),
        SettingItem("copy-on-select", "Copy on select", "Copy selected terminal text to the clipboard as soon as you finish selecting.", .terminal, "Selection"),
        SettingItem("selection-clear-on-typing", "Clear selection when typing", "Remove the selected range when sending text to the terminal.", .terminal, "Selection"),
        SettingItem("selection-clear-on-copy", "Clear selection after copying", "Remove the selected range after copying its text.", .terminal, "Selection"),
        SettingItem("scroll-precision", "Trackpad scroll speed", "Adjust smooth scrolling speed.", .terminal, "Scrolling"),
        SettingItem("scroll-discrete", "Mouse wheel scroll speed", "Adjust mouse wheel scrolling speed.", .terminal, "Scrolling"),
        SettingItem("scroll-on-keystroke", "Scroll to bottom when typing", "Return to live output when sending a keystroke.", .terminal, "Scrolling"),
        SettingItem("scroll-on-output", "Scroll to bottom on output", "Return to live output whenever the terminal receives new text.", .terminal, "Scrolling"),
        SettingItem("mouse-reporting", "Allow programs to use the mouse", "Send mouse events to terminal programs that request them. Hold Shift to select text instead.", .terminal, "Input"),
        SettingItem("macos-option-as-alt", "Option as Alt", "Use both Option keys, neither, or just one as the terminal Alt modifier.", .terminal, "Input"),
        SettingItem("directory", "New pane directory", "Start new splits in the project folder or the current pane's working directory.", .terminal, "Input"),
        SettingItem("terminal-keybindings", "Key bindings", "Keys the terminal handles while it is focused. They take precedence over app shortcuts.", .terminal, "Key bindings"),
        SettingItem("keybind-clear-defaults", "Disable built-in bindings", "Turn off Tab's built-in terminal keys, such as Command-K to clear the screen, and keep only yours.", .terminal, "Key bindings"),
        SettingItem("terminal-import-notes", "Imported settings", "Notes about terminal settings that could not be applied.", .terminal, "Migration"),
        SettingItem("terminal-reset", "Reset terminal settings", "Return every setting on this page, including key bindings, to its default.", .terminal, "Reset"),
        // Commands
        SettingItem("add-command", "Custom commands", "Run a saved shell command in a new tab in the selected project. Assign a direct shortcut or find it in the command palette.", .commands, "Commands"),
        // Browser
        SettingItem("browser-enabled", "Enable built-in browser", "Open web pages in browser tabs and let tab browser commands drive them.", .browser, "General"),
        SettingItem("browser-terminal-links", "Open terminal links in the browser", "Command-click a web link in a terminal to open it in a browser tab instead of your system browser.", .browser, "General"),
        SettingItem("browser-search-engine", "Search engine", "Searches typed in the address bar use this engine.", .browser, "Browsing"),
        SettingItem("browser-home-page", "Home page", "The page new browser tabs open to. Leave it empty for the start page.", .browser, "Browsing"),
        SettingItem("browser-profiles", "Profiles", "Profiles keep cookies and logins apart. New browser panes use the default profile.", .browser, "Profiles"),
        SettingItem("browser-import", "Import from another browser", "Bring history, bookmarks, or sign-ins from Safari, Chrome or Firefox on this Mac.", .browser, "Profiles"),
        // Server
        SettingItem("server", "Current device", "Manage the local server that keeps your terminal sessions running.", .server, "Connection"),
        SettingItem("default-shell", "Default shell (executable path)", "Shell for new sessions. Leave empty to use $SHELL, falling back to /bin/zsh.", .server, "Sessions"),
        SettingItem("history-budget", "History budget per session (MiB)", "Retained terminal history, from 0 to 65536 MiB. Saved-history changes take effect at the next server start.", .server, "Sessions"),
        SettingItem("shell-integration", "Shell integration", "Enable working-directory tracking and prompt navigation in new sessions.", .server, "Sessions"),
        SettingItem("stop-server", "Stop Server", "End all sessions on this device and stop the server. A confirmation is required.", .server, "Server control"),
        SettingItem("restart-server", "Restart Server", "End all sessions and start the server again. Saved terminal records are preserved.", .server, "Server control"),
        // Mobile
        SettingItem("mobile-access", "Allow mobile devices", "Let paired phones reach this device's server over the local network or a VPN. A paired phone gets full terminal access.", .mobile, "Access"),
        SettingItem("mobile-port", "Port", "Network port phones connect to, from 1024 to 65535.", .mobile, "Access"),
        SettingItem("mobile-status", "Status", "Whether phones can reach this device right now.", .mobile, "Access"),
        SettingItem("mobile-pair", "Pair a phone", "Show a one-time code to scan with the Tab app.", .mobile, "Pairing"),
        SettingItem("mobile-devices", "Paired devices", "Phones that can connect. Revoking one disconnects it immediately.", .mobile, "Devices"),
        // AI
        SettingItem("ai-commit-provider", "Commit provider", "AI CLI that drafts commit messages. Auto uses the first installed provider.", .ai, "Commit"),
        SettingItem("ai-commit-prompt", "Commit prompt", "AI drafts only the commit message. Tab commits, and pushes when you choose to. An empty prompt uses the default. Do not include secrets.", .ai, "Commit"),
        SettingItem("ai-commit-include-unstaged", "Include unstaged changes", "Stage every change before an AI commit, not only what is already staged.", .ai, "Commit"),
        SettingItem("ai-commit-push", "Push after committing", "Push the branch once an AI commit is made.", .ai, "Commit"),
        SettingItem("ai-create-pr-provider", "Pull request provider", "AI CLI that drafts pull requests. Auto uses the first installed provider.", .ai, "Create Pull Request"),
        SettingItem("ai-create-pr-prompt", "Pull request prompt", "AI drafts the title, summary, branch name, and target branch. You review them before Tab commits, pushes, and opens the pull request. An empty prompt uses the default.", .ai, "Create Pull Request"),
        SettingItem("ai-project-pr-prompt", "Project pull request prompt", "Instructions for one project's pull requests, used instead of the pull request prompt above. Its worktrees use it too. Empty uses the general prompt.", .ai, "Create Pull Request"),
        // Backup
        SettingItem("backup-export", "Export backup", "Save settings, themes, projects, workspaces, and terminal layouts to a .tab file.", .backup, "Backup & Restore"),
        SettingItem("backup-restore", "Restore backup", "Choose a .tab backup. It is restored the next time Tab opens, with a recovery copy in the Backups folder.", .backup, "Backup & Restore"),
        SettingItem("backup-files", "Configuration files", "Open configuration files in your editor. Terminal settings reload when Tab becomes active.", .backup, "Configuration"),
        SettingItem("backup-folder", "Backups folder", "Recovery copies made before a backup is restored.", .backup, "Configuration"),
    ]

    private static let byId: [String: SettingItem] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    public static func item(_ id: String) -> SettingItem? { byId[id] }

    /// Every shortcut as Keyboard lists them: one card, ordered by the
    /// keyboard shortcuts guide's groups, each searchable by its group.
    public static func shortcutItems() -> [SettingItem] {
        ShortcutGroup.allCases.flatMap { group in
            ShortcutCatalog.all.filter { $0.group == group }.map { shortcut in
                SettingItem("shortcut.\(shortcut.name)", shortcut.label, group.title, .keyboard, "Shortcuts")
            }
        }
    }

    /// A custom command's row.
    public static func commandItem(_ command: CustomCommand) -> SettingItem {
        SettingItem(command.shortcutId, command.name, command.command, .commands, "Commands")
    }

    /// Every row the window can show for `commands`.
    public static func searchIndex(commands: [CustomCommand]) -> [SettingItem] {
        items + shortcutItems() + commands.map(commandItem)
    }

    /// The rows matching `query`, in page order.
    public static func search(_ query: String, commands: [CustomCommand]) -> [SettingItem] {
        searchIndex(commands: commands).filter { $0.matches(query) }
    }
}

/// AI actions whose provider and prompt Settings edits.
public enum AIAction: String, CaseIterable, Sendable {
    case commit
    case createPullRequest = "create_pr"

    public var defaultPrompt: String {
        switch self {
        case .commit:
            return "Write a concise commit message that explains the intent of all staged changes. Follow the repository's existing commit-message style."
        case .createPullRequest:
            return "Write an accurate pull request title and a concise summary of the changes. Choose a short descriptive branch name and the appropriate target branch."
        }
    }

    var providerSetting: String { self == .commit ? "ai-commit-provider" : "ai-create-pr-provider" }
    var promptSetting: String { self == .commit ? "ai-commit-prompt" : "ai-create-pr-prompt" }

    /// AI command-line tools, as `(id, name)`.
    public static let providers: [(id: String, name: String)] = [
        ("claude", "Claude Code"), ("codex", "Codex"), ("opencode", "OpenCode"), ("copilot", "GitHub Copilot"),
        ("cursor", "Cursor"), ("droid", "Droid"), ("grok", "Grok"), ("kiro", "Kiro CLI"), ("pi", "Pi"),
        ("xal", "Xal"), ("antigravity", "Antigravity"), ("omp", "Oh My Pi"),
    ]
}
