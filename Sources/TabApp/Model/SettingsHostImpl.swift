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
    public func previewTerminalSettings(_ settings: TerminalSettings) { model.apply(terminalSettings: settings, preview: true) }

    public func openConfigurationFile(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("{}\n".utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Server

    public var serverState: ServerConnectionState {
        switch model.connectionState(.local) {
        case .ready: return .running
        case .connecting, .reconnecting: return .connecting
        case .idle, .needsUser: return .stopped
        }
    }

    public func connectServer() {
        model.connection(.local)?.retryNow()
    }

    public func readServerSettings() async throws -> ServerSettingsDoc { try await local().serverSettings() }
    public func writeServerSettings(_ settings: ServerSettingsDoc) async throws { try await local().writeServerSettings(settings) }

    public func stopServer() async throws {
        _ = try await local().stopServer(force: true)
    }

    public func restartServer() async throws { try await local().restartServer() }

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

    // MARK: Other

    /// The AI command-line tools found on this Mac.
    public func installedAIProviders() -> [String] {
        model.ai.installed.map(\.id)
    }

    public func dictationLanguages() -> [DictationLanguage] {
        SpeechRecorder.languages()
    }

    public func aiPromptProjects() -> [SettingsProject] {
        model.state.projects
            .filter { !$0.home && $0.parentId == nil }
            .map { SettingsProject(id: $0.id.description, name: $0.name) }
    }

    public func backupState() throws -> Data {
        try BackupStateMerge.backup(model.state, terminalFontSizes: model.terminalFontSizes)
    }
}
