import AppKit
import TabClient
import TabCore

/// What the remote servers model, its popover, dialogs and pane need from
/// the app shell. The shell owns the connections (`ServerConnection`); the
/// model asks it to connect and hang up, and reads where each one stands.
@MainActor
public protocol RemoteServersHost: AnyObject {
    /// The window sheets and alerts attach to.
    var remoteServersWindow: NSWindow? { get }
    /// `settings.json`, which lists the servers.
    var settingsURL: URL { get }
    /// How ssh goes through the app's proxy when it applies to the whole
    /// app; `nil` otherwise.
    var sshProxy: ProxyCommand? { get }
    /// Where the shell's connection to `server` stands.
    func remoteConnection(_ server: ServerId) -> RemoteConnectionSnapshot
    /// Connects `server`, or tries again now. `fresh` hangs up a live
    /// connection first, for Reconnect.
    func connectRemoteServer(_ server: ServerId, fresh: Bool)
    /// Hangs up without ending terminals there; it stays offline, not
    /// retrying, until Connect or until one of its projects is opened.
    func disconnectRemoteServer(_ server: ServerId)
    /// The connection for requests such as listing folders or stopping the
    /// server there, while connected.
    func remoteServerAPI(_ server: ServerId) -> ServerAPI?
    /// The server list in `settings.json` changed (added, edited, regrouped,
    /// forgotten): the shell takes in the new list and syncs connections.
    func remoteServerListDidChange(_ servers: [ServerEntry])
    /// `servers` were forgotten: their projects and layouts leave this app.
    func forgetProjects(on servers: [ServerId])
    /// New Terminal in `server`'s Home, connecting it first if needed.
    func openRemoteHome(on server: ServerId)
    /// Add Project… on `server`: the shell shows a `RemoteFolderBrowser`.
    func addRemoteProject(on server: ServerId)
    /// Shows the Remote Servers pane in the current project.
    func showRemoteServersPane()
    /// A failure the user should see, such as a settings write that failed.
    func showRemoteError(_ message: String)
}

/// Where a connection to a remote server stands, as the shell reports it.
public struct RemoteConnectionSnapshot: Equatable, Sendable {
    public var state: RemoteServerState
    /// Why the last attempt failed, while not connected.
    public var failure: ClientError?
    /// A reconnect waits for its turn.
    public var retrying: Bool

    public init(state: RemoteServerState = .offline, failure: ClientError? = nil, retrying: Bool = false) {
        self.state = state
        self.failure = failure
        self.retrying = retrying
    }

    public static let offline = RemoteConnectionSnapshot()

    /// The snapshot for the shell's `ConnectionState` and its last failure.
    public init(_ state: ConnectionState, failure: ClientError?) {
        switch state {
        case .idle: self.init(state: .offline, failure: failure)
        case .connecting: self.init(state: .connecting)
        case .ready: self.init(state: .connected)
        case .reconnecting: self.init(state: .offline, failure: failure, retrying: true)
        case .needsUser(let message): self.init(state: .offline, failure: failure ?? .transport(message))
        }
    }
}
