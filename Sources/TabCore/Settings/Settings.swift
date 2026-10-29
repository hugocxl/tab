import Foundation

/// The app's preferences, stored in `settings.json`. Every section tolerates
/// missing and unknown keys, so files written by older or newer builds load.
public struct Settings: Codable, Equatable, Sendable {
    public var voice: VoiceSettings
    public var ai: AISettings
    public var commands: [CustomCommand]
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
        voice = VoiceSettings()
        ai = AISettings()
        commands = []
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
        voice = try container.value(.voice, defaults.voice)
        ai = try container.value(.ai, defaults.ai)
        commands = try container.value(.commands, defaults.commands)
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
        try voice.validate()
        try browser.validate()
        try validateCommands()
        try ServerEntry.validate(servers)
        try window.validate()
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

    public func saveVoice(to url: URL) throws {
        try voice.validate()
        try saveSection("voice", voice, to: url)
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

    /// Saves one AI entry, such as `prompts.commit`, over the file's current
    /// contents, and returns the AI settings as saved. `nil` removes it.
    public static func saveAIEntry(in url: URL, table: String, key: String, value: String?) throws -> AISettings {
        try saveAIEntries(in: url, table: table, entries: [(key, value)])
    }

    /// Saves the options last chosen for an AI commit.
    public static func saveCommitChoices(_ choices: CommitChoices, in url: URL) throws -> AISettings {
        try saveAIEntries(
            in: url,
            table: "commit",
            entries: [("includeUnstaged", choices.includeUnstaged), ("push", choices.push)]
        )
    }

    private static func saveAIEntries(in url: URL, table: String, entries: [(String, Any?)]) throws -> AISettings {
        var document = try SettingsDocument.read(url)
        try document.setEntries("ai", table, entries)
        try document.write(to: url)
        do {
            return try SettingsJSON.decode(AISettings.self, from: document.root["ai"] ?? [String: Any]())
        } catch {
            throw SettingsError("ai", SettingsJSON.describe(error))
        }
    }
}

public struct WindowSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum CloseBehavior: String, Codable, Sendable, CaseIterable {
    /// Closing a terminal pane ends its terminal.
    case closeSession
    /// Closing a terminal pane leaves it running in the server.
    case detach
}

public struct WindowSettings: Codable, Equatable, Sendable {
    public var defaultSize: WindowSize
    /// Closing asks first while a program other than the shell runs.
    public var confirmRunningProcess: Bool
    public var closeBehavior: CloseBehavior

    public init(
        defaultSize: WindowSize = WindowSize(width: 1200, height: 800),
        confirmRunningProcess: Bool = true,
        closeBehavior: CloseBehavior = .closeSession
    ) {
        self.defaultSize = defaultSize
        self.confirmRunningProcess = confirmRunningProcess
        self.closeBehavior = closeBehavior
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WindowSettings()
        defaultSize = try container.value(.defaultSize, defaults.defaultSize)
        confirmRunningProcess = try container.value(.confirmRunningProcess, defaults.confirmRunningProcess)
        closeBehavior = try container.value(.closeBehavior, defaults.closeBehavior)
    }

    public func validate() throws {
        for (name, value, minimum) in [("width", defaultSize.width, 640.0), ("height", defaultSize.height, 400.0)] {
            guard value.isFinite, (minimum...16384).contains(value) else {
                throw SettingsError("window.defaultSize.\(name)", "must be between \(Int(minimum)) and 16384")
            }
        }
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

/// The options last chosen for an AI commit.
public struct CommitChoices: Codable, Equatable, Sendable {
    public var includeUnstaged: Bool
    public var push: Bool

    public init(includeUnstaged: Bool = true, push: Bool = true) {
        self.includeUnstaged = includeUnstaged
        self.push = push
    }
}

/// AI tool choices per action. Hand edits are expected here, so keys this
/// build does not know and values that are not text are ignored instead of
/// stopping the app from starting.
public struct AISettings: Codable, Equatable, Sendable {
    /// The command-line tool per action, such as `commit` → `claude`.
    public var providers: [String: String]
    /// Extra instructions per action.
    public var prompts: [String: String]
    /// Pull request instructions per project id.
    public var projectPrPrompts: [String: String]
    public var commit: CommitChoices

    enum CodingKeys: String, CodingKey {
        case providers, prompts, projectPrPrompts, commit
    }

    public init(
        providers: [String: String] = [:],
        prompts: [String: String] = [:],
        projectPrPrompts: [String: String] = [:],
        commit: CommitChoices = CommitChoices()
    ) {
        self.providers = providers
        self.prompts = prompts
        self.projectPrPrompts = projectPrPrompts
        self.commit = commit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = Self.textEntries(container, .providers)
        prompts = Self.textEntries(container, .prompts)
        projectPrPrompts = Self.textEntries(container, .projectPrPrompts)
        let defaults = CommitChoices()
        let commit = try? container.nestedContainer(keyedBy: CommitChoices.CodingKeys.self, forKey: .commit)
        self.commit = CommitChoices(
            includeUnstaged: (try? commit?.decodeIfPresent(Bool.self, forKey: .includeUnstaged)) ?? defaults.includeUnstaged,
            push: (try? commit?.decodeIfPresent(Bool.self, forKey: .push)) ?? defaults.push
        )
    }

    private static func textEntries(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: String] {
        guard let table = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) else { return [:] }
        var entries: [String: String] = [:]
        for entry in table.allKeys {
            if let text = try? table.decode(String.self, forKey: entry) { entries[entry.stringValue] = text }
        }
        return entries
    }
}

extension CommitChoices {
    enum CodingKeys: String, CodingKey {
        case includeUnstaged, push
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

public struct VoiceSettings: Codable, Equatable, Sendable {
    /// The dictation language, such as `en-US`; empty follows the system.
    public var language: String
    /// An offline model's path; empty uses the system recognizer.
    public var model: String
    /// Presses Return after inserting the transcript.
    public var autoSend: Bool

    public init(language: String = "", model: String = "", autoSend: Bool = false) {
        self.language = language
        self.model = model
        self.autoSend = autoSend
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.value(.language, "")
        model = try container.value(.model, "")
        autoSend = try container.value(.autoSend, false)
    }

    public func validate() throws {
        if model.utf8.count > 4096 || model.contains("\0") {
            throw SettingsError("voice.model", "Invalid model path")
        }
        if language.utf8.count > 200 {
            throw SettingsError("voice.language", "Language names must be at most 200 bytes")
        }
    }
}
