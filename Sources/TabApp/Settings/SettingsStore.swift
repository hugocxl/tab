import AppKit
import Combine
import TabCore
import TabProtocol

/// The Settings window's model: the app's preferences as saved in the
/// profile, the server's and mobile access's settings read through the host,
/// and the problems to show beside each row. Every change is validated,
/// saved at once and passed to the host to apply. The app keeps one store
/// for its whole life; it also reloads `terminal.json` when the app becomes
/// active, so hand edits apply.
@MainActor
public final class SettingsStore {
    public let dirs: TabDirs
    public weak var host: SettingsHost?
    public let theme: AppTheme

    public private(set) var settings: Settings
    public private(set) var terminal: TerminalSettings
    /// Problems by row id; `application` and `configuration` are page-wide.
    public private(set) var errors: [String: String] = [:]

    public private(set) var serverState: ServerConnectionState
    public private(set) var serverSettings: ServerSettingsDoc?
    public private(set) var serverBusy = false
    public private(set) var remoteAccess: RemoteAccessState?
    public private(set) var pairing: PairingOffer?
    public private(set) var mobileBusy = false
    public private(set) var backupBusy = false
    public private(set) var backupStatus = ""
    public private(set) var browserProfiles: [BrowserProfileSummary] = []

    /// Fires after anything the window shows changed.
    public let changes = PassthroughSubject<Void, Never>()
    private var activation: NSObjectProtocol?

    /// Loads `settings.json` and `terminal.json` from `dirs`. A file that
    /// does not load leaves the defaults in place and its problem on the page.
    public init(dirs: TabDirs, host: SettingsHost?, theme: AppTheme? = nil) {
        self.dirs = dirs
        self.host = host
        self.theme = theme ?? .shared
        serverState = host?.serverState ?? .stopped
        var errors: [String: String] = [:]
        do {
            settings = try Settings.load(dirs.settings)
        } catch {
            settings = Settings()
            errors["application"] = "\(error)"
        }
        do {
            terminal = try TerminalSettings.load(dirs.terminalSettings)
        } catch {
            terminal = TerminalSettings()
            errors["configuration"] = "terminal.json: \(error). Your last saved values are kept until it is fixed."
        }
        self.errors = errors
        if BackupArchive.hasPending(dirs) {
            backupStatus = "An import is ready for the next launch. Quit and reopen Tab to apply it, or cancel the import here."
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadTerminal() }
        }
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    private func changed() { changes.send() }

    /// Runs a save, recording its problem under `id` or clearing it.
    @discardableResult
    private func attempt(_ id: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            errors[id] = nil
            changed()
            return true
        } catch {
            errors[id] = Self.message(error)
            changed()
            return false
        }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? SettingsError { return error.message.prefix(1).uppercased() + error.message.dropFirst() }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    public func dismissError(_ id: String) {
        errors[id] = nil
        changed()
    }

    /// Records a problem found by a control, such as a refused shortcut.
    public func setError(_ id: String, _ message: String?) {
        errors[id] = message
        changed()
    }

    private func applySettings() { host?.settingsDidChange(settings) }

    // MARK: General

    public func setCloseBehavior(_ behavior: CloseBehavior) {
        attempt("close-behavior") {
            var next = settings
            next.window.closeBehavior = behavior
            try next.saveWindow(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    public func setConfirmRunningProcess(_ enabled: Bool) {
        attempt("confirm-process") {
            try settings.setConfirmRunningProcess(enabled, in: dirs.settings)
            applySettings()
        }
    }

    public func setFileOpener(_ opener: String) {
        attempt("file-opener") {
            var next = settings
            next.openers.file = opener
            try next.saveOpeners(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    /// Saves the default window width or height from its field.
    public func setWindowSize(_ id: String, _ text: String) {
        attempt(id) {
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
                throw SettingsError(id, "Enter a number of points.")
            }
            var next = settings
            if id == "width" { next.window.defaultSize.width = value } else { next.window.defaultSize.height = value }
            try next.saveWindow(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    public func setWorktreeLocation(_ id: String, _ text: String) {
        attempt(id) {
            var next = settings
            if id == "worktree-template" {
                next.worktrees.defaultLocation.pathTemplate = text
            } else {
                next.worktrees.defaultLocation.parentPath = text
            }
            try next.saveWorktrees(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    public func setVoiceAutoSend(_ enabled: Bool) {
        updateVoice("voice-auto-send") { $0.autoSend = enabled }
    }

    public func setVoiceLanguage(_ language: String) {
        updateVoice("voice-language") { $0.language = language }
    }

    public func setVoiceModel(_ path: String) {
        updateVoice("voice-model") { $0.model = path }
    }

    private func updateVoice(_ id: String, _ change: (inout VoiceSettings) -> Void) {
        attempt(id) {
            var next = settings
            change(&next.voice)
            try next.saveVoice(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    // MARK: Appearance

    /// Changes appearance settings, saving only what changed so the main
    /// window's own saves in between are kept.
    public func updateAppearance(_ id: String, _ change: (inout Appearance) -> Void) {
        attempt(id) {
            var next = settings.appearance
            change(&next)
            settings.appearance = try next.saveChanges(since: settings.appearance, to: dirs.settings)
            theme.setThemes(dark: settings.appearance.darkTheme, light: settings.appearance.lightTheme)
            applySettings()
        }
    }

    public func setTheme(dark: Bool, _ name: String) {
        updateAppearance(dark ? "dark-theme" : "light-theme") { appearance in
            if dark { appearance.darkTheme = name } else { appearance.lightTheme = name }
        }
    }

    // MARK: Keyboard

    /// Binds a shortcut, or resets it with `nil`. Returns the reason a chord
    /// was refused, such as a conflict with another shortcut.
    @discardableResult
    public func setBinding(_ id: String, _ chord: KeyChord?) -> String? {
        if let chord {
            if Keymap.isCommandAction(id) && !chord.hasCommandModifier {
                return refuse(id, "Command shortcuts must include Command, Control, or Option.")
            }
            if let other = settings.keymap.conflict(for: id, chord: chord), other != id {
                return refuse(id, "\(chord.display) is already used by \(Self.actionName(other, commands: settings.commands)).")
            }
            if Keymap.isCommandAction(id), terminal.keybindings.action(for: chord) != nil {
                return refuse(id, "\(chord.display) is a terminal key binding. Choose a different shortcut.")
            }
        }
        do {
            let keymap = try settings.keymap.withBinding(id, chord)
            var next = settings
            next.keymap = keymap
            try keymap.save(to: dirs.settings)
            settings = next
            errors[id] = nil
            changed()
            applySettings()
            return nil
        } catch {
            return refuse(id, Self.message(error))
        }
    }

    private func refuse(_ id: String, _ message: String) -> String {
        errors[id] = message
        changed()
        return message
    }

    /// How a keymap action is named on the page.
    static func actionName(_ id: String, commands: [CustomCommand]) -> String {
        if let shortcut = ShortcutCatalog.find(id) { return shortcut.label }
        if let command = commands.first(where: { $0.shortcutId == id }) { return command.name }
        return id
    }

    // MARK: Commands

    /// Adds `command`, or replaces the one with its id.
    @discardableResult
    public func saveCommand(_ command: CustomCommand) -> Bool {
        attempt("commands") {
            var next = settings
            var command = command
            command.name = command.name.trimmingCharacters(in: .whitespaces)
            command.command = command.command.trimmingCharacters(in: .whitespaces)
            try command.validate()
            if let index = next.commands.firstIndex(where: { $0.id == command.id }) {
                next.commands[index] = command
            } else {
                next.commands.append(command)
            }
            try next.saveCommands(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    public func removeCommand(_ id: String) {
        attempt("commands") {
            var next = settings
            guard let command = next.commands.first(where: { $0.id == id }) else { return }
            next.commands.removeAll { $0.id == id }
            if next.keymap.binding(command.shortcutId) != nil {
                next.keymap = try next.keymap.withBinding(command.shortcutId, nil)
            }
            try next.saveCommands(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    // MARK: Terminal

    /// Changes one terminal preference by its Settings id and saves it.
    public func setTerminal(_ id: String, _ value: String) {
        attempt(Self.terminalRow(id)) {
            var next = terminal
            try next.setPreference(id, value)
            try saveTerminal(next)
        }
    }

    /// The row a terminal preference's problems show on.
    static func terminalRow(_ id: String) -> String {
        switch id {
        case "padding-left", "padding-right": return "window-padding-x"
        case "padding-top", "padding-bottom": return "window-padding-y"
        case "dismiss-import-notes": return "terminal-import-notes"
        default: return id
        }
    }

    /// Shows a terminal preference without saving it, while a slider moves.
    public func previewTerminal(_ id: String, _ value: String) {
        var next = terminal
        guard (try? next.setPreference(id, value)) != nil else { return }
        host?.previewTerminalSettings(next)
    }

    public func editTerminal(_ id: String, _ edit: TerminalEdit) {
        attempt(id) {
            var next = terminal
            try next.edit(edit)
            try saveTerminal(next)
        }
    }

    private func saveTerminal(_ next: TerminalSettings) throws {
        if next.keybindings != terminal.keybindings {
            try settings.validateCommandShortcuts(terminal: next)
        }
        try next.save(to: dirs.terminalSettings)
        terminal = next
        host?.terminalSettingsDidChange(next)
    }

    public func setNewPaneDirectory(_ directory: NewPaneDirectory) {
        attempt("directory") {
            var next = settings
            next.panes.newPaneDirectory = directory
            try next.savePanes(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    /// Whether anything on the Terminal page differs from the defaults.
    public var terminalIsCustomized: Bool {
        var defaults = TerminalSettings()
        defaults.diagnostics = terminal.diagnostics
        return terminal != defaults || settings.panes.newPaneDirectory != .project
    }

    /// Returns every Terminal page setting, key bindings included, to its
    /// default.
    public func resetTerminal() {
        attempt("terminal-reset") {
            try saveTerminal(TerminalSettings())
            if settings.panes.newPaneDirectory != .project {
                var next = settings
                next.panes.newPaneDirectory = .project
                try next.savePanes(to: dirs.settings)
                settings = next
                applySettings()
            }
            errors = errors.filter { SettingsCatalog.item($0.key)?.category != .terminal }
        }
    }

    /// Reads `terminal.json` again after a hand edit. A file that does not
    /// load keeps the last good settings and shows why.
    public func reloadTerminal() {
        do {
            let loaded = try TerminalSettings.load(dirs.terminalSettings)
            let hadError = errors["configuration"] != nil
            errors["configuration"] = nil
            guard loaded != terminal || hadError else { return }
            terminal = loaded
            host?.terminalSettingsDidChange(loaded)
            changed()
        } catch {
            let message = "terminal.json: \(Self.message(error)). Your last saved values are kept until it is fixed."
            guard errors["configuration"] != message else { return }
            errors["configuration"] = message
            changed()
        }
    }

    // MARK: Browser

    public func updateBrowser(_ id: String, _ change: (inout BrowserSettings) -> Void) {
        attempt(id) {
            var next = settings
            change(&next.browser)
            try next.saveBrowser(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    public func refreshBrowserProfiles() {
        browserProfiles = host?.browserProfiles() ?? []
        changed()
    }

    public func addBrowserProfile(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return refuseVoid("browser-profiles", "Enter a profile name.") }
        attempt("browser-profiles") { _ = try host?.addBrowserProfile(named: name) }
        refreshBrowserProfiles()
    }

    public func renameBrowserProfile(_ id: String, _ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return refuseVoid("browser-profiles", "Enter a profile name.") }
        attempt("browser-profiles") { try host?.renameBrowserProfile(id, to: name) }
        refreshBrowserProfiles()
    }

    public func deleteBrowserProfile(_ id: String) {
        run("browser-profiles") { host in
            try await host.deleteBrowserProfile(id)
        } then: { [weak self] in
            guard let self else { return }
            if settings.browser.defaultProfile == id { updateBrowser("browser-profiles") { $0.defaultProfile = "" } }
            refreshBrowserProfiles()
        }
    }

    public func clearBrowserProfile(_ id: String) {
        run("browser-profiles") { host in try await host.clearBrowserProfileData(id) } then: {}
    }

    public func importBrowserData(_ source: BrowserImportSource, cookies: Bool) {
        run("browser-import") { host in try await host.importBrowserData(from: source, cookies: cookies) } then: {}
    }

    private func refuseVoid(_ id: String, _ message: String) {
        _ = refuse(id, message)
    }

    /// Runs host work, recording its failure under `id`.
    private func run(_ id: String, _ work: @escaping (SettingsHost) async throws -> Void, then done: @escaping () -> Void) {
        guard let host else { return }
        Task { [weak self] in
            do {
                try await work(host)
                self?.errors[id] = nil
                done()
            } catch {
                self?.errors[id] = Self.message(error)
            }
            self?.changed()
        }
    }

    // MARK: Server

    /// The host reports the server's state.
    public func updateServerState(_ state: ServerConnectionState) {
        guard state != serverState else { return }
        serverState = state
        if state != .running { serverSettings = nil }
        changed()
        if state == .running { loadServerSettings() }
    }

    public func loadServerSettings() {
        guard let host, serverState == .running else { return }
        Task { [weak self] in
            do {
                let settings = try await host.readServerSettings()
                self?.serverSettings = settings
                self?.errors["server"] = nil
            } catch {
                self?.errors["server"] = Self.message(error)
            }
            self?.changed()
        }
    }

    public func connectServer() {
        host?.connectServer()
        serverState = host?.serverState ?? serverState
        changed()
    }

    /// Saves a server setting from its field or switch.
    public func setServer(_ id: String, _ value: String) {
        guard var next = serverSettings else { return }
        let text = value.trimmingCharacters(in: .whitespaces)
        switch id {
        case "default-shell":
            if text.isEmpty {
                next.defaultShell = nil
            } else {
                guard text.hasPrefix("/") else { return refuseVoid(id, "Enter the absolute path of a shell, such as /bin/zsh.") }
                next.defaultShell = ServerPath(text)
            }
        case "history-budget":
            guard let mebibytes = UInt64(text), mebibytes <= 65536 else {
                return refuseVoid(id, "Enter a whole number of MiB from 0 to 65536.")
            }
            next.historyBudgetBytes = mebibytes * 1024 * 1024
        case "shell-integration":
            next.shellIntegration = text == "true"
        default:
            return
        }
        let previous = serverSettings
        serverSettings = next
        run(id) { host in try await host.writeServerSettings(next) } then: {}
        if previous == nil { changed() }
    }

    /// Stops or restarts the server after the user confirmed.
    public func controlServer(restart: Bool) {
        guard let host else { return }
        let id = restart ? "restart-server" : "stop-server"
        serverBusy = true
        changed()
        Task { [weak self] in
            do {
                if restart { try await host.restartServer() } else { try await host.stopServer() }
                self?.errors[id] = nil
            } catch {
                self?.errors[id] = Self.message(error)
            }
            guard let self else { return }
            serverBusy = false
            updateServerState(host.serverState)
            changed()
        }
    }

    // MARK: Mobile

    /// The host reports a `remoteAccess` change.
    public func updateRemoteAccess(_ state: RemoteAccessState?) {
        remoteAccess = state
        if state?.pairingExpiresAt == nil { pairing = nil }
        changed()
    }

    public func loadRemoteAccess() {
        guard let host, serverState == .running else { return }
        Task { [weak self] in
            do {
                self?.remoteAccess = try await host.readRemoteAccess()
                self?.errors["mobile-access"] = nil
            } catch {
                self?.errors["mobile-access"] = Self.message(error)
            }
            self?.changed()
        }
    }

    public func setMobileEnabled(_ enabled: Bool) {
        guard var settings = remoteAccess?.settings else { return }
        settings.enabled = enabled
        writeRemoteAccess("mobile-access", settings)
    }

    public func setMobilePort(_ text: String) {
        guard var settings = remoteAccess?.settings else { return }
        guard let port = UInt16(text.trimmingCharacters(in: .whitespaces)), port >= 1024 else {
            return refuseVoid("mobile-port", "Enter a port from 1024 to 65535.")
        }
        settings.port = port
        writeRemoteAccess("mobile-port", settings)
    }

    private func writeRemoteAccess(_ id: String, _ settings: RemoteAccessSettings) {
        mobileBusy = true
        changed()
        run(id) { host in try await host.writeRemoteAccess(settings) } then: { [weak self] in
            self?.mobileBusy = false
            self?.loadRemoteAccess()
        }
    }

    public func startPairing() {
        guard let host else { return }
        mobileBusy = true
        changed()
        Task { [weak self] in
            do {
                self?.pairing = try await host.startPairing()
                self?.errors["mobile-pair"] = nil
            } catch {
                self?.errors["mobile-pair"] = Self.message(error)
            }
            self?.mobileBusy = false
            self?.changed()
        }
    }

    public func cancelPairing() {
        pairing = nil
        changed()
        guard let host else { return }
        Task { await host.cancelPairing() }
    }

    public func revokeDevice(_ device: DeviceId) {
        run("mobile-devices") { host in try await host.revokeDevice(device) } then: { [weak self] in
            self?.loadRemoteAccess()
        }
    }

    // MARK: AI

    /// Chooses the tool for an action; empty means Auto.
    public func setAIProvider(_ action: AIAction, _ provider: String) {
        attempt(action.providerSetting) {
            settings.ai = try Settings.saveAIEntry(
                in: dirs.settings, table: "providers", key: action.rawValue, value: provider.isEmpty ? nil : provider
            )
            applySettings()
        }
    }

    /// Saves an action's prompt; the default prompt or an empty one is
    /// stored as no prompt.
    public func setAIPrompt(_ action: AIAction, _ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty || trimmed == action.defaultPrompt ? nil : trimmed
        attempt(action.promptSetting) {
            settings.ai = try Settings.saveAIEntry(in: dirs.settings, table: "prompts", key: action.rawValue, value: value)
            applySettings()
        }
    }

    public func prompt(_ action: AIAction) -> String {
        let saved = settings.ai.prompts[action.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? action.defaultPrompt : saved
    }

    /// The pull request prompt saved for `project`, empty when it uses the
    /// general one.
    public func projectPRPrompt(_ project: String) -> String {
        settings.ai.projectPrPrompts[project]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Saves `project`'s own pull request prompt; an empty one goes back to
    /// the general prompt.
    public func setProjectPRPrompt(_ project: String, _ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        attempt("ai-project-pr-prompt") {
            settings.ai = try Settings.saveAIEntry(
                in: dirs.settings, table: "projectPrPrompts", key: project, value: trimmed.isEmpty ? nil : trimmed
            )
            applySettings()
        }
    }

    public func setCommitChoices(_ choices: CommitChoices) {
        attempt("ai-commit-include-unstaged") {
            settings.ai = try Settings.saveCommitChoices(choices, in: dirs.settings)
            applySettings()
        }
    }

    // MARK: Backup

    /// Writes a backup of the profile to `url`.
    public func exportBackup(to url: URL) {
        attempt("backup-export") {
            let state = try host?.backupState()
            try BackupArchive.collect(from: dirs, state: state).write(to: url)
            backupStatus = "Backup exported."
        }
    }

    /// Reads a chosen backup and stages it for the next launch.
    public func restoreBackup(from url: URL) {
        attempt("backup-restore") {
            let archive = try BackupArchive.read(url)
            try archive.stage(in: dirs)
            backupStatus = archive.summary + " Quit and reopen Tab to restore it."
        }
    }

    public var hasPendingRestore: Bool { BackupArchive.hasPending(dirs) }

    public func cancelRestore() {
        attempt("backup-restore") {
            try BackupArchive.cancelPending(dirs)
            backupStatus = "Import cancelled."
        }
    }

    // MARK: Files

    /// Opens a configuration file in the default editor, creating it first
    /// when missing.
    public func openConfiguration(_ name: String) {
        let url = dirs.root.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            switch name {
            case "terminal.json": try? terminal.save(to: url)
            case "settings.json": _ = try? Settings.load(url)
            default: break
            }
        }
        host?.openConfigurationFile(url)
    }
}
