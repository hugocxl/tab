import AppKit
import Combine
import TabClient
import TabCore
import TabProtocol

/// What Settings needs from the app, backed by the model and this
/// computer's server connection.
@MainActor
public final class SettingsHostImpl: SettingsHost {
    unowned let model: AppModel
    public weak var store: SettingsStore?
    private var subscription: AnyCancellable?

    public init(model: AppModel) {
        self.model = model
        subscription = model.changes.sink { [weak self] changes in
            guard let self else { return }
            if changes.contains(.activity) { self.store?.updateServerState(self.serverState) }
            if changes.contains(.remoteAccess) { self.refreshRemoteAccess() }
        }
    }

    private func refreshRemoteAccess() {
        Task { [weak self] in
            guard let self, let client = try? local(), let access = try? await client.remoteAccess(),
                  model.connections[.local]?.main === client else { return }
            store?.updateRemoteAccess(access)
        }
    }

    private func local() throws -> ServerAPI {
        guard let client = model.connections[.local]?.main else {
            throw ModelError("This Mac's server is not running.")
        }
        return client
    }

    // MARK: Applying preferences

    public func settingsDidChange(_ settings: Settings) { model.apply(settings: settings) }
    public func terminalSettingsDidChange(_ settings: TerminalSettings) { model.apply(terminalSettings: settings) }

    // MARK: Server

    public var serverState: ServerConnectionState {
        switch model.connectionState(.local) {
        case .ready: return .running
        case .connecting, .reconnecting: return .connecting
        case .idle, .needsUser: return .stopped
        }
    }

    public var serverVersion: String? { model.localServerBuild?.version }

    public var canRestartServer: Bool { model.updater.canRestartServer }
    public var serverRestarting: Bool { model.updater.status == .restartingServer }
    public var serverRestartFailure: String? { model.updater.serverRestartFailure }

    public func connectServer() {
        model.connection(.local)?.retryNow()
    }

    public func readServerSettings() async throws -> ServerSettingsDoc { try await local().serverSettings() }
    public func writeServerSettings(_ settings: ServerSettingsDoc) async throws { try await local().writeServerSettings(settings) }

    public func stopServer() async throws {
        _ = try await local().stopServer(force: true)
    }

    public func restartServer() async throws {
        _ = try local()
        guard canRestartServer else { throw ModelError("Wait for the current update to finish, then restart the server.") }
        model.updater.handle(.endTerminalsAndRestartServer)
    }

    // MARK: Mobile

    public func readRemoteAccess() async throws -> RemoteAccessState { try await local().remoteAccess() }

    public func writeRemoteAccess(_ settings: RemoteAccessSettings) async throws {
        _ = try await local().writeRemoteAccess(settings)
    }

    public func startPairing() async throws -> PairingOffer { try await local().startPairing(hosts: []) }
    public func cancelPairing() async { _ = try? await local().cancelPairing() }
    public func revokeDevice(_ device: DeviceId) async throws { _ = try await local().revokeDevice(device) }

    // MARK: Browser

    public func browserProfiles() -> [BrowserProfileSummary] { model.browserProfiles.browserProfiles() }

    public func addBrowserProfile(named name: String) throws -> BrowserProfileSummary {
        try model.browserProfiles.addBrowserProfile(named: name)
    }

    public func renameBrowserProfile(_ id: String, to name: String) throws {
        try model.browserProfiles.renameBrowserProfile(id, to: name)
    }

    public func deleteBrowserProfile(_ id: String) async throws { try await model.browserProfiles.deleteBrowserProfile(id) }
    public func clearBrowserProfileData(_ id: String) async throws { try await model.browserProfiles.clearBrowserProfileData(id) }
    public func browserImportSources() -> [BrowserImportSource] { model.browserProfiles.browserImportSources() }

    public func importBrowserData(from source: BrowserImportSource, cookies: Bool) async throws {
        try await model.browserProfiles.importBrowserData(from: source, cookies: cookies)
    }

    // MARK: Privacy

    public func privacyAccess(_ permission: PrivacyPermission) -> PrivacyAccess { PrivacyAccess.current(permission) }

    // MARK: Agents

    public func agentIntegrations() async throws -> [AgentIntegrationStatus] {
        try await Task.detached(priority: .userInitiated) { try AgentIntegrations.current().status() }.value
    }

    public func setAgentIntegration(_ enabled: Bool) async throws -> [AgentIntegrationStatus] {
        try await Task.detached(priority: .userInitiated) {
            let integrations = try AgentIntegrations.current()
            return enabled ? try integrations.install() : try integrations.remove()
        }.value
    }

    public func migrationSources() -> [TerminalMigration.Source] {
        TerminalMigration.available(home: URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()))
    }

    public func openAgent(prompt: String) throws {
        guard let pane = model.newTab(.agent) else { throw ModelError("Tab couldn't open an agent tab.") }
        model.draftAgentPrompt(prompt, in: pane)
    }

    // MARK: Backup

    public func backupState() throws -> Data {
        try BackupStateMerge.backup(model.state, terminalFontSizes: model.terminalFontSizes)
    }
}
