import Foundation
import TabClient
import TabCore
import TabProtocol

/// Whether the local server is reachable, as the Settings sidebar tile shows.
public enum ServerConnectionState: Equatable, Sendable {
    case connecting
    case running
    case stopped

    public var title: String {
        switch self {
        case .connecting: return "Connecting…"
        case .running: return "Running"
        case .stopped: return "Stopped"
        }
    }
}

/// A browser profile as Settings lists it.
public struct BrowserProfileSummary: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Another browser's profile on this Mac that can be imported.
public struct BrowserImportSource: Equatable, Sendable {
    /// Such as "Safari" or "Chrome — Work".
    public var name: String
    /// Whether its cookies (sign-ins) can be imported too.
    public var supportsCookies: Bool

    public init(name: String, supportsCookies: Bool) {
        self.name = name
        self.supportsCookies = supportsCookies
    }
}

/// What Settings needs from the rest of the app: the server, mobile access,
/// browser profiles and the app model. Settings reads and writes
/// `settings.json` and `terminal.json` itself and tells the host after each
/// change, so the app can apply it at once.
@MainActor
public protocol SettingsHost: AnyObject {
    // MARK: Applying preferences

    /// `settings.json` changed; apply it to the running app.
    func settingsDidChange(_ settings: Settings)
    /// `terminal.json` changed; apply it to every terminal.
    func terminalSettingsDidChange(_ settings: TerminalSettings)

    // MARK: Server

    /// The local server's state; the host calls
    /// `SettingsStore.updateServerState` when it changes.
    var serverState: ServerConnectionState { get }
    /// The connected server’s reported version, absent while disconnected.
    var serverVersion: String? { get }
    var serverRestarting: Bool { get }
    var canRestartServer: Bool { get }
    var serverRestartFailure: String? { get }
    /// Starts the local server or reconnects to it.
    func connectServer()
    func readServerSettings() async throws -> ServerSettingsDoc
    func writeServerSettings(_ settings: ServerSettingsDoc) async throws
    /// Ends every session and stops the server.
    func stopServer() async throws
    /// Ends every session and starts the server again.
    func restartServer() async throws

    // MARK: Mobile

    func readRemoteAccess() async throws -> RemoteAccessState
    func writeRemoteAccess(_ settings: RemoteAccessSettings) async throws
    /// A one-time pairing offer for the server's own addresses.
    func startPairing() async throws -> PairingOffer
    func cancelPairing() async
    func revokeDevice(_ device: DeviceId) async throws

    // MARK: Browser

    func browserProfiles() -> [BrowserProfileSummary]
    func addBrowserProfile(named name: String) throws -> BrowserProfileSummary
    func renameBrowserProfile(_ id: String, to name: String) throws
    /// Deletes a profile and its data; its panes use the default profile.
    func deleteBrowserProfile(_ id: String) async throws
    /// Signs out of everything and removes the profile's cookies, cache,
    /// history and logins.
    func clearBrowserProfileData(_ id: String) async throws
    func browserImportSources() -> [BrowserImportSource]
    /// Imports history and bookmarks, or cookies, into the default profile.
    func importBrowserData(from source: BrowserImportSource, cookies: Bool) async throws

    // MARK: Privacy

    /// What macOS answered Tab, and so programs in its terminals, for `permission`.
    func privacyAccess(_ permission: PrivacyPermission) -> PrivacyAccess

    // MARK: Agents

    /// This Mac's server's coding agents and what their last checks found.
    func agentProviders() async throws -> AgentProvidersState
    func writeAgentProviders(_ settings: AgentProviderSettings) async throws -> AgentProvidersState
    /// Checks each enabled provider's CLI now.
    func checkAgentProviders() async throws -> AgentProvidersState
    /// Starts installing or updating a provider's CLI on this Mac's server.
    func maintainAgentProvider(_ id: String, action: AgentProviderMaintenance.Action) async throws -> AgentProvidersState
    /// `provider`'s models in the user's order, hidden ones included.
    func agentModels(_ provider: AgentProviderConfig, refresh: Bool) async throws -> [AgentModelDescriptor]
    /// What Tab installed for each coding agent on this computer.
    func agentIntegrations() async throws -> [AgentIntegrationStatus]
    /// Installs or removes the skill and hooks of every agent found.
    func setAgentIntegration(_ enabled: Bool) async throws -> [AgentIntegrationStatus]
    /// The terminals whose settings an agent can bring into Tab.
    func migrationSources() -> [TerminalMigration.Source]
    /// Opens an agent tab in Home with `prompt` in its composer, not yet sent.
    func openAgent(prompt: String) throws

    // MARK: Updates

    /// Current updater status and primary action for Settings → General.
    var updaterSummary: UpdaterSummary { get }
    /// Runs the updater's primary action from Settings.
    func performUpdaterAction(_ action: UpdaterSummary.Action)
    /// Arms a one-shot quiet relaunch for the ready update once Tab is hidden.
    func scheduleRelaunchWhenIdle()

    // MARK: Plugins

    /// Current installation state of a plugin.
    func pluginState(_ id: PluginId) -> PluginInstallState
    /// Installs and activates `id`.
    func installPlugin(_ id: PluginId) async throws
    /// Deactivates and removes `id` from disk.
    func uninstallPlugin(_ id: PluginId) throws

    // MARK: Backup

    /// The local projects with their layouts and workspaces, as the backup
    /// stores them (`state.json`'s configuration).
    func backupState() throws -> Data
}

public extension SettingsHost {
    var serverVersion: String? { nil }
    var serverRestarting: Bool { false }
    var canRestartServer: Bool { true }
    var serverRestartFailure: String? { nil }
    var updaterSummary: UpdaterSummary { UpdaterSummary(detail: "\(Release.appName) \(Release.version)") }
    func performUpdaterAction(_ action: UpdaterSummary.Action) {}
    func scheduleRelaunchWhenIdle() {}
    func pluginState(_ id: PluginId) -> PluginInstallState { .notInstalled }
    func installPlugin(_ id: PluginId) async throws {}
    func uninstallPlugin(_ id: PluginId) throws {}
}

/// A host with no app behind it: a running server with default settings,
/// nothing paired, one browser profile. For tests and previews.
@MainActor
public final class PreviewSettingsHost: SettingsHost {
    public var serverState: ServerConnectionState = .running
    public var serverRestarting = false
    public var serverRestartFailure: String?
    public var serverVersion: String? = Release.version
    public var serverSettings = ServerSettingsDoc()
    public var remoteAccess = RemoteAccessState(revision: 0, settings: RemoteAccessSettings(), status: .disabled)
    public var profiles = [BrowserProfileSummary(id: "", name: "Default")]
    public private(set) var appliedSettings: [Settings] = []
    public private(set) var appliedTerminal: [TerminalSettings] = []
    public private(set) var serverActions: [String] = []
    public var state: Data?
    public var importSources: [BrowserImportSource] = []
    public private(set) var agentPrompts: [String] = []
    public var integrations = CodingAgent.allCases.map {
        AgentIntegrationStatus(agent: $0, found: $0 != .pi, skill: .missing, hook: $0.supportsSessionHook ? .missing : .unsupported)
    }
    public var migrations = Array(TerminalMigration.sources.prefix(2))
    public var providers = AgentProvidersState(settings: AgentProviderSettings())
    public var reportedModels: [AgentChatProvider: [AgentModelDescriptor]] = [:]

    public init() {}

    public func settingsDidChange(_ settings: Settings) { appliedSettings.append(settings) }
    public func terminalSettingsDidChange(_ settings: TerminalSettings) { appliedTerminal.append(settings) }

    public func connectServer() { serverState = .running }
    public func readServerSettings() async throws -> ServerSettingsDoc { serverSettings }
    public func writeServerSettings(_ settings: ServerSettingsDoc) async throws { serverSettings = settings }
    public func stopServer() async throws {
        serverActions.append("stop")
        serverState = .stopped
    }
    public func restartServer() async throws { serverActions.append("restart") }

    public func readRemoteAccess() async throws -> RemoteAccessState { remoteAccess }
    public func writeRemoteAccess(_ settings: RemoteAccessSettings) async throws {
        remoteAccess.settings = settings
        remoteAccess.status = settings.enabled ? .listening : .disabled
        remoteAccess.revision += 1
    }
    public func startPairing() async throws -> PairingOffer {
        let invite = PairingInvite(hosts: ["127.0.0.1"], port: remoteAccess.settings.port, fingerprint: Data(repeating: 1, count: 32), code: Data(repeating: 2, count: 16))
        return PairingOffer(invite: invite, expiresAt: UInt64(Date().timeIntervalSince1970) + 300)
    }
    public func cancelPairing() async {}
    public func revokeDevice(_ device: DeviceId) async throws {
        remoteAccess.devices.removeAll { $0.id == device }
    }

    public func browserProfiles() -> [BrowserProfileSummary] { profiles }
    public func addBrowserProfile(named name: String) throws -> BrowserProfileSummary {
        let profile = BrowserProfileSummary(id: UUID().uuidString.lowercased(), name: name)
        profiles.append(profile)
        return profile
    }
    public func renameBrowserProfile(_ id: String, to name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
    }
    public func deleteBrowserProfile(_ id: String) async throws { profiles.removeAll { $0.id == id && !id.isEmpty } }
    public func clearBrowserProfileData(_ id: String) async throws {}
    public func browserImportSources() -> [BrowserImportSource] { importSources }
    public func importBrowserData(from source: BrowserImportSource, cookies: Bool) async throws {}

    public var privacy: [PrivacyPermission: PrivacyAccess] = [.camera: .allowed, .microphone: .denied]
    public func privacyAccess(_ permission: PrivacyPermission) -> PrivacyAccess { privacy[permission] ?? .notAsked }
    public func agentIntegrations() async throws -> [AgentIntegrationStatus] { integrations }
    public func setAgentIntegration(_ enabled: Bool) async throws -> [AgentIntegrationStatus] {
        for index in integrations.indices where integrations[index].found {
            integrations[index].skill = enabled ? .installed : .missing
            if integrations[index].agent.supportsSessionHook { integrations[index].hook = enabled ? .installed : .missing }
        }
        return integrations
    }
    public func agentProviders() async throws -> AgentProvidersState { providers }
    public func writeAgentProviders(_ settings: AgentProviderSettings) async throws -> AgentProvidersState {
        providers.settings = settings
        return providers
    }
    public func checkAgentProviders() async throws -> AgentProvidersState { providers }
    public func maintainAgentProvider(_ id: String, action: AgentProviderMaintenance.Action) async throws -> AgentProvidersState {
        providers
    }
    public func agentModels(_ provider: AgentProviderConfig, refresh: Bool) async throws -> [AgentModelDescriptor] {
        provider.models.arrange(reportedModels[provider.kind] ?? [])
    }
    public func migrationSources() -> [TerminalMigration.Source] { migrations }
    public func openAgent(prompt: String) throws { agentPrompts.append(prompt) }

    public var installedPlugins: Set<PluginId> = []
    public func pluginState(_ id: PluginId) -> PluginInstallState {
        installedPlugins.contains(id) ? .installed : .notInstalled
    }
    public func installPlugin(_ id: PluginId) async throws {
        installedPlugins.insert(id)
    }
    public func uninstallPlugin(_ id: PluginId) throws {
        installedPlugins.remove(id)
    }

    public func backupState() throws -> Data {
        if let state { return state }
        return try AppStateStore.encode(AppState.bootstrap())
    }
}
