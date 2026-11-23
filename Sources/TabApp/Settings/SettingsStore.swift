import AppKit
import Combine
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
    /// What Tab installed for each coding agent; `nil` until read.
    public private(set) var agentIntegrations: [AgentIntegrationStatus]?
    public private(set) var agentIntegrationBusy = false
    /// This Mac's server's coding agents; `nil` until read.
    public private(set) var agentProviders: AgentProvidersState?
    /// Each provider's models as Settings lists them, hidden ones included, by provider ID.
    public private(set) var agentModels: [String: [AgentModelDescriptor]] = [:]
    /// Providers whose model list couldn't be read.
    public private(set) var agentModelsUnavailable: Set<String> = []
    public private(set) var checkingAgentProviders = false
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

    /// Reads what Tab installed for each coding agent.
    public func loadAgentIntegrations() {
        changeAgentIntegrations(nil)
    }

    /// Installs or removes the skill and hooks of every agent found.
    public func setAgentIntegration(_ enabled: Bool) {
        changeAgentIntegrations(enabled)
    }

    private func changeAgentIntegrations(_ enable: Bool?) {
        guard !agentIntegrationBusy, let host else { return }
        agentIntegrationBusy = true
        changed()
        Task { [weak self] in
            do {
                let statuses = if let enable {
                    try await host.setAgentIntegration(enable)
                } else {
                    try await host.agentIntegrations()
                }
                self?.agentIntegrations = statuses
                self?.errors["agent-integration"] = nil
            } catch {
                self?.errors["agent-integration"] = Self.message(error)
            }
            self?.agentIntegrationBusy = false
            self?.changed()
        }
    }

    // MARK: Agent providers

    /// Reads the providers, then checks them again when the last check is
    /// older than the server's interval.
    public func loadAgentProviders() {
        guard let host, serverState == .running else { return }
        let edits = agentProviderEdits
        Task { [weak self] in
            do {
                let state = try await host.agentProviders()
                guard let self else { return }
                self.acceptAgentProviders(state, editsAtStart: edits)
                self.errors["agent-providers"] = nil
                if self.needsCheck(state) { self.checkAgentProviders() }
            } catch {
                self?.errors["agent-providers"] = Self.agentProvidersMessage(error)
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

    private func needsCheck(_ state: AgentProvidersState) -> Bool {
        let interval = TimeInterval(state.settings.healthCheckInterval)
        return state.settings.providers.contains { provider in
            guard provider.enabled else { return false }
            guard let checked = state.health(provider.id)?.checkedAt else { return true }
            return interval > 0 && Date().timeIntervalSince(checked) > interval
        }
    }

    /// Checks every enabled provider's CLI version and sign-in.
    public func checkAgentProviders() {
        guard let host, !checkingAgentProviders else { return }
        checkingAgentProviders = true
        changed()
        let edits = agentProviderEdits
        Task { [weak self] in
            do {
                let state = try await host.checkAgentProviders()
                self?.acceptAgentProviders(state, editsAtStart: edits)
                self?.errors["agent-providers"] = nil
            } catch {
                self?.errors["agent-providers"] = Self.agentProvidersMessage(error)
            }
            self?.checkingAgentProviders = false
            self?.changed()
        }
    }

    /// Installs or updates `id`'s CLI on the server, then reads the providers until it finishes.
    public func maintainAgentProvider(_ id: String, action: AgentProviderMaintenance.Action) {
        guard let host else { return }
        let edits = agentProviderEdits
        Task { [weak self] in
            do {
                let state = try await host.maintainAgentProvider(id, action: action)
                self?.acceptAgentProviders(state, editsAtStart: edits)
                self?.errors["agent-provider-version"] = nil
                self?.followMaintenance()
            } catch {
                self?.errors["agent-provider-version"] = Self.agentProvidersMessage(error)
            }
            self?.changed()
        }
    }

    /// Reads the providers every second and a half while an install or update runs.
    private func followMaintenance() {
        guard maintenanceFollower == nil, let host else { return }
        maintenanceFollower = Task { [weak self] in
            defer { self?.maintenanceFollower = nil }
            while self?.agentProviders?.maintenance.contains(where: \.isRunning) == true {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled else { return }
                let edits = agentProviderEdits
                guard let state = try? await host.agentProviders() else { return }
                acceptAgentProviders(state, editsAtStart: edits)
                changed()
            }
            // The CLI may list other models now.
            guard let self else { return }
            for id in agentModels.keys { loadAgentModels(id) }
        }
    }

    /// Lists `id`'s models, asking its CLI again when `refresh`.
    public func loadAgentModels(_ id: String, refresh: Bool = false) {
        guard let host, let provider = agentProviders?.settings.provider(id) else { return }
        Task { [weak self] in
            do {
                self?.agentModels[id] = try await host.agentModels(provider, refresh: refresh)
                self?.agentModelsUnavailable.remove(id)
            } catch {
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
    @discardableResult
    public func addAgentProvider(_ kind: AgentChatProvider) -> String? {
        guard let settings = agentProviders?.settings, settings.providers.count < AgentProviderSettings.maxProviders else {
            setError("agent-providers", "Remove a provider before adding another.")
            return nil
        }
        let id = settings.newID(kind)
        let count = settings.providers.filter { $0.kind == kind }.count
        updateAgentProviders("agent-providers") { settings in
            settings.providers.append(AgentProviderConfig(id: id, kind: kind, name: "\(kind.name) \(count + 1)"))
        }
        return id
    }

    public func removeAgentProvider(_ id: String) {
        updateAgentProviders("agent-providers") { settings in
            settings.providers.removeAll { $0.id == id && !$0.isBuiltIn }
        }
        agentModels[id] = nil
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
        agentProviderWrite = Task { [weak self] in
            await previous?.value
            guard let self, let current = agentProviders?.settings else { return }
            do {
                let saved = try await host.writeAgentProviders(current)
                if agentProviders?.settings == current {
                    agentProviders?.health = saved.health
                    agentProviders?.maintenance = saved.maintenance
                }
            } catch {
                errors[row] = Self.agentProvidersMessage(error)
                if let state = try? await host.agentProviders() { agentProviders = state }
            }
            changed()
        }
    }

    private static func agentProvidersMessage(_ error: Error) -> String {
        if case ClientError.server(let reply) = error, reply.code == .unsupported {
            return "This Mac's server is older than this app. Restart it from Settings › Server to manage providers."
        }
        return message(error)
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
}
