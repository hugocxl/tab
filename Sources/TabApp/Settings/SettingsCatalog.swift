import AppKit
import TabCore

/// A page of the Settings window, in sidebar order.
public enum SettingsCategory: String, CaseIterable, Sendable {
    case general, interface, appearance, terminal, keyboard, integrations, privacy, browser, server, remoteServers, mobile, backup, changelog

    public var title: String {
        switch self {
        case .general: return "General"
        case .interface: return "Interface"
        case .appearance: return "Themes"
        case .terminal: return "Terminal"
        case .keyboard: return "Shortcuts"
        case .integrations: return "Integrations"
        case .privacy: return "Privacy"
        case .browser: return "Browser"
        case .remoteServers: return "Remote Servers"
        case .server: return "Server"
        case .mobile: return "Mobile"
        case .backup: return "Backup & Restore"
        case .changelog: return "Changelog"
        }
    }

    /// The SF Symbol and colors of the category's icon tile: a gradient from
    /// `top` to `bottom` under a `glyph`-colored symbol.
    var icon: (symbol: String, top: UInt32, bottom: UInt32, glyph: UInt32) {
        switch self {
        case .general: return ("gearshape.fill", 0xA2A2A7, 0x76767B, 0xFFFFFF)
        case .interface: return ("macwindow", 0x5BB2FF, 0x1F6FEB, 0xFFFFFF)
        case .appearance: return ("paintpalette.fill", 0x3FA2FF, 0xC04BF2, 0xFFFFFF)
        case .terminal: return ("apple.terminal", 0x3A3A3C, 0x151515, 0x5BE37A)
        case .keyboard: return ("command", 0xF7F7F8, 0xDCDCDF, 0x6E6E73)
        case .integrations: return ("puzzlepiece.extension.fill", 0xFF6FB5, 0x8E4BF2, 0xFFFFFF)
        case .privacy: return ("hand.raised.fill", 0x5BB2FF, 0x1F6FEB, 0xFFFFFF)
        case .browser: return ("globe", 0x5BB2FF, 0x1F6FEB, 0xFFFFFF)
        case .remoteServers: return ("network", 0x4FD1D5, 0x1E9AA0, 0xFFFFFF)
        case .server: return ("server.rack", 0x4FD1D5, 0x1E9AA0, 0xFFFFFF)
        case .mobile: return ("iphone", 0x6BDB7E, 0x2FA84A, 0xFFFFFF)
        case .backup: return ("clock.arrow.circlepath", 0x9B9BA0, 0x5F5F64, 0xFFFFFF)
        case .changelog: return ("list.bullet.rectangle.portrait.fill", 0xFFC94A, 0xF29D1B, 0xFFFFFF)
        }
    }

    /// Categories that start a new group in the sidebar, with a gap above.
    var startsGroup: Bool { [.terminal, .browser, .backup].contains(self) }
}

/// A page opened from a row of a category's page, such as Terminal's
/// Advanced Font Settings.
public enum SettingsSubpage: String, CaseIterable, Sendable {
    case advancedFont

    public var title: String {
        switch self {
        case .advancedFont: return "Advanced Font Settings"
        }
    }

    public var category: SettingsCategory {
        switch self {
        case .advancedFont: return .terminal
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
    /// The subpage the row is on, `nil` for the category's own page.
    public let subpage: SettingsSubpage?

    public init(_ id: String, _ label: String, _ description: String, _ category: SettingsCategory, _ section: String,
                subpage: SettingsSubpage? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.category = category
        self.section = section
        self.subpage = subpage
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
        SettingItem("remote-servers", "Remote Servers", "Manage SSH connections, passwords and server groups.", .remoteServers, "Remote Servers"),
        // General
        SettingItem("close-behavior", "When closing tabs or panes", "Close sessions unused by other panes, or detach to keep them running and reopen them from Detached Terminals.", .general, "Closing terminals"),
        SettingItem("confirm-process", "Confirm before closing a running process", "Ask before ending a running command. Detaching never requires confirmation.", .general, "Closing terminals"),
        SettingItem("file-opener", "Open files with", "Opens files you click in a terminal. Files open in the Tab editor or another application.", .general, "Files"),
        SettingItem("worktree-template", "Default worktree path template", "For example ../{base-dir}.{branch}. Must include {branch}; also supports {project-name}. Relative paths start in the project folder. Overrides the default folder.", .general, "Worktrees"),
        SettingItem("worktree-folder", "Default worktree folder", "Worktrees go in <folder>/<project>/<name>. Leave both location settings empty to use ~/.tab/worktrees.", .general, "Worktrees"),
        // Appearance
        SettingItem("light-theme", "Light theme", "Colors for the interface and terminals when macOS uses light appearance.", .appearance, "Themes"),
        SettingItem("dark-theme", "Dark theme", "Colors for the interface and terminals when macOS uses dark appearance.", .appearance, "Themes"),
        SettingItem("sidebar", "Expand sidebar", "Show project names alongside their icons in the workspace sidebar.", .interface, "Window"),
        SettingItem("sidebar-layout", "Sidebar layout", "Group tabs under their projects, or list only the open tabs, each showing its project.", .interface, "Window"),
        SettingItem("color-scheme", "Color scheme", "Choose an appearance or follow macOS.", .interface, "Appearance"),
        SettingItem("interface-style", "Interface style", "Native macOS glass, always tinted with your theme.", .interface, "Appearance"),
        SettingItem("glass-panes", "Use glass for panes", "Web pages and device screens keep their own backgrounds.", .interface, "Appearance"),
        SettingItem("preserve-pane-width", "Preserve pane width when resizing sidebar", "", .interface, "Window"),
        SettingItem("sidebar-gesture", "Use a gesture to toggle the sidebar", "Option-scroll always scrolls content sideways.", .interface, "Window"),
        SettingItem("animation-style", "Animation style", "Pane transitions and sidebars follow this style. Reduce Motion turns animations off.", .interface, "Animation"),
        // Terminal
        SettingItem("typography-preview", "", "", .terminal, "Typography"),
        SettingItem("font-family", "Terminal font", "", .terminal, "Typography"),
        SettingItem("font-size", "Font size", "", .terminal, "Typography"),
        SettingItem("font-style", "Style", "", .terminal, "Typography"),
        SettingItem("font-advanced", "Advanced", "", .terminal, "Typography"),
        SettingItem("advanced-preview", "", "", .terminal, "Advanced Font Settings", subpage: .advancedFont),
        SettingItem("character-spacing", "Character spacing", "", .terminal, "Advanced Font Settings", subpage: .advancedFont),
        SettingItem("line-height", "Line height", "", .terminal, "Advanced Font Settings", subpage: .advancedFont),
        SettingItem("ligatures", "Ligatures", "", .terminal, "Advanced Font Settings", subpage: .advancedFont),
        SettingItem("font-smoothing", "Font smoothing", "", .terminal, "Advanced Font Settings", subpage: .advancedFont),
        SettingItem("fallback-fonts", "Fallback fonts", "Used in order for characters the terminal font doesn't have.", .terminal, "Advanced Font Settings", subpage: .advancedFont),
        SettingItem("improve-contrast", "Improve text contrast", "Adjust unreadable text against its background.", .terminal, "Colors"),
        SettingItem("force-theme-palette", "Force theme palette for text", "Map text colors to the nearest theme color.", .terminal, "Colors"),
        SettingItem("display-p3", "Use Display P3 color space", "Read theme and program colors as wide-gamut Display P3.", .terminal, "Colors"),
        SettingItem("cursor-preview", "", "", .terminal, "Cursor"),
        SettingItem("cursor-style", "Cursor style", "", .terminal, "Cursor"),
        SettingItem("cursor-blink", "Blink speed", "", .terminal, "Cursor"),
        SettingItem("force-cursor-style", "Force style", "Ignore application requests to change cursor shape.", .terminal, "Cursor"),
        SettingItem("option-key", "Option key", "", .terminal, "Keyboard"),
        SettingItem("smooth-scrolling", "Smooth scrolling", "", .terminal, "Scrolling"),
        SettingItem("selection-preview", "", "", .terminal, "Selection"),
        SettingItem("copy-on-select", "Copy on selection", "", .terminal, "Selection"),
        SettingItem("copy-animation", "Play animation on copy", "", .terminal, "Selection"),
        SettingItem("selection-foreground", "Foreground", "", .terminal, "Selection"),
        SettingItem("selection-background", "Background", "", .terminal, "Selection"),
        SettingItem("rounded-selection", "Rounded corners", "", .terminal, "Selection"),
        SettingItem("app-links", "Links that open apps", "", .terminal, "Links"),
        SettingItem("generated-titles", "Prefer generated titles", "", .terminal, "Titles"),
        SettingItem("startup-command", "Startup command", "", .terminal, "Shell"),
        // Integrations
        SettingItem("agent-integration", "Integrate with available agents", "Installs a Tab skill and session hooks for supported agents.", .integrations, "Coding Agents"),
        SettingItem("agent-integration-agents", "Agents", "", .integrations, "Coding Agents"),
        SettingItem("terminal-migration", "Migrate from another terminal", "An agent reads that terminal's configuration and brings its shortcuts, font, cursor and colors into Tab.", .integrations, "Migration"),
        // Privacy
        SettingItem("privacy-camera", "Camera", "", .privacy, "Permissions"),
        SettingItem("privacy-microphone", "Microphone", "", .privacy, "Permissions"),
        SettingItem("privacy-contacts", "Contacts", "", .privacy, "Permissions"),
        SettingItem("privacy-calendars", "Calendars", "", .privacy, "Permissions"),
        SettingItem("privacy-reminders", "Reminders", "", .privacy, "Permissions"),
        SettingItem("privacy-photos", "Photos", "", .privacy, "Permissions"),
        SettingItem("privacy-location", "Location Services", "", .privacy, "Permissions"),
        SettingItem("privacy-bluetooth", "Bluetooth", "", .privacy, "Permissions"),
        SettingItem("privacy-automation", "Automation", "Lets programs control other apps, such as with osascript.", .privacy, "Terminal Programs"),
        SettingItem("privacy-files", "Full Disk Access", "Lets programs read protected folders, such as Mail and Safari data.", .privacy, "Terminal Programs"),
        // Browser
        SettingItem("browser-enabled", "Enable built-in browser", "Open web pages in browser tabs and let tab browser commands drive them.", .browser, "General"),
        SettingItem("browser-terminal-links", "Open terminal links in the browser", "Command-click a web link in a terminal to open it in a browser tab instead of your system browser.", .browser, "General"),
        SettingItem("browser-search-engine", "Search engine", "Searches typed in the address bar use this engine.", .browser, "Browsing"),
        SettingItem("browser-home-page", "Home page", "The page new browser tabs open to. Leave it empty for the start page.", .browser, "Browsing"),
        SettingItem("browser-profiles", "Profiles", "Profiles keep cookies and logins apart. New browser panes use the default profile.", .browser, "Profiles"),
        SettingItem("browser-import", "Import from another browser", "Bring history, bookmarks, or sign-ins from Safari, Chrome or Firefox on this Mac.", .browser, "Profiles"),
        // Server
        SettingItem("server", "Local server", "View the version and connection status of the local server that keeps your terminal sessions running.", .server, "Connection"),
        SettingItem("stop-server", "Stop Server", "End all sessions on this device and stop the server. A confirmation is required.", .server, "Server control"),
        SettingItem("restart-server", "Restart Server", "End all sessions and start the server again. Saved terminal records are preserved.", .server, "Server control"),
        // Mobile
        SettingItem("mobile-access", "Allow mobile devices", "Let paired phones reach this device's server over the local network or a VPN. A paired phone gets full terminal access.", .mobile, "Access"),
        SettingItem("mobile-port", "Port", "Network port phones connect to, from 1024 to 65535.", .mobile, "Access"),
        SettingItem("mobile-status", "Status", "Whether phones can reach this device right now.", .mobile, "Access"),
        SettingItem("mobile-pair", "Pair a phone", "Show a one-time code to scan with the Tab app.", .mobile, "Pairing"),
        SettingItem("mobile-devices", "Paired devices", "Phones that can connect. Revoking one disconnects it immediately.", .mobile, "Devices"),
        // Backup
        SettingItem("backup-export", "Export backup", "Save settings, themes, projects, workspaces, and terminal layouts to a .tab file.", .backup, "Backup & Restore"),
        SettingItem("backup-restore", "Restore backup", "Choose a .tab backup. It is restored the next time Tab opens, with a recovery copy in the Backups folder.", .backup, "Backup & Restore"),
        SettingItem("backup-folder", "Backups folder", "Recovery copies made before a backup is restored.", .backup, "Configuration"),
    ]

    private static let byId: [String: SettingItem] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

    public static func item(_ id: String) -> SettingItem? { byId[id] }

    /// Every shortcut, ordered and grouped by its catalog category.
    public static func shortcutItems() -> [SettingItem] {
        ShortcutGroup.allCases.flatMap { group in
            ShortcutCatalog.all.filter { $0.group == group }.map { shortcut in
                SettingItem("shortcut.\(shortcut.name)", shortcut.label, "", .keyboard, group.title)
            }
        }
    }

    /// Every row the window can show.
    public static func searchIndex() -> [SettingItem] {
        items + shortcutItems()
    }

    /// The rows matching `query`, in page order.
    public static func search(_ query: String) -> [SettingItem] {
        searchIndex().filter { $0.matches(query) }
    }
}
