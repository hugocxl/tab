import Foundation

// The shared shortcut catalog: every command's id, default keys, the
// contexts they apply in, its group in Settings → Keyboard and its place in
// the menu bar. Menus, the keymap and Settings all read this one table.

/// Where a shortcut applies. `nil` means everywhere in the app.
public enum ShortcutContext {
    /// The workspace when no text field has the keyboard, where Copy and
    /// Paste go to the terminal.
    public static let workspaceClipboard =
        "WorkspaceTabs && !TextInput && !BareInput && !MultilineInput && !TerminalSearchInput"

    /// The scope a context belongs to when checking conflicts: the workspace
    /// clipboard and the main window share the workspace's keys.
    static func scope(_ context: String?) -> String? {
        guard let context else { return nil }
        if context == workspaceClipboard || context == "MainWindow" { return "WorkspaceTabs" }
        return context
    }

    /// Whether a key in one context can collide with the same key in another.
    public static func overlap(_ left: String?, _ right: String?) -> Bool {
        left == nil || right == nil || scope(left) == scope(right)
    }
}

/// A feature whose backend a shortcut's command needs.
public enum ShortcutFeature: String, CaseIterable, Sendable {
    case voice
    case notifications
    case commandLineTool
    case updates
    case appHiding

    /// Why a build without a backend for the feature cannot offer it.
    public var unsupportedReason: String {
        switch self {
        case .voice: return "Voice input is not available on this Mac."
        case .notifications: return "Notifications are not available on this Mac."
        case .commandLineTool: return "Installing the command line tool is not available in this build."
        case .updates: return "Automatic updates are not available in this build."
        case .appHiding: return "Hiding apps is not available."
        }
    }
}

/// The section of Settings → Keyboard a shortcut is listed under, following
/// the keyboard shortcuts guide.
public enum ShortcutGroup: String, CaseIterable, Sendable {
    case palette
    case panes
    case files
    case projects
    case terminal
    case browser
    case dictation
    case app
    case textEditing
    case lists
    case settingsWindow

    public var title: String {
        switch self {
        case .palette: return "Command Palette"
        case .panes: return "Panes"
        case .files: return "Files and Source Control"
        case .projects: return "Projects and Navigation"
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .dictation: return "Dictation"
        case .app: return "App"
        case .textEditing: return "Text Editing"
        case .lists: return "Lists and Menus"
        case .settingsWindow: return "Settings Window"
        }
    }
}

/// One shortcut: its default keys, and for each key the contexts it applies
/// in. A rebound shortcut applies in all of `contexts`.
public struct ShortcutDefinition: Sendable {
    public let id: ShortcutId
    /// Default keys, primary first, in the persisted `cmd-shift-p` syntax.
    public let keys: [String]
    public let contexts: [String?]
    /// For each of `keys`, the contexts that key applies in.
    public let keyContexts: [[String?]]
    public let group: ShortcutGroup

    init(_ id: ShortcutId, keys: [String], contexts: [String?], keyContexts: [[String?]], group: ShortcutGroup) {
        self.id = id
        self.keys = keys
        self.contexts = contexts
        self.keyContexts = keyContexts
        self.group = group
    }

    /// The id string used in `settings.json` and menus.
    public var name: String { id.rawValue }

    /// The default primary chord, or `nil` for a command with no default key.
    public var defaultChord: KeyChord? { keys.first.map(KeyChord.defaultBinding) }

    /// The name Settings shows.
    public var label: String {
        let label: String
        switch id {
        case .newTab: label = "new terminal"
        case .newTabInProject: label = "new terminal in project"
        default:
            label = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// The feature whose backend the command needs.
    public var feature: ShortcutFeature? {
        switch id {
        case .installCommandLineTool: return .commandLineTool
        case .hideApp, .hideOthers, .showAll: return .appHiding
        case .toggleVoiceRecording, .voiceFinish, .voiceCancel, .voicePause: return .voice
        default: return nil
        }
    }

    /// Whether this shortcut and `other` can be active at the same time.
    public func overlaps(_ other: ShortcutDefinition) -> Bool {
        contexts.contains { context in other.contexts.contains { ShortcutContext.overlap(context, $0) } }
    }

    /// The default keys that apply in `context`.
    public func defaultKeys(in context: String?) -> [String] {
        zip(keys, keyContexts).filter { $0.1.contains(context) }.map(\.0)
    }
}

extension ShortcutId {
    public var definition: ShortcutDefinition { ShortcutCatalog.definition(self) }
    public var label: String { definition.label }

    public static let tabs: [ShortcutId] = [
        .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
        .selectTab6, .selectTab7, .selectTab8, .selectTab9,
    ]

    public static let projects: [ShortcutId] = [
        .selectProject1, .selectProject2, .selectProject3, .selectProject4, .selectProject5,
        .selectProject6, .selectProject7, .selectProject8, .selectProject9,
    ]
}

/// A row of the menu bar.
public enum ShortcutMenuItem: Equatable, Sendable {
    /// A command from the catalog; its key comes from the keymap.
    case shortcut(ShortcutId, title: String)
    /// A command with no shortcut, such as Check for Updates….
    case command(String, title: String)
    /// The system Services submenu.
    case services
    case separator
}

/// One menu of the menu bar.
public struct ShortcutMenu: Equatable, Sendable {
    public let title: String
    public let items: [ShortcutMenuItem]
}

public enum ShortcutCatalog {
    private static let index: [ShortcutId: ShortcutDefinition] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static let byName: [String: ShortcutDefinition] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func definition(_ id: ShortcutId) -> ShortcutDefinition {
        // Every case has a row; the catalog tests check it.
        index[id] ?? ShortcutDefinition(id, keys: [], contexts: [nil], keyContexts: [], group: .app)
    }

    /// The shortcut with the id string `name`, such as `split_right`.
    public static func find(_ name: String) -> ShortcutDefinition? { byName[name] }

    /// The default keys of `name` that apply in `context`.
    public static func defaultKeys(_ name: String, in context: String?) -> [String] {
        find(name)?.defaultKeys(in: context) ?? []
    }

    /// Commands a user can rebind in Settings → Keyboard and the keymap.
    public static let keymapActions: [ShortcutId] = [
        .openSettings, .newHomeTab, .newTabInProject, .newWorktree, .switchWorktree,
        .toggleSidebar, .toggleAgentsPanel, .toggleAgentSessions, .toggleFiles,
        .toggleSourceControl, .goToFile, .findInFiles, .toggleFullScreen, .toggleThemePicker,
        .toggleCommandPalette, .navigateBack, .navigateForward, .quit, .hideApp, .hideOthers,
        .minimize, .newTab, .existingTerminals, .detachTerminal, .closeTab, .splitRight,
        .splitDown, .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
        .toggleZoomPane, .equalizeSplits, .closePane, .nextTab, .previousTab,
        .previousProject, .nextProject, .addProject,
        .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
        .selectTab6, .selectTab7, .selectTab8, .selectTab9,
        .selectProject1, .selectProject2, .selectProject3, .selectProject4, .selectProject5,
        .selectProject6, .selectProject7, .selectProject8, .selectProject9,
        .copy, .paste, .find, .findNext, .findPrevious, .scrollToBottom,
        .previousPrompt, .nextPrompt, .selectCommandOutput,
        .increaseFontSize, .decreaseFontSize, .newBrowserTab,
    ]

    /// Built-in defaults that give way to a key a user binding already has,
    /// so a newer default never takes a key someone bound before it existed.
    public static let yielding: [ShortcutId] = [
        .openSettings, .newHomeTab, .newTabInProject, .newWorktree, .switchWorktree,
        .toggleSidebar, .toggleAgentsPanel, .toggleFiles, .toggleSourceControl, .goToFile,
        .findInFiles, .toggleFullScreen, .toggleThemePicker, .toggleCommandPalette,
        .navigateBack, .navigateForward, .quit, .hideApp, .hideOthers, .minimize,
        .previousPrompt, .nextPrompt, .find, .findNext, .findPrevious,
        .previousProject, .nextProject,
        .selectProject1, .selectProject2, .selectProject3, .selectProject4, .selectProject5,
        .selectProject6, .selectProject7, .selectProject8, .selectProject9,
        .addProject, .closeTab, .splitRight, .splitDown,
        .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
        .toggleZoomPane, .equalizeSplits, .closePane, .menuOpenSubmenu, .menuCloseSubmenu,
        .newBrowserTab, .browserFocusAddress, .browserReload, .browserBack, .browserForward,
        .browserZoomIn, .browserZoomOut, .browserZoomReset, .browserCopyUrl, .browserInspect,
    ]

    /// Pairs of shortcuts whose default keys collide where both apply.
    public static func defaultConflicts() -> [(ShortcutId, ShortcutId, KeyChord)] {
        var conflicts: [(ShortcutId, ShortcutId, KeyChord)] = []
        var seen: [(ShortcutDefinition, KeyChord, [String?])] = []
        for shortcut in all {
            for (key, contexts) in zip(shortcut.keys, shortcut.keyContexts) {
                let chord = KeyChord.defaultBinding(key)
                for (other, otherChord, otherContexts) in seen where otherChord == chord && other.id != shortcut.id {
                    let collides = contexts.contains { context in
                        otherContexts.contains { ShortcutContext.overlap(context, $0) }
                    }
                    if collides { conflicts.append((other.id, shortcut.id, chord)) }
                }
                seen.append((shortcut, chord, contexts))
            }
        }
        return conflicts
    }

    /// A chord as the menu bar shows it, such as `⌘⇧P`.
    public static func displayChord(_ chord: String) -> String {
        var rest = Substring(chord)
        var symbols = [false, false, false, false, false]
        let names = ["ctrl", "alt", "shift", "cmd", "fn"]
        while let dash = rest.firstIndex(of: "-") {
            guard let index = names.firstIndex(of: String(rest[..<dash])) else { break }
            symbols[index] = true
            rest = rest[rest.index(after: dash)...]
        }
        var display = ""
        for (enabled, symbol) in zip(symbols, ["⌃", "⌥", "⇧", "⌘", "fn"]) where enabled {
            display += symbol
        }
        switch rest {
        case "left": return display + "←"
        case "right": return display + "→"
        case "up": return display + "↑"
        case "down": return display + "↓"
        case "enter": return display + "↩"
        case "tab": return display + "⇥"
        case "escape": return display + "⎋"
        case "backspace": return display + "⌫"
        case "delete": return display + "⌦"
        default: return display + rest.uppercased()
        }
    }

    /// The menu bar. `available` leaves out commands whose feature this build
    /// cannot offer.
    public static func menus(
        appName: String,
        available: Set<ShortcutFeature> = Set(ShortcutFeature.allCases)
    ) -> [ShortcutMenu] {
        var app: [ShortcutMenuItem] = [.shortcut(.openSettings, title: "Settings…")]
        if available.contains(.updates) {
            app.append(.command("check_for_updates", title: "Check for Updates…"))
        }
        if available.contains(.commandLineTool) {
            app.append(.shortcut(.installCommandLineTool, title: "Install Command Line Tool…"))
        }
        app += [
            .separator, .services, .separator,
            .shortcut(.hideApp, title: "Hide \(appName)"),
            .shortcut(.hideOthers, title: "Hide Others"),
            .shortcut(.showAll, title: "Show All"),
            .separator,
            .shortcut(.quit, title: "Quit \(appName)"),
            .shortcut(.endAllSessionsAndQuit, title: "End All Sessions and Quit"),
        ]
        let edit: [ShortcutMenuItem] = [
            .shortcut(.textInputCut, title: "Cut"),
            .shortcut(.textInputCopy, title: "Copy"),
            .shortcut(.textInputPaste, title: "Paste"),
            .shortcut(.textInputSelectAll, title: "Select All"),
            .separator,
            .shortcut(.find, title: "Find…"),
            .shortcut(.findNext, title: "Find Next"),
            .shortcut(.findPrevious, title: "Find Previous"),
            .separator,
            .shortcut(.previousPrompt, title: "Previous Prompt"),
            .shortcut(.nextPrompt, title: "Next Prompt"),
            .shortcut(.selectCommandOutput, title: "Select Command Output"),
        ]
        let file: [ShortcutMenuItem] = [
            .shortcut(.newTab, title: "New Terminal"),
            .shortcut(.newBrowserTab, title: "New Browser Pane"),
            .shortcut(.newHomeTab, title: "New Home Terminal"),
            .shortcut(.newTabInProject, title: "New Terminal in Project…"),
            .shortcut(.newWorktree, title: "New Worktree…"),
            .shortcut(.switchWorktree, title: "Switch Worktree…"),
            .shortcut(.addProject, title: "Open Project…"),
            .separator,
            .shortcut(.closeTab, title: "Close Tab"),
        ]
        var view: [ShortcutMenuItem] = [.shortcut(.toggleCommandPalette, title: "Command Palette…"), .separator]
        if available.contains(.voice) {
            view.append(.shortcut(.toggleVoiceRecording, title: "Toggle Voice Recording"))
        }
        view += [
            .separator,
            .shortcut(.toggleSidebar, title: "Toggle Sidebar"),
            .shortcut(.toggleAgentsPanel, title: "Toggle Agents Panel"),
            .shortcut(.toggleAgentSessions, title: "Toggle Agent Sessions"),
            .shortcut(.toggleFiles, title: "Toggle Files"),
            .shortcut(.toggleSourceControl, title: "Toggle Source Control"),
            .shortcut(.goToFile, title: "Go to File…"),
            .shortcut(.findInFiles, title: "Find in Files…"),
            .shortcut(.toggleFullScreen, title: "Toggle Full Screen"),
            .separator,
            .shortcut(.toggleThemePicker, title: "Theme Picker"),
            .separator,
            .shortcut(.increaseFontSize, title: "Increase Font Size"),
            .shortcut(.decreaseFontSize, title: "Decrease Font Size"),
        ]
        var window: [ShortcutMenuItem] = [
            .shortcut(.minimize, title: "Minimize"),
            .shortcut(.zoom, title: "Zoom"),
            .separator,
            .shortcut(.splitRight, title: "Split Right"),
            .shortcut(.splitDown, title: "Split Down"),
            .shortcut(.focusPaneLeft, title: "Focus Pane Left"),
            .shortcut(.focusPaneRight, title: "Focus Pane Right"),
            .shortcut(.focusPaneUp, title: "Focus Pane Up"),
            .shortcut(.focusPaneDown, title: "Focus Pane Down"),
            .shortcut(.toggleZoomPane, title: "Toggle Pane Zoom"),
            .shortcut(.equalizeSplits, title: "Equalize Splits"),
            .shortcut(.closePane, title: "Close Pane"),
            .shortcut(.closeTab, title: "Close Tab"),
            .separator,
            .shortcut(.nextTab, title: "Next Tab"),
            .shortcut(.previousTab, title: "Previous Tab"),
            .separator,
            .shortcut(.previousProject, title: "Previous Project"),
            .shortcut(.nextProject, title: "Next Project"),
            .separator,
        ]
        window += ShortcutId.tabs.enumerated().map { .shortcut($1, title: "Tab \($0 + 1)") }
        window.append(.separator)
        window += ShortcutId.projects.enumerated().map { .shortcut($1, title: "Project \($0 + 1)") }
        return [
            ShortcutMenu(title: appName, items: app),
            ShortcutMenu(title: "Edit", items: edit),
            ShortcutMenu(title: "File", items: file),
            ShortcutMenu(title: "View", items: view),
            ShortcutMenu(title: "Window", items: window),
        ]
    }
}

/// Modifier keys of a chord.
public struct ChordModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ChordModifiers(rawValue: 1 << 0)
    public static let control = ChordModifiers(rawValue: 1 << 1)
    public static let option = ChordModifiers(rawValue: 1 << 2)
    public static let shift = ChordModifiers(rawValue: 1 << 3)
    public static let function = ChordModifiers(rawValue: 1 << 4)

    /// In the canonical order of the persisted syntax.
    static let ordered: [(String, ChordModifiers)] = [
        ("cmd", .command), ("ctrl", .control), ("alt", .option), ("shift", .shift), ("fn", .function),
    ]
}

/// A key with modifiers in the persisted syntax, such as `cmd-shift-p`, kept
/// canonical: modifiers in the order cmd, ctrl, alt, shift, fn, and the key
/// lowercase.
public struct KeyChord: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            switch self {
            case .invalid(let source): return "invalid key chord \"\(source)\""
            }
        }
    }

    private init(raw: String) { rawValue = raw }

    /// Parses `cmd-shift-p`, `Ctrl-Alt-Esc`, `super-k` or `cmd-P` (an
    /// uppercase letter implies Shift).
    public init(_ source: String) throws {
        let invalid = ParseError.invalid(source)
        var rest = Substring(source)
        var modifiers = ChordModifiers()
        while let dash = rest.firstIndex(of: "-") {
            let component = rest[..<dash].lowercased()
            let name = component == "super" ? "cmd" : component
            guard let modifier = ChordModifiers.ordered.first(where: { $0.0 == name })?.1 else { break }
            if modifiers.contains(modifier) { throw invalid }
            modifiers.insert(modifier)
            rest = rest[rest.index(after: dash)...]
        }
        var key = rest.lowercased()
        switch key {
        case "plus": key = "+"
        case "minus": key = "-"
        case "return": key = "enter"
        case "esc": key = "escape"
        default: break
        }
        if rest.count == 1, let first = rest.unicodeScalars.first, first.isASCII,
           first.properties.isUppercase
        {
            modifiers.insert(.shift)
        }
        guard Self.validKey(key) else { throw invalid }
        let prefix = ChordModifiers.ordered.filter { modifiers.contains($0.1) }.map { $0.0 + "-" }.joined()
        rawValue = prefix + key
    }

    /// A built-in default, kept as written if it does not parse.
    static func defaultBinding(_ value: String) -> KeyChord {
        (try? KeyChord(value)) ?? KeyChord(raw: value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            try self.init(text)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid key chord \"\(text)\"")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The modifiers of the chord.
    public var modifiers: ChordModifiers {
        var result = ChordModifiers()
        var rest = Substring(rawValue)
        while let dash = rest.firstIndex(of: "-"),
              let modifier = ChordModifiers.ordered.first(where: { $0.0 == rest[..<dash] })?.1
        {
            result.insert(modifier)
            rest = rest[rest.index(after: dash)...]
        }
        return result
    }

    /// The key without modifiers, such as `p`, `enter` or `-`.
    public var key: String {
        var rest = Substring(rawValue)
        while let dash = rest.firstIndex(of: "-"),
              ChordModifiers.ordered.contains(where: { $0.0 == rest[..<dash] })
        {
            rest = rest[rest.index(after: dash)...]
        }
        return String(rest)
    }

    /// How the menu bar shows it, such as `⌘⇧P`.
    public var display: String { ShortcutCatalog.displayChord(rawValue) }

    public static func < (lhs: KeyChord, rhs: KeyChord) -> Bool { lhs.rawValue < rhs.rawValue }

    private static let namedKeys: Set<String> = [
        "enter", "escape", "space", "tab", "backspace", "delete", "insert", "home", "end",
        "pageup", "pagedown", "up", "down", "left", "right",
    ]

    private static func validKey(_ key: String) -> Bool {
        if key.count == 1, let character = key.first {
            return !character.isWhitespace
                && !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        if namedKeys.contains(key) { return true }
        guard key.hasPrefix("f"), let number = UInt8(key.dropFirst()) else { return false }
        return (1...24).contains(number) && String(number) == key.dropFirst()
    }
}

public enum ShortcutId: String, CaseIterable, Codable, Sendable {
    case newTab = "new_tab"
    case existingTerminals = "existing_terminals"
    case detachTerminal = "detach_terminal"
    case closeTab = "close_tab"
    case splitRight = "split_right"
    case splitDown = "split_down"
    case focusPaneLeft = "focus_pane_left"
    case focusPaneRight = "focus_pane_right"
    case focusPaneUp = "focus_pane_up"
    case focusPaneDown = "focus_pane_down"
    case toggleZoomPane = "toggle_zoom_pane"
    case equalizeSplits = "equalize_splits"
    case closePane = "close_pane"
    case nextTab = "next_tab"
    case previousTab = "previous_tab"
    case previousProject = "previous_project"
    case nextProject = "next_project"
    case addProject = "add_project"
    case selectTab1 = "select_tab1"
    case selectTab2 = "select_tab2"
    case selectTab3 = "select_tab3"
    case selectTab4 = "select_tab4"
    case selectTab5 = "select_tab5"
    case selectTab6 = "select_tab6"
    case selectTab7 = "select_tab7"
    case selectTab8 = "select_tab8"
    case selectTab9 = "select_tab9"
    case selectProject1 = "select_project1"
    case selectProject2 = "select_project2"
    case selectProject3 = "select_project3"
    case selectProject4 = "select_project4"
    case selectProject5 = "select_project5"
    case selectProject6 = "select_project6"
    case selectProject7 = "select_project7"
    case selectProject8 = "select_project8"
    case selectProject9 = "select_project9"
    case copy = "copy"
    case paste = "paste"
    case find = "find"
    case findNext = "find_next"
    case findPrevious = "find_previous"
    case scrollToBottom = "scroll_to_bottom"
    case increaseFontSize = "increase_font_size"
    case decreaseFontSize = "decrease_font_size"
    case newHomeTab = "new_home_tab"
    case newTabInProject = "new_tab_in_project"
    case newWorktree = "new_worktree"
    case switchWorktree = "switch_worktree"
    case toggleSidebar = "toggle_sidebar"
    case toggleAgentsPanel = "toggle_agents_panel"
    case toggleAgentSessions = "toggle_agent_sessions"
    case toggleFiles = "toggle_files"
    case toggleSourceControl = "toggle_source_control"
    case goToFile = "go_to_file"
    case findInFiles = "find_in_files"
    case toggleFullScreen = "toggle_full_screen"
    case toggleThemePicker = "toggle_theme_picker"
    case navigateBack = "navigate_back"
    case navigateForward = "navigate_forward"
    case quit = "quit"
    case hideApp = "hide_app"
    case hideOthers = "hide_others"
    case minimize = "minimize"
    case textInputBackspace = "text_input.backspace"
    case textInputDelete = "text_input.delete"
    case textInputLeft = "text_input.left"
    case textInputRight = "text_input.right"
    case textInputWordLeft = "text_input.word_left"
    case textInputWordRight = "text_input.word_right"
    case textInputHome = "text_input.home"
    case textInputEnd = "text_input.end"
    case textInputSelectLeft = "text_input.select_left"
    case textInputSelectRight = "text_input.select_right"
    case textInputSelectWordLeft = "text_input.select_word_left"
    case textInputSelectWordRight = "text_input.select_word_right"
    case textInputSelectHome = "text_input.select_home"
    case textInputSelectEnd = "text_input.select_end"
    case textInputSelectAll = "text_input.select_all"
    case textInputCopy = "text_input.copy"
    case textInputCut = "text_input.cut"
    case textInputPaste = "text_input.paste"
    case textInputUndo = "text_input.undo"
    case textInputRedo = "text_input.redo"
    case textInputDocumentStart = "text_input.document_start"
    case textInputDocumentEnd = "text_input.document_end"
    case textInputShowCharacterPalette = "text_input.show_character_palette"
    case textInputInsertNewline = "text_input.insert_newline"
    case textInputUp = "text_input.up"
    case textInputDown = "text_input.down"
    case textInputSelectUp = "text_input.select_up"
    case textInputSelectDown = "text_input.select_down"
    case textInputDeleteWord = "text_input.delete_word"
    case textInputPageUp = "text_input.page_up"
    case textInputPageDown = "text_input.page_down"
    case textInputSelectPageUp = "text_input.select_page_up"
    case textInputSelectPageDown = "text_input.select_page_down"
    case textInputSelectDocumentStart = "text_input.select_document_start"
    case textInputSelectDocumentEnd = "text_input.select_document_end"
    case textInputSubmit = "text_input.submit"
    case textInputCancel = "text_input.cancel"
    case popoverSelectNext = "popover.select_next"
    case popoverSelectPrevious = "popover.select_previous"
    case popoverConfirm = "popover.confirm"
    case popoverSecondaryConfirm = "popover.secondary_confirm"
    case popoverTabPressed = "popover.tab_pressed"
    case popoverNavigateBack = "popover.navigate_back"
    case popoverDismiss = "popover.dismiss"
    case popoverNextTab = "popover.next_tab"
    case popoverPreviousTab = "popover.previous_tab"
    case menuDismissMenu = "menu.dismiss_menu"
    case menuHighlightPrevious = "menu.highlight_previous"
    case menuHighlightNext = "menu.highlight_next"
    case menuConfirmHighlighted = "menu.confirm_highlighted"
    case menuOpenSubmenu = "menu.open_submenu"
    case menuCloseSubmenu = "menu.close_submenu"
    case buttonActivate = "button.activate"
    case endAllSessionsAndQuit = "end_all_sessions_and_quit"
    case showAll = "show_all"
    case zoom = "zoom"
    case terminalCloseFind = "terminal.close_find"
    case previousPrompt = "previous_prompt"
    case nextPrompt = "next_prompt"
    case selectCommandOutput = "select_command_output"
    case openSettings = "open_settings"
    case settingsClose = "settings.close"
    case settingsSearch = "settings.search"
    case settingsFocusNavbar = "settings.focus_navbar"
    case settingsNextControl = "settings.next_control"
    case settingsPreviousControl = "settings.previous_control"
    case installCommandLineTool = "install_command_line_tool"
    case toggleCommandPalette = "toggle_command_palette"
    case commandPaletteActions = "command_palette.actions"
    case toggleVoiceRecording = "toggle_voice_recording"
    case voiceFinish = "voice.finish"
    case voiceCancel = "voice.cancel"
    case voicePause = "voice.pause"
    case newBrowserTab = "new_browser_tab"
    case browserFocusAddress = "browser.focus_address"
    case browserReload = "browser.reload"
    case browserBack = "browser.back"
    case browserForward = "browser.forward"
    case browserZoomIn = "browser.zoom_in"
    case browserZoomOut = "browser.zoom_out"
    case browserZoomReset = "browser.zoom_reset"
    case browserCopyUrl = "browser.copy_url"
    case browserInspect = "browser.inspect"
}

extension ShortcutCatalog {
    /// Every shortcut, in the order Settings lists them.
    public static let all: [ShortcutDefinition] = [
        ShortcutDefinition(.newTab, keys: ["cmd-t"], contexts: ["MainWindow"], keyContexts: [["MainWindow"]], group: .panes),
        ShortcutDefinition(.existingTerminals, keys: ["cmd-alt-t"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.detachTerminal, keys: [], contexts: ["WorkspaceTabs"], keyContexts: [], group: .panes),
        ShortcutDefinition(.closeTab, keys: ["cmd-shift-w"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.splitRight, keys: ["cmd-d"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.splitDown, keys: ["cmd-shift-d"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.focusPaneLeft, keys: ["cmd-alt-left"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.focusPaneRight, keys: ["cmd-alt-right"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.focusPaneUp, keys: ["cmd-alt-up"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.focusPaneDown, keys: ["cmd-alt-down"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.toggleZoomPane, keys: ["cmd-shift-enter"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.equalizeSplits, keys: ["cmd-ctrl-="], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.closePane, keys: ["cmd-w"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.nextTab, keys: ["cmd-]", "ctrl-tab"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"], ["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.previousTab, keys: ["cmd-[", "ctrl-shift-tab"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"], ["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.previousProject, keys: ["ctrl-[", "cmd-alt-["], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"], ["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.nextProject, keys: ["ctrl-]", "cmd-alt-]"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"], ["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.addProject, keys: ["cmd-o"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectTab1, keys: ["cmd-1"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectTab2, keys: ["cmd-2"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectTab3, keys: ["cmd-3"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectTab4, keys: ["cmd-4"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectTab5, keys: ["cmd-5"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectTab6, keys: ["cmd-6"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectTab7, keys: ["cmd-7"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectTab8, keys: ["cmd-8"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectTab9, keys: ["cmd-9"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.selectProject1, keys: ["ctrl-1"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectProject2, keys: ["ctrl-2"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectProject3, keys: ["ctrl-3"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectProject4, keys: ["ctrl-4"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectProject5, keys: ["ctrl-5"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectProject6, keys: ["ctrl-6"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectProject7, keys: ["ctrl-7"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectProject8, keys: ["ctrl-8"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.selectProject9, keys: ["ctrl-9"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.copy, keys: ["cmd-c"], contexts: [ShortcutContext.workspaceClipboard], keyContexts: [[ShortcutContext.workspaceClipboard]], group: .terminal),
        ShortcutDefinition(.paste, keys: ["cmd-v"], contexts: [ShortcutContext.workspaceClipboard], keyContexts: [[ShortcutContext.workspaceClipboard]], group: .terminal),
        ShortcutDefinition(.find, keys: ["cmd-f"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .terminal),
        ShortcutDefinition(.findNext, keys: ["cmd-g"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .terminal),
        ShortcutDefinition(.findPrevious, keys: ["cmd-shift-g"], contexts: ["TerminalSearchInput"], keyContexts: [["TerminalSearchInput"]], group: .terminal),
        ShortcutDefinition(.scrollToBottom, keys: ["cmd-end"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .terminal),
        ShortcutDefinition(.increaseFontSize, keys: ["cmd-+", "cmd-=", "cmd-shift-="], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"], ["WorkspaceTabs"], ["WorkspaceTabs"]], group: .terminal),
        ShortcutDefinition(.decreaseFontSize, keys: ["cmd--"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .terminal),
        ShortcutDefinition(.newHomeTab, keys: ["cmd-n"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .panes),
        ShortcutDefinition(.newTabInProject, keys: ["cmd-shift-n"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.newWorktree, keys: ["cmd-alt-n"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.switchWorktree, keys: ["cmd-alt-w"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.toggleSidebar, keys: ["cmd-b"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.toggleAgentsPanel, keys: ["cmd-alt-a"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.toggleAgentSessions, keys: [], contexts: ["WorkspaceTabs"], keyContexts: [], group: .projects),
        ShortcutDefinition(.toggleFiles, keys: ["cmd-e"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .files),
        ShortcutDefinition(.toggleSourceControl, keys: ["cmd-y"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .files),
        ShortcutDefinition(.goToFile, keys: ["cmd-p"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .files),
        ShortcutDefinition(.findInFiles, keys: ["cmd-shift-f"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .files),
        ShortcutDefinition(.toggleFullScreen, keys: ["cmd-ctrl-f"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.toggleThemePicker, keys: ["cmd-shift-k"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.navigateBack, keys: ["cmd-ctrl-left"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.navigateForward, keys: ["cmd-ctrl-right"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .projects),
        ShortcutDefinition(.quit, keys: ["cmd-q"], contexts: [nil], keyContexts: [[nil]], group: .app),
        ShortcutDefinition(.hideApp, keys: ["cmd-h"], contexts: [nil], keyContexts: [[nil]], group: .app),
        ShortcutDefinition(.hideOthers, keys: ["cmd-alt-h"], contexts: [nil], keyContexts: [[nil]], group: .app),
        ShortcutDefinition(.minimize, keys: ["cmd-m"], contexts: [nil], keyContexts: [[nil]], group: .app),
        ShortcutDefinition(.textInputBackspace, keys: ["backspace"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputDelete, keys: ["delete"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputLeft, keys: ["left"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputRight, keys: ["right"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputWordLeft, keys: ["alt-left"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputWordRight, keys: ["alt-right"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputHome, keys: ["cmd-left"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputEnd, keys: ["cmd-right"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectLeft, keys: ["shift-left"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectRight, keys: ["shift-right"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectWordLeft, keys: ["shift-alt-left"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectWordRight, keys: ["shift-alt-right"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectHome, keys: ["shift-cmd-left"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectEnd, keys: ["shift-cmd-right"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectAll, keys: ["cmd-a"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput", "TerminalPane", "TerminalFindOpen"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput", "TerminalPane", "TerminalFindOpen"]], group: .textEditing),
        ShortcutDefinition(.textInputCopy, keys: ["cmd-c"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputCut, keys: ["cmd-x"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputPaste, keys: ["cmd-v"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputUndo, keys: ["cmd-z"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputRedo, keys: ["shift-cmd-z"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputDocumentStart, keys: ["home", "cmd-up"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], ["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputDocumentEnd, keys: ["end", "cmd-down"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], ["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputShowCharacterPalette, keys: ["ctrl-cmd-space"], contexts: ["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"], keyContexts: [["TextInput", "BareInput", "TerminalSearchInput", "MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputInsertNewline, keys: ["enter"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputUp, keys: ["up"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputDown, keys: ["down"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectUp, keys: ["shift-up"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectDown, keys: ["shift-down"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputDeleteWord, keys: ["alt-backspace"], contexts: ["MultilineInput", "TextInput", "TerminalSearchInput"], keyContexts: [["MultilineInput", "TextInput", "TerminalSearchInput"]], group: .textEditing),
        ShortcutDefinition(.textInputPageUp, keys: ["pageup"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputPageDown, keys: ["pagedown"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectPageUp, keys: ["shift-pageup"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectPageDown, keys: ["shift-pagedown"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectDocumentStart, keys: ["shift-cmd-up"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSelectDocumentEnd, keys: ["shift-cmd-down"], contexts: ["MultilineInput"], keyContexts: [["MultilineInput"]], group: .textEditing),
        ShortcutDefinition(.textInputSubmit, keys: ["enter"], contexts: ["TextInput", "TerminalSearchInput"], keyContexts: [["TextInput", "TerminalSearchInput"]], group: .textEditing),
        ShortcutDefinition(.textInputCancel, keys: ["escape"], contexts: ["TextInput", "TerminalSearchInput"], keyContexts: [["TextInput", "TerminalSearchInput"]], group: .textEditing),
        ShortcutDefinition(.popoverSelectNext, keys: ["down"], contexts: ["Picker"], keyContexts: [["Picker"]], group: .lists),
        ShortcutDefinition(.popoverSelectPrevious, keys: ["up", "shift-tab"], contexts: ["Picker"], keyContexts: [["Picker"], ["Picker"]], group: .lists),
        ShortcutDefinition(.popoverConfirm, keys: ["enter"], contexts: ["Picker"], keyContexts: [["Picker"]], group: .lists),
        ShortcutDefinition(.popoverSecondaryConfirm, keys: ["alt-enter", "cmd-enter"], contexts: ["Picker"], keyContexts: [["Picker"], ["Picker"]], group: .lists),
        ShortcutDefinition(.popoverTabPressed, keys: ["tab"], contexts: ["Picker"], keyContexts: [["Picker"]], group: .lists),
        ShortcutDefinition(.popoverNavigateBack, keys: ["alt-backspace", "alt-left"], contexts: ["Picker"], keyContexts: [["Picker"], ["Picker"]], group: .lists),
        ShortcutDefinition(.popoverDismiss, keys: ["escape"], contexts: ["Picker"], keyContexts: [["Picker"]], group: .lists),
        ShortcutDefinition(.popoverNextTab, keys: ["ctrl-tab"], contexts: ["Picker"], keyContexts: [["Picker"]], group: .lists),
        ShortcutDefinition(.popoverPreviousTab, keys: ["ctrl-shift-tab"], contexts: ["Picker"], keyContexts: [["Picker"]], group: .lists),
        ShortcutDefinition(.menuDismissMenu, keys: ["escape"], contexts: ["Menu"], keyContexts: [["Menu"]], group: .lists),
        ShortcutDefinition(.menuHighlightPrevious, keys: ["up"], contexts: ["Menu"], keyContexts: [["Menu"]], group: .lists),
        ShortcutDefinition(.menuHighlightNext, keys: ["down"], contexts: ["Menu"], keyContexts: [["Menu"]], group: .lists),
        ShortcutDefinition(.menuConfirmHighlighted, keys: ["enter"], contexts: ["Menu"], keyContexts: [["Menu"]], group: .lists),
        ShortcutDefinition(.menuOpenSubmenu, keys: ["right"], contexts: ["Menu"], keyContexts: [["Menu"]], group: .lists),
        ShortcutDefinition(.menuCloseSubmenu, keys: ["left"], contexts: ["Menu"], keyContexts: [["Menu"]], group: .lists),
        ShortcutDefinition(.buttonActivate, keys: ["enter", "space"], contexts: ["Button"], keyContexts: [["Button"], ["Button"]], group: .lists),
        ShortcutDefinition(.endAllSessionsAndQuit, keys: [], contexts: [nil], keyContexts: [], group: .app),
        ShortcutDefinition(.showAll, keys: [], contexts: [nil], keyContexts: [], group: .app),
        ShortcutDefinition(.zoom, keys: [], contexts: [nil], keyContexts: [], group: .app),
        ShortcutDefinition(.terminalCloseFind, keys: ["escape"], contexts: ["TerminalFindOpen && !TerminalSearchInput"], keyContexts: [["TerminalFindOpen && !TerminalSearchInput"]], group: .terminal),
        ShortcutDefinition(.previousPrompt, keys: ["cmd-up", "cmd-shift-up"], contexts: [ShortcutContext.workspaceClipboard], keyContexts: [[ShortcutContext.workspaceClipboard], [ShortcutContext.workspaceClipboard]], group: .terminal),
        ShortcutDefinition(.nextPrompt, keys: ["cmd-down", "cmd-shift-down"], contexts: [ShortcutContext.workspaceClipboard], keyContexts: [[ShortcutContext.workspaceClipboard], [ShortcutContext.workspaceClipboard]], group: .terminal),
        ShortcutDefinition(.selectCommandOutput, keys: [], contexts: [ShortcutContext.workspaceClipboard], keyContexts: [], group: .terminal),
        ShortcutDefinition(.openSettings, keys: ["cmd-,"], contexts: [nil], keyContexts: [[nil]], group: .app),
        ShortcutDefinition(.settingsClose, keys: ["cmd-w"], contexts: ["SettingsWindow"], keyContexts: [["SettingsWindow"]], group: .settingsWindow),
        ShortcutDefinition(.settingsSearch, keys: ["cmd-f"], contexts: ["SettingsWindow"], keyContexts: [["SettingsWindow"]], group: .settingsWindow),
        ShortcutDefinition(.settingsFocusNavbar, keys: ["cmd-shift-e"], contexts: ["SettingsWindow"], keyContexts: [["SettingsWindow"]], group: .settingsWindow),
        ShortcutDefinition(.settingsNextControl, keys: ["tab"], contexts: ["SettingsWindow"], keyContexts: [["SettingsWindow"]], group: .settingsWindow),
        ShortcutDefinition(.settingsPreviousControl, keys: ["shift-tab"], contexts: ["SettingsWindow"], keyContexts: [["SettingsWindow"]], group: .settingsWindow),
        ShortcutDefinition(.installCommandLineTool, keys: [], contexts: [nil], keyContexts: [], group: .app),
        ShortcutDefinition(.toggleCommandPalette, keys: ["cmd-shift-p"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .palette),
        ShortcutDefinition(.commandPaletteActions, keys: ["cmd-k"], contexts: ["CommandPalette"], keyContexts: [["CommandPalette"]], group: .palette),
        ShortcutDefinition(.toggleVoiceRecording, keys: ["cmd-shift-i"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .dictation),
        ShortcutDefinition(.voiceFinish, keys: ["enter"], contexts: ["VoiceRecording"], keyContexts: [["VoiceRecording"]], group: .dictation),
        ShortcutDefinition(.voiceCancel, keys: ["escape"], contexts: ["VoiceRecording"], keyContexts: [["VoiceRecording"]], group: .dictation),
        ShortcutDefinition(.voicePause, keys: ["space"], contexts: ["VoiceRecording"], keyContexts: [["VoiceRecording"]], group: .dictation),
        ShortcutDefinition(.newBrowserTab, keys: ["cmd-alt-b"], contexts: ["WorkspaceTabs"], keyContexts: [["WorkspaceTabs"]], group: .browser),
        ShortcutDefinition(.browserFocusAddress, keys: ["cmd-l"], contexts: ["Browser"], keyContexts: [["Browser"]], group: .browser),
        ShortcutDefinition(.browserReload, keys: ["cmd-r"], contexts: ["Browser"], keyContexts: [["Browser"]], group: .browser),
        ShortcutDefinition(.browserBack, keys: ["cmd-["], contexts: ["Browser"], keyContexts: [["Browser"]], group: .browser),
        ShortcutDefinition(.browserForward, keys: ["cmd-]"], contexts: ["Browser"], keyContexts: [["Browser"]], group: .browser),
        ShortcutDefinition(.browserZoomIn, keys: ["cmd-=", "cmd-+", "cmd-shift-="], contexts: ["Browser"], keyContexts: [["Browser"], ["Browser"], ["Browser"]], group: .browser),
        ShortcutDefinition(.browserZoomOut, keys: ["cmd--"], contexts: ["Browser"], keyContexts: [["Browser"]], group: .browser),
        ShortcutDefinition(.browserZoomReset, keys: ["cmd-0"], contexts: ["Browser"], keyContexts: [["Browser"]], group: .browser),
        ShortcutDefinition(.browserCopyUrl, keys: ["cmd-shift-c"], contexts: ["Browser"], keyContexts: [["Browser"]], group: .browser),
        ShortcutDefinition(.browserInspect, keys: ["cmd-alt-i"], contexts: ["Browser"], keyContexts: [["Browser"]], group: .browser),
    ]
}
