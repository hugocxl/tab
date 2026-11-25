import AppKit
import Combine
import struct SwiftUI.AnyView
import TabClient
import TabCore
import TabProtocol

/// The Settings window's model: the app's preferences as saved in the
/// profile, the server's and mobile access's settings read through the host,
/// and the problems to show beside each row. Every change is validated,
/// saved at once and passed to the host to apply. The app keeps one store
/// for its whole life.
@MainActor
public final class SettingsStore {
    public let dirs: TabDirs
    public weak var host: SettingsHost?
    public let theme: AppTheme

    public private(set) var settings: Settings
    public private(set) var terminal: TerminalSettings
    /// Problems by row id; `application` and `configuration` are page-wide.
    public private(set) var errors: [String: String] = [:]

    public var serverVersion: String? { serverState == .running ? host?.serverVersion : nil }

    public private(set) var serverState: ServerConnectionState
    public private(set) var serverSettings: ServerSettingsDoc?
    public private(set) var updaterSummary: UpdaterSummary
    public var serverRestarting: Bool { host?.serverRestarting ?? false }
    public var serverBusy: Bool { serverControlBusy || serverRestarting }
    private var serverControlBusy = false
    private struct ServerDetails: Equatable {
        var version: String?
        var restarting: Bool
        var canRestart: Bool
        var failure: String?
    }
    private var lastServerDetails: ServerDetails?

    public private(set) var remoteAccess: RemoteAccessState?
    public private(set) var pairing: PairingOffer?
    public private(set) var pairingBusy = false
    public private(set) var mobileBusy = false
    public private(set) var backupBusy = false
    public private(set) var backupStatus = ""
    public private(set) var browserProfiles: [BrowserProfileSummary] = []
    /// Per-provider Tab integration status (skill and hooks), by provider ID.
    public private(set) var providerIntegrations: [String: AgentIntegrationStatus] = [:]
    public private(set) var providerIntegrationBusy: Set<String> = []
    /// The computer whose coding agents Settings › Agents shows: this Mac or a remote server.
    public private(set) var agentComputer: ServerId = .local
    /// `agentComputer`'s coding agents; `nil` until read.
    public private(set) var agentProviders: AgentProvidersState?
    /// This Mac's providers while another computer's are shown, to copy from; `nil` until read.
    public private(set) var localAgentProviders: [AgentProviderConfig]?
    private var lastAgentComputers: [AgentComputer] = []
    /// Each provider's models as Settings lists them, hidden ones included, by provider ID.
    public private(set) var agentModels: [String: [AgentModelDescriptor]] = [:]
    /// Providers whose model list couldn't be read.
    public private(set) var agentModelsUnavailable: Set<String> = []
    public private(set) var checkingAgentProviders = false
    /// Runs another check when the current one finishes, so providers added or copied mid-check are checked too.
    private var recheckAgentProviders = false
    private var agentProviderWrite: Task<Void, Never>?
    private var maintenanceFollower: Task<Void, Never>?
    /// Counts edits, so a read that started before one doesn't replace it.
    private var agentProviderEdits = 0

    /// Fires after anything the window shows changed.
    public let changes = PassthroughSubject<Void, Never>()
    private var serverWrite: Task<Void, Never>?
    private var pairingRevision = 0

    /// Loads `settings.json` and `terminal.json` from `dirs`. A file that
    /// does not load leaves the defaults in place and its problem on the page.
    public init(dirs: TabDirs, host: SettingsHost?, theme: AppTheme? = nil) {
        self.dirs = dirs
        self.host = host
        self.theme = theme ?? .shared
        serverState = host?.serverState ?? .stopped
        updaterSummary = host?.updaterSummary ?? UpdaterSummary(detail: "\(Release.appName) \(Release.version)")
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

    public func updateUpdaterSummary(_ summary: UpdaterSummary) {
        guard summary != updaterSummary else { return }
        updaterSummary = summary
        changed()
    }

    public func setAutomaticDownloads(_ enabled: Bool) {
        attempt("update-auto-download") {
            var next = settings
            next.updates.automaticDownloads = enabled
            if !enabled { next.updates.automaticInstall = false }
            try next.saveUpdates(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    public func setAutomaticInstall(_ enabled: Bool) {
        attempt("update-auto-install") {
            var next = settings
            next.updates.automaticInstall = enabled
            if enabled { next.updates.automaticDownloads = true }
            try next.saveUpdates(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    public func performUpdaterAction(_ action: UpdaterSummary.Action) {
        host?.performUpdaterAction(action)
        if let summary = host?.updaterSummary { updateUpdaterSummary(summary) }
    }

    public func scheduleRelaunchWhenIdle() {
        host?.scheduleRelaunchWhenIdle()
        if let summary = host?.updaterSummary { updateUpdaterSummary(summary) }
    }

    // MARK: Integrations

    /// Reads what Tab installed in `provider`'s config folder.
    public func loadAgentProviderIntegration(_ provider: AgentProviderConfig) {
        changeAgentProviderIntegration(provider, enable: nil)
    }

    /// Installs or removes Tab's skill and hooks in `provider`'s config folder.
    public func setAgentProviderIntegration(_ provider: AgentProviderConfig, enabled: Bool) {
        changeAgentProviderIntegration(provider, enable: enabled)
    }

    private func changeAgentProviderIntegration(_ provider: AgentProviderConfig, enable: Bool?) {
        let id = provider.id
        guard !providerIntegrationBusy.contains(id), let host else { return }
        providerIntegrationBusy.insert(id)
        changed()
        Task { [weak self] in
            do {
                let status = if let enable {
                    try await host.setAgentProviderIntegration(provider, enabled: enable)
                } else {
                    try await host.agentProviderIntegration(provider)
                }
                if let status { self?.providerIntegrations[id] = status }
                else { self?.providerIntegrations[id] = nil }
                self?.errors["agent-provider-integration"] = nil
            } catch {
                self?.errors["agent-provider-integration"] = Self.message(error)
            }
            self?.providerIntegrationBusy.remove(id)
            self?.changed()
        }
    }

    // MARK: Agent providers

    /// This Mac, then each remote server.
    public var agentComputers: [AgentComputer] { host?.agentComputers ?? [] }

    /// The shown computer's name, such as "This Mac".
    public var agentComputerName: String {
        agentComputers.first { $0.id == agentComputer }?.name ?? "This Mac"
    }

    /// Whether the shown computer's server is connected.
    public var agentComputerConnected: Bool {
        agentComputer.isLocal ? serverState == .running : agentComputers.first { $0.id == agentComputer }?.connected == true
    }

    /// Shows `server`'s providers instead, dropping what was read from the other computer.
    public func selectAgentComputer(_ server: ServerId) {
        guard server != agentComputer, server.isLocal || agentComputers.contains(where: { $0.id == server }) else { return }
        agentComputer = server
        agentProviders = nil
        localAgentProviders = nil
        agentModels = [:]
        agentModelsUnavailable = []
        providerIntegrations = [:]
        checkingAgentProviders = false
        recheckAgentProviders = false
        maintenanceFollower?.cancel()
        maintenanceFollower = nil
        agentProviderEdits += 1
        for key in errors.keys where key.hasPrefix("agent-") { errors[key] = nil }
        changed()
        loadAgentProviders(check: true)
    }

    /// Reads the shown computer's providers again when its connection changed, such as
    /// a remote server that connected while Settings showed it.
    public func agentComputersChanged() {
        let computers = agentComputers
        guard computers != lastAgentComputers else { return }
        lastAgentComputers = computers
        if !agentComputer.isLocal, !computers.contains(where: { $0.id == agentComputer }) {
            return selectAgentComputer(.local)
        }
        if agentProviders == nil, agentComputerConnected { loadAgentProviders(check: true) }
        changed()
    }

    /// Reads the providers, then checks their status automatically when `check` is true.
    /// Another computer's server is asked even when it isn't connected, which connects it.
    public func loadAgentProviders(check: Bool = true) {
        guard let host, !agentComputer.isLocal || serverState == .running else { return }
        let edits = agentProviderEdits
        let server = agentComputer
        if !server.isLocal, serverState == .running {
            Task { [weak self] in
                let local = try? await host.agentProviders(on: .local)
                guard let self, agentComputer == server else { return }
                localAgentProviders = local?.settings.providers ?? []
                changed()
            }
        }
        Task { [weak self] in
            do {
                let state = try await host.agentProviders(on: server)
                guard let self, self.agentComputer == server else { return }
                self.acceptAgentProviders(state, editsAtStart: edits)
                self.errors["agent-providers"] = nil
                if check, state.settings.providers.contains(where: \.enabled) {
                    self.checkAgentProviders()
                }
            } catch {
                guard self?.agentComputer == server else { return }
                self?.errors["agent-providers"] = self?.agentProvidersMessage(error)
            }
            self?.changed()
        }
    }

    /// Takes the server's providers, keeping local edits made since the read began.
    private func acceptAgentProviders(_ state: AgentProvidersState, editsAtStart: Int) {
        guard editsAtStart != agentProviderEdits, let local = agentProviders else {
            agentProviders = state
            return
        }
        agentProviders = AgentProvidersState(settings: local.settings, health: state.health,
                                             maintenance: state.maintenance, kinds: state.kinds)
    }

    /// Checks every enabled provider's CLI version and sign-in.
    public func checkAgentProviders() {
        guard let host else { return }
        if checkingAgentProviders {
            recheckAgentProviders = true
            return
        }
        checkingAgentProviders = true
        recheckAgentProviders = false
        changed()
        let edits = agentProviderEdits
        let server = agentComputer
        Task { [weak self] in
            do {
                let state = try await host.checkAgentProviders(on: server)
                guard self?.agentComputer == server else { return }
                self?.acceptAgentProviders(state, editsAtStart: edits)
                self?.errors["agent-providers"] = nil
            } catch {
                guard self?.agentComputer == server else { return }
                self?.errors["agent-providers"] = self?.agentProvidersMessage(error)
            }
            guard let self, agentComputer == server else { return }
            checkingAgentProviders = false
            let recheck = recheckAgentProviders
            recheckAgentProviders = false
            changed()
            if recheck { checkAgentProviders() }
        }
    }

    /// Installs or updates `id`'s CLI on the server, then reads the providers until it finishes.
    public func maintainAgentProvider(_ id: String, action: AgentProviderMaintenance.Action) {
        guard let host else { return }
        let edits = agentProviderEdits
        let server = agentComputer
        Task { [weak self] in
            do {
                let state = try await host.maintainAgentProvider(id, action: action, on: server)
                guard self?.agentComputer == server else { return }
                self?.acceptAgentProviders(state, editsAtStart: edits)
                self?.errors["agent-provider-version"] = nil
                self?.followMaintenance()
            } catch {
                guard self?.agentComputer == server else { return }
                self?.errors["agent-provider-version"] = self?.agentProvidersMessage(error)
            }
            self?.changed()
        }
    }

    /// Reads the providers every second and a half while an install or update runs.
    private func followMaintenance() {
        guard maintenanceFollower == nil, let host else { return }
        let server = agentComputer
        maintenanceFollower = Task { [weak self] in
            defer { self?.maintenanceFollower = nil }
            while self?.agentProviders?.maintenance.contains(where: \.isRunning) == true {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled else { return }
                let edits = agentProviderEdits
                guard let state = try? await host.agentProviders(on: server), agentComputer == server else { return }
                acceptAgentProviders(state, editsAtStart: edits)
                changed()
            }
            // The CLI may list other models now, and report usage where it was missing.
            guard let self else { return }
            for id in agentModels.keys { loadAgentModels(id) }
            host.agentProvidersDidChange(on: server)
        }
    }

    /// Lists `id`'s models, asking its CLI again when `refresh`.
    public func loadAgentModels(_ id: String, refresh: Bool = false) {
        guard let host, let provider = agentProviders?.settings.provider(id) else { return }
        let server = agentComputer
        Task { [weak self] in
            do {
                let models = try await host.agentModels(provider, refresh: refresh, on: server)
                guard self?.agentComputer == server else { return }
                self?.agentModels[id] = models
                self?.agentModelsUnavailable.remove(id)
            } catch {
                guard self?.agentComputer == server else { return }
                self?.agentModelsUnavailable.insert(id)
            }
            self?.changed()
        }
    }

    /// Orders `id`'s listed models by its preferences at once, leaving out a
    /// removed custom model, then lists them again once the change is saved.
    public func rearrangeAgentModels(_ id: String, removing removed: String? = nil) {
        guard let preferences = agentProviders?.settings.provider(id)?.models, let models = agentModels[id] else { return }
        agentModels[id] = preferences.arrange(models.filter { $0.id != removed })
        changed()
        let write = agentProviderWrite
        Task { [weak self] in
            await write?.value
            self?.loadAgentModels(id)
        }
    }

    /// Changes one provider, recording a refusal under `row`.
    public func updateAgentProvider(_ id: String, row: String, _ change: @escaping (inout AgentProviderConfig) -> Void) {
        updateAgentProviders(row) { settings in
            guard let index = settings.providers.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.providers[index])
        }
    }

    /// Adds a provider of `kind` and returns its ID.
    /// What the server finds for `provider`, saved or not; nil when it can't check one it hasn't saved.
    public func probeAgentProvider(_ provider: AgentProviderConfig) async -> AgentProviderHealth? {
        guard let host, agentComputerConnected else { return nil }
        return try? await host.probeAgentProvider(provider, on: agentComputer)
    }

    @discardableResult
    /// Whether another provider fits; sets the list's error when it doesn't.
    public func canAddAgentProvider() -> Bool {
        guard let settings = agentProviders?.settings else { return false }
        guard settings.providers.count < AgentProviderSettings.maxProviders else {
            setError("agent-providers", "Remove a provider before adding another.")
            return false
        }
        return true
    }

    /// Adds `provider` as the Add Provider dialog made it; nil when it can't be added.
    /// When `integrate` is true and the provider's kind supports Tab integration, installs
    /// Tab's skill and hooks into the provider's config folder.
    public func addAgentProvider(_ provider: AgentProviderConfig, integrate: Bool = true) -> String? {
        guard canAddAgentProvider(), agentProviders?.settings.provider(provider.id) == nil else { return nil }
        updateAgentProviders("agent-providers") { $0.providers.append(provider) }
        guard agentProviders?.settings.provider(provider.id) != nil else { return nil }
        // Tab's skill and hooks are installed from this Mac, so only into its own config folders.
        if integrate, agentComputer.isLocal, CodingAgent(provider: provider.kind) != nil {
            setAgentProviderIntegration(provider, enabled: true)
        }
        let write = agentProviderWrite
        Task { [weak self] in
            await write?.value
            self?.checkAgentProviders()
        }
        return provider.id
    }

    public func removeAgentProvider(_ id: String) {
        updateAgentProviders("agent-providers") { settings in
            settings.providers.removeAll { $0.id == id }
        }
        agentModels[id] = nil
        providerIntegrations[id] = nil
        errors["agent-provider-integration"] = nil
    }

    /// Applies `change` at once and saves it on the server after any earlier
    /// save, so quick edits arrive in order; a refused one reloads the server's.
    public func updateAgentProviders(_ row: String, _ change: @escaping (inout AgentProviderSettings) -> Void) {
        guard var state = agentProviders, let host else { return }
        var next = state.settings
        change(&next)
        do {
            try next.validate()
        } catch {
            return setError(row, "That value isn't allowed here.")
        }
        state.settings = next
        agentProviders = state
        agentProviderEdits += 1
        errors[row] = nil
        changed()
        let previous = agentProviderWrite
        let server = agentComputer
        let snapshot = next
        agentProviderWrite = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let saved = try await host.writeAgentProviders(snapshot, on: server)
                if agentComputer == server, agentProviders?.settings == snapshot {
                    agentProviders?.health = saved.health
                    agentProviders?.maintenance = saved.maintenance
                }
            } catch {
                guard agentComputer == server else { return }
                errors[row] = agentProvidersMessage(error)
                if let state = try? await host.agentProviders(on: server), agentComputer == server { agentProviders = state }
            }
            if agentComputer == server { changed() }
        }
    }

    /// This Mac's providers the shown computer lacks, by ID, which `copyAgentProviders` can add.
    public var copyableAgentProviders: [AgentProviderConfig] {
        guard !agentComputer.isLocal, let local = localAgentProviders, let shown = agentProviders?.settings else { return [] }
        return local.filter { shown.provider($0.id) == nil }
    }

    /// Adds this Mac's providers `ids` to the shown computer, with folders under this Mac's
    /// home written from `~` so they name the same folders in the other computer's home.
    /// Its CLIs are then checked there, as they may be missing.
    public func copyAgentProviders(_ ids: [String]) {
        let copies = copyableAgentProviders.filter { ids.contains($0.id) }.map { Self.portable($0) }
        guard !copies.isEmpty, let settings = agentProviders?.settings else { return }
        guard settings.providers.count + copies.count <= AgentProviderSettings.maxProviders else {
            return setError("agent-providers", "Remove a provider before copying more.")
        }
        updateAgentProviders("agent-providers") { $0.providers += copies }
        let write = agentProviderWrite
        Task { [weak self] in
            await write?.value
            self?.checkAgentProviders()
        }
    }

    /// `provider` prepared for another computer: paths under this Mac's home written from `~`,
    /// and a standard CLI path (such as `/opt/homebrew/bin/agy`) dropped so the other computer
    /// finds the CLI on its own `PATH` (for example `~/.local/bin/agy`).
    static func portable(_ provider: AgentProviderConfig, home: String = NSHomeDirectory()) -> AgentProviderConfig {
        func portable(_ path: String?) -> String? {
            guard let path else { return nil }
            return TabDirs.abbreviateHome(path, home: home) ?? path
        }
        var copy = provider
        if let exec = provider.executable?.trimmingCharacters(in: .whitespacesAndNewlines),
           let defaultName = provider.kind.spec.executable, !defaultName.isEmpty,
           (exec as NSString).lastPathComponent == defaultName {
            copy.executable = nil
        } else {
            copy.executable = portable(provider.executable)
        }
        copy.home = portable(provider.home)
        copy.shadowHome = portable(provider.shadowHome)
        return copy
    }

    private func agentProvidersMessage(_ error: Error) -> String {
        if case ClientError.server(let reply) = error, reply.code == .unsupported {
            return agentComputer.isLocal
                ? "This Mac's server is older than this app. Restart it from Settings › Server to manage providers."
                : "\(agentComputerName) runs an older Tab. Update it from Settings › Remote Servers to manage its providers."
        }
        return Self.message(error)
    }

    // MARK: Appearance

    /// Changes appearance settings, saving only what changed so the main
    /// window's own saves in between are kept.
    public func updateAppearance(_ id: String, _ change: (inout Appearance) -> Void) {
        attempt(id) {
            var next = settings.appearance
            change(&next)
            settings.appearance = try next.saveChanges(since: settings.appearance, to: dirs.settings)
            theme.setInterface(settings.appearance)
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
            if let other = settings.keymap.conflict(for: id, chord: chord), other != id {
                return refuse(id, "\(chord.display) is already used by \(ShortcutCatalog.find(other)?.label ?? other).")
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

    // MARK: Terminal

    /// Changes terminal preferences and saves them, recording a refusal
    /// under the row `id`.
    public func updateTerminal(_ id: String, _ change: (inout TerminalSettings) -> Void) {
        attempt(id) {
            var next = terminal
            change(&next)
            guard next != terminal else { return }
            try next.save(to: dirs.terminalSettings)
            terminal = next
            host?.terminalSettingsDidChange(next)
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

    public func updateAgents(_ id: String, _ change: (inout AgentSettings) -> Void) {
        attempt(id) {
            var next = settings
            change(&next.agents)
            try next.saveAgents(to: dirs.settings)
            settings = next
            applySettings()
        }
    }

    public func updateNotifications(_ id: String, _ change: (inout NotificationSettings) -> Void) {
        attempt(id) {
            var next = settings
            change(&next.notifications)
            try next.saveNotifications(to: dirs.settings)
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
        let details = ServerDetails(version: host?.serverVersion, restarting: serverRestarting,
                                    canRestart: host?.canRestartServer ?? false, failure: host?.serverRestartFailure)
        let detailsChanged = details != lastServerDetails
        lastServerDetails = details
        guard state != serverState else {
            if detailsChanged { changed() }
            return
        }
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
        guard let current = serverSettings, let host else { return }
        do {
            _ = try Self.serverSetting(current, id: id, value: value)
        } catch {
            return refuseVoid(id, Self.message(error))
        }
        let previous = serverWrite
        serverWrite = Task { [weak self] in
            await previous?.value
            guard let self, serverState == .running, let current = serverSettings else { return }
            do {
                let next = try Self.serverSetting(current, id: id, value: value)
                try await host.writeServerSettings(next)
                serverSettings = next
                errors[id] = nil
            } catch {
                errors[id] = Self.message(error)
            }
            changed()
        }
    }

    private static func commandArguments(_ text: String) throws -> [String] {
        do {
            return try Executable.commandArguments(text)
        } catch {
            throw SettingsError("startup-command", "\(error)")
        }
    }

    /// Applies one field to the last settings accepted by the server, so
    /// queued edits cannot overwrite each other or retain a failed edit.
    private static func serverSetting(_ current: ServerSettingsDoc, id: String, value: String) throws -> ServerSettingsDoc {
        var next = current
        let text = value.trimmingCharacters(in: .whitespaces)
        switch id {
        case "startup-command":
            next.startupCommand = text.isEmpty ? [] : try Self.commandArguments(text)
        default:
            throw SettingsError(id, "Unknown server setting.")
        }
        try next.validate()
        return next
    }

    /// Stops or restarts the server after the user confirmed.
    public func controlServer(restart: Bool) {
        guard let host else { return }
        let id = restart ? "restart-server" : "stop-server"
        guard !serverBusy else { return }
        serverControlBusy = true
        changed()
        Task { [weak self] in
            do {
                if restart { try await host.restartServer() } else { try await host.stopServer() }
                self?.errors[id] = nil
            } catch {
                self?.errors[id] = Self.message(error)
            }
            guard let self else { return }
            serverControlBusy = false
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
        guard !mobileBusy else { return }
        guard var settings = remoteAccess?.settings else { return }
        settings.enabled = enabled
        writeRemoteAccess("mobile-access", settings)
    }

    public func setMobileKeepAwake(_ keepAwake: Bool) {
        guard !mobileBusy else { return }
        guard var settings = remoteAccess?.settings else { return }
        settings.allowsSleep = !keepAwake
        writeRemoteAccess("mobile-keep-awake", settings)
    }

    public func setMobilePort(_ text: String) {
        guard !mobileBusy else { return }
        guard var settings = remoteAccess?.settings else { return }
        guard let port = UInt16(text.trimmingCharacters(in: .whitespaces)), port >= 1024 else {
            return refuseVoid("mobile-port", "Enter a port from 1024 to 65535.")
        }
        settings.port = port
        writeRemoteAccess("mobile-port", settings)
    }

    private func writeRemoteAccess(_ id: String, _ settings: RemoteAccessSettings) {
        guard let host else { return }
        mobileBusy = true
        changed()
        Task { [weak self] in
            do {
                try await host.writeRemoteAccess(settings)
                self?.remoteAccess = try await host.readRemoteAccess()
                self?.errors[id] = nil
            } catch {
                self?.errors[id] = Self.message(error)
            }
            self?.mobileBusy = false
            self?.changed()
        }
    }

    public func startPairing() {
        guard let host, !mobileBusy else { return }
        pairingRevision += 1
        let revision = pairingRevision
        pairingBusy = true
        mobileBusy = true
        changed()
        Task { [weak self] in
            guard self?.pairingRevision == revision else { return }
            do {
                let offer = try await host.startPairing()
                guard self?.pairingRevision == revision else { return }
                self?.pairing = offer
                self?.errors["mobile-pair"] = nil
            } catch {
                guard self?.pairingRevision == revision else { return }
                self?.errors["mobile-pair"] = Self.message(error)
            }
            self?.pairingBusy = false
            self?.mobileBusy = false
            self?.changed()
        }
    }

    public func cancelPairing() {
        pairingRevision += 1
        if pairingBusy { mobileBusy = false }
        pairingBusy = false
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

    // MARK: Plugins

    public func pluginState(_ id: PluginId) -> PluginInstallState {
        host?.pluginState(id) ?? .notInstalled
    }

    public func pluginsDidChange() {
        changed()
    }

    public func installPlugin(_ id: PluginId) {
        let key = "plugin.\(id.rawValue)"
        errors[key] = nil
        changed()
        Task { [weak self] in
            guard let self, let host = self.host else { return }
            do {
                try await host.installPlugin(id)
                self.errors[key] = nil
            } catch {
                self.errors[key] = Self.message(error)
            }
            self.changed()
        }
    }

    public func uninstallPlugin(_ id: PluginId) {
        let key = "plugin.\(id.rawValue)"
        attempt(key) {
            try host?.uninstallPlugin(id)
        }
    }

    public func hasPluginSettings(_ id: PluginId) -> Bool {
        host?.hasPluginSettings(id) ?? false
    }

    public func pluginSettingsView(for id: PluginId) -> AnyView? {
        host?.pluginSettingsView(for: id, store: self)
    }

    public func pluginConfig<T: Decodable>(_ type: T.Type, for id: PluginId) -> T? {
        settings.plugins.decodeConfig(type, for: id)
    }

    public func updatePluginConfig<T: Encodable>(_ id: PluginId, _ value: T) {
        let key = "plugin.\(id.rawValue).config"
        attempt(key) {
            var next = settings
            try next.plugins.encodeConfig(value, for: id)
            try next.savePlugins(to: dirs.settings)
            settings = next
            applySettings()
        }
    }
}
