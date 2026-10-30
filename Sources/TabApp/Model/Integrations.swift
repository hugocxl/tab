import AppKit
import TabClient
import TabCore
import TabProtocol

extension AppModel {
    /// How `server` is reached: the test override, this computer's socket,
    /// or the Remote Servers model's SSH connector.
    func connector(_ server: ServerId, _ entry: ServerEntry?) -> ServerConnector? {
        if let connectorOverride { return connectorOverride(server, entry) }
        if server.isLocal {
            var local = LocalServer(dirs: dirs)
            if let app = Executable.currentURL(), Executable.containingBundle(of: app) != nil {
                local.hostApp = app
            }
            return LocalConnector(server: local)
        }
        guard let entry else { return nil }
        return remoteServers.connector(for: entry)
    }

    /// Starts the parts that run beside the window: updates.
    func startIntegrations() {
        updater.start()
    }

    /// Every connection change: Remote Servers redraws and the updater
    /// checks whether it can install.
    func integrationsConnectionChanged(_ connection: ServerConnection) {
        remoteServers.connectionsDidChange()
        if connection.id.isLocal { updater.reconcile() }
    }

    /// The environment of a new terminal: the proxy when it applies.
    func creationEnvironment(_ pane: PaneId, server: ServerId) -> (environment: [String: String], proxied: Bool) {
        let supports = connections[server]?.main?.supportsSessionEnvironment ?? false
        return proxy.creationEnvironment(for: pane, localServer: server.isLocal, serverSupportsEnvironment: supports)
    }
}

// MARK: Remote servers

extension AppModel: RemoteServersHost {
    public var remoteServersWindow: NSWindow? { presenter?.window }
    public var settingsURL: URL { dirs.settings }
    public var sshProxy: ProxyCommand? { try? proxy.sshCommand() }

    public func remoteConnection(_ server: ServerId) -> RemoteConnectionSnapshot {
        guard let connection = connections[server] else { return .offline }
        return RemoteConnectionSnapshot(connection.state, failure: connection.lastFailure)
    }

    public func connectRemoteServer(_ server: ServerId, fresh: Bool) {
        if fresh { connections.removeValue(forKey: server)?.disconnect() }
        guard let connection = connection(server) else { return }
        if case .needsUser = connection.state { connection.retryNow() } else { connection.start() }
    }

    public func disconnectRemoteServer(_ server: ServerId) {
        connections[server]?.disconnect()
    }

    public func remoteServerAPI(_ server: ServerId) -> ServerAPI? {
        connections[server]?.main
    }

    public func remoteServerListDidChange(_ servers: [ServerEntry]) {
        var updated = settings
        updated.servers = servers
        apply(settings: updated)
    }

    public func forgetProjects(on servers: [ServerId]) {
        edit { state in
            for server in servers { try state.forgetServer(server) }
        }
        for server in servers { connections.removeValue(forKey: server)?.disconnect() }
    }

    public func openRemoteHome(on server: ServerId) {
        connectOnDemand(server)
        guard let home = state.serverHome(server) else {
            pendingRemoteHomes.insert(server)
            return
        }
        newTerminal(in: home.id)
    }

    public func addRemoteProject(on server: ServerId) {
        presenter?.showRemoteFolderBrowser(server)
    }

    public func showRemoteServersPane() {
        showServersPane()
    }

    public func showRemoteError(_ message: String) {
        report(message)
    }
}

// MARK: Proxy

extension AppModel: ProxyHost {
    public var proxyWindow: NSWindow? { presenter?.window }

    public var localServerSupportsProxy: Bool {
        connections[.local]?.main?.supportsSessionEnvironment ?? true
    }

    public func restartTerminal(_ pane: PaneId) {
        Task {
            defer { proxy.forget(pane) }
            guard await controller(for: pane)?.willClose() ?? true else { return }
            guard let server = state.paneServer(pane), let old = state.pane(pane)?.content.session,
                  let projectId = state.paneProject(pane), let project = state.project(projectId) else { return }
            let directory = (panes.controller(for: pane) as? TerminalPane)?.directory ?? project.directory
            var created: PaneId?
            edit { state in
                created = try state.restartTerminal(pane)
                if let created {
                    proxy.transferChoice(from: pane, to: created)
                    _ = state.prepareCreation(created, directory: directory)
                }
            }
            panes.remove(pane)
            endSessions([old], on: server)
            if let created { focusPane(created) }
        }
    }

    public func proxyDidChange(_ model: ProxyModel) {
        updater.setSessionConfiguration(model.sessionConfiguration())
        for entry in settings.servers {
            guard let connection = connections[entry.id],
                  connection.sshTarget != (try? ServerForm.target(for: entry, proxy: sshProxy)) else { continue }
            let active: Bool
            switch connection.state {
            case .idle, .needsUser: active = false
            case .ready, .connecting, .reconnecting: active = true
            }
            connections.removeValue(forKey: entry.id)?.disconnect()
            if active { connectOnDemand(entry.id) }
        }
        notify(.settings)
    }

    public func showProxyNotice(_ message: String) {
        presenter?.showToast(message, error: false)
    }
}

extension ServerAPI {
    /// Whether the server can start terminals with an environment.
    var supportsSessionEnvironment: Bool {
        (self as? ServerClient)?.supports(.sessionEnvironment) ?? true
    }
}

// MARK: Updates

extension AppModel: UpdaterHost {
    public var updateWindow: NSWindow? { presenter?.window }

    public var localServerBuild: BuildInfo? { connections[.local]?.main?.server.build }

    public var runningSessionCount: Int { localSessionCount }

    public func endAllSessions() async throws {
        guard let main = connections[.local]?.main else { throw ModelError("This Mac's server is not running.") }
        _ = try await main.stopServer(force: true)
    }

    public func stopLocalServerIfIdle() async -> Bool {
        guard let main = connections[.local]?.main else { return true }
        return (try? await main.stopServerIfIdle()) ?? false
    }

    public func prepareToQuitForUpdate() -> Bool {
        saveNow()
        browserProfiles.saveHistories()
        return !openEditors.contains(where: \.isDirty)
    }

    public func quitForUpdate() {
        NSApp.terminate(nil)
    }

    public func updaterStatusDidChange(_ status: UpdaterStatus) {
        notify(.settings)
    }

    public func announceUpdate(version: String) {
        presenter?.showToast("Tab \(version) is ready to install.", error: false)
    }
}
