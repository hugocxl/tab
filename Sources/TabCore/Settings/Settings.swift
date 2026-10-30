import Foundation

/// The app's preferences, stored in `settings.json`. Every section tolerates
/// missing and unknown keys, so files written by older or newer builds load.
public struct Settings: Codable, Equatable, Sendable {
    public var appearance: Appearance
    public var window: WindowSettings
    public var keymap: Keymap
    public var projects: ProjectSettings
    public var worktrees: WorktreeSettings
    public var panes: PaneSettings
    public var clipboard: ClipboardSettings
    public var openers: OpenerSettings
    public var browser: BrowserSettings
    /// Other computers' servers, reached over SSH.
    public var servers: [ServerEntry]

    public init() {
        appearance = Appearance()
        window = WindowSettings()
        keymap = Keymap()
        projects = ProjectSettings()
        worktrees = WorktreeSettings()
        panes = PaneSettings()
        clipboard = ClipboardSettings()
        openers = OpenerSettings()
        browser = BrowserSettings()
        servers = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        appearance = try container.value(.appearance, defaults.appearance)
        window = try container.value(.window, defaults.window)
        keymap = try container.value(.keymap, defaults.keymap)
        projects = try container.value(.projects, defaults.projects)
        worktrees = try container.value(.worktrees, defaults.worktrees)
        panes = try container.value(.panes, defaults.panes)
        clipboard = try container.value(.clipboard, defaults.clipboard)
        openers = try container.value(.openers, defaults.openers)
        browser = try container.value(.browser, defaults.browser)
        servers = try container.value(.servers, defaults.servers)
    }

    /// Reads `url`, creating it with the defaults when missing, and checks
    /// every section.
    public static func load(_ url: URL) throws -> Settings {
        let data = try readOrCreate(url) { try SettingsJSON.encode(Settings()) }
        let settings = try decode(data, path: url.path)
        try settings.validate()
        return settings
    }

    /// Settings from JSON; an empty document is the defaults.
    public static func decode(_ data: Data, path: String = "settings.json") throws -> Settings {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            throw SettingsError(path, SettingsJSON.describe(error))
        }
    }

    public func validate() throws {
        try browser.validate()
        try ServerEntry.validate(servers)
    }

    public func server(_ id: ServerId) -> ServerEntry? { servers.first { $0.id == id } }

    // MARK: Saving sections

    /// Writes one section over the file's current contents, keeping the
    /// file's other sections and keys this build does not know.
    private func saveSection<T: Encodable>(_ name: String, _ value: T, to url: URL) throws {
        var document = try SettingsDocument.read(url)
        try document.merge(name, value)
        try document.write(to: url)
    }

    public func saveWindow(to url: URL) throws {
        try validate()
        try saveSection("window", window, to: url)
    }

    public func saveOpeners(to url: URL) throws {
        try saveSection("openers", openers, to: url)
    }

    public func saveBrowser(to url: URL) throws {
        try browser.validate()
        try saveSection("browser", browser, to: url)
    }

    public func savePanes(to url: URL) throws {
        try saveSection("panes", panes, to: url)
    }

    public func saveClipboard(to url: URL) throws {
        try saveSection("clipboard", clipboard, to: url)
    }

    public func saveWorktrees(to url: URL) throws {
        try worktrees.defaultLocation.validate()
        for location in worktrees.projects.values { try location.validate() }
        try saveSection("worktrees", worktrees, to: url)
    }

    /// Saves whether closing asks first while a program runs. The setting
    /// changes in memory only once it is saved.
    public mutating func setConfirmRunningProcess(_ enabled: Bool, in url: URL) throws {
        var document = try SettingsDocument.read(url)
        try document.merge("window", ["confirmRunningProcess": enabled])
        try document.write(to: url)
        window.confirmRunningProcess = enabled
    }

    /// Saves where the Open Project page searches for folders.
    public mutating func setProjectSearchRoot(_ root: String, in url: URL) throws {
        var document = try SettingsDocument.read(url)
        try document.merge("projects", ["searchRoot": root])
        try document.write(to: url)
        projects.searchRoot = root
    }
}

public enum CloseBehavior: String, Codable, Sendable, CaseIterable {
    /// Closing a terminal pane ends its terminal.
    case closeSession
    /// Closing a terminal pane leaves it running in the server.
    case detach
}

public struct WindowSettings: Codable, Equatable, Sendable {
    /// Closing asks first while a program other than the shell runs.
    public var confirmRunningProcess: Bool
    public var closeBehavior: CloseBehavior

    public init(confirmRunningProcess: Bool = true, closeBehavior: CloseBehavior = .closeSession) {
        self.confirmRunningProcess = confirmRunningProcess
        self.closeBehavior = closeBehavior
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WindowSettings()
        confirmRunningProcess = try container.value(.confirmRunningProcess, defaults.confirmRunningProcess)
        closeBehavior = try container.value(.closeBehavior, defaults.closeBehavior)
    }
}

public enum NewPaneDirectory: String, Codable, Sendable, CaseIterable {
    /// New terminals start in the project's folder.
    case project
    /// New terminals start in the focused terminal's folder.
    case current
}

public struct PaneSettings: Codable, Equatable, Sendable {
    public var newPaneDirectory: NewPaneDirectory

    public init(newPaneDirectory: NewPaneDirectory = .project) {
        self.newPaneDirectory = newPaneDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newPaneDirectory = try container.value(.newPaneDirectory, .project)
    }
}

public struct ProjectSettings: Codable, Equatable, Sendable {
    /// Where the Open Project page searches for folders.
    public var searchRoot: String?

    public init(searchRoot: String? = nil) {
        self.searchRoot = searchRoot
    }
}

public struct ClipboardSettings: Codable, Equatable, Sendable {
    public var copyOnSelect: Bool

    public init(copyOnSelect: Bool = false) {
        self.copyOnSelect = copyOnSelect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copyOnSelect = try container.value(.copyOnSelect, false)
    }
}

public struct OpenerSettings: Codable, Equatable, Sendable {
    /// The file opener that shows project files in Tab's own editor pane.
    public static let tabEditor = "tab.editor"
    /// The opener that sends links to the default browser.
    public static let systemBrowser = "system.browser"

    /// Where terminal links open: `system.browser`, or an app's identifier.
    public var url: String
    /// Where terminal file paths open: `tab.editor`, or an app's identifier.
    public var file: String
    /// The app projects open in, if one was chosen.
    public var projectTarget: String?

    public init(url: String = OpenerSettings.systemBrowser, file: String = OpenerSettings.tabEditor, projectTarget: String? = nil) {
        self.url = url
        self.file = file
        self.projectTarget = projectTarget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.value(.url, Self.systemBrowser)
        file = try container.value(.file, Self.tabEditor)
        projectTarget = try container.decodeIfPresent(String.self, forKey: .projectTarget)
    }
}
