import Foundation
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

/// A project whose pull request prompt Settings can override: a top-level
/// project (worktrees use their parent's prompt).
public struct SettingsProject: Equatable, Sendable {
    /// The project id, the key under `ai.projectPrPrompts`.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
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
    /// `terminal.json` changed or was reloaded; apply it to every terminal.
    func terminalSettingsDidChange(_ settings: TerminalSettings)
    /// A slider is being dragged: show these terminal settings without
    /// saving them. The final value arrives through
    /// `terminalSettingsDidChange` on release.
    func previewTerminalSettings(_ settings: TerminalSettings)
    /// Opens a configuration file in the user's default editor.
    func openConfigurationFile(_ url: URL)

    // MARK: Server

    /// The local server's state; the host calls
    /// `SettingsStore.updateServerState` when it changes.
    var serverState: ServerConnectionState { get }
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

    // MARK: Other

    /// Ids of the AI command-line tools found on this Mac, such as `claude`.
    func installedAIProviders() -> [String]
    /// The projects that can have their own pull request prompt, in sidebar
    /// order.
    func aiPromptProjects() -> [SettingsProject]
    /// The local projects with their layouts and workspaces, as the backup
    /// stores them (`state.json`'s configuration).
    func backupState() throws -> Data
}

/// A host with no app behind it: a running server with default settings,
/// nothing paired, one browser profile. For tests and previews.
@MainActor
public final class PreviewSettingsHost: SettingsHost {
    public var serverState: ServerConnectionState = .running
    public var serverSettings = ServerSettingsDoc()
    public var remoteAccess = RemoteAccessState(revision: 0, settings: RemoteAccessSettings(), status: .disabled)
    public var profiles = [BrowserProfileSummary(id: "", name: "Default")]
    public private(set) var appliedSettings: [Settings] = []
    public private(set) var appliedTerminal: [TerminalSettings] = []
    public private(set) var previews: [TerminalSettings] = []
    public private(set) var openedFiles: [URL] = []
    public private(set) var serverActions: [String] = []
    public var state: Data?
    public var projects: [SettingsProject] = []
    public var importSources: [BrowserImportSource] = []

    public init() {}

    public func settingsDidChange(_ settings: Settings) { appliedSettings.append(settings) }
    public func terminalSettingsDidChange(_ settings: TerminalSettings) { appliedTerminal.append(settings) }
    public func previewTerminalSettings(_ settings: TerminalSettings) { previews.append(settings) }
    public func openConfigurationFile(_ url: URL) { openedFiles.append(url) }

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

    public func installedAIProviders() -> [String] { [] }
    public func aiPromptProjects() -> [SettingsProject] { projects }
    public func backupState() throws -> Data {
        if let state { return state }
        return try AppStateStore.encode(AppState.bootstrap())
    }
}
