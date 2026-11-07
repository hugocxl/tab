import Foundation
import TabClient
import TabCore
import TabProtocol

extension AppModel {
    // MARK: Connections

    /// The connection to `server`, made on first use. `nil` for a server
    /// that is no longer listed.
    @discardableResult
    public func connection(_ server: ServerId) -> ServerConnection? {
        if let existing = connections[server] { return existing }
        let entry = server.isLocal ? nil : settings.server(server)
        guard server.isLocal || entry != nil, let connector = connector(server, entry) else { return nil }
        let connection = ServerConnection(id: server, connector: connector, sshTarget: entry.flatMap { try? ServerForm.target(for: $0, proxy: sshProxy) })
        connection.onReady = { [weak self] connection in self?.serverReady(connection) }
        connection.onEvent = { [weak self] connection, event in self?.receive(event, from: connection) }
        connection.onStateChange = { [weak self] connection in self?.connectionChanged(connection) }
        connections[server] = connection
        return connection
    }

    /// Connects a remote server when one of its projects is opened.
    public func connectOnDemand(_ server: ServerId) {
        guard let connection = connection(server) else { return }
        if case .needsUser = connection.state { return }
        connection.start()
    }

    /// Connects every listed remote server so its cards show live agents,
    /// branches and activity. Servers that log in with a password wait until
    /// one of their projects is opened, so launching never asks.
    func startServers() {
        for entry in settings.servers where !entry.passwordLogin {
            connectOnDemand(entry.id)
        }
    }

    /// Every server the app knows, this computer's first.
    public var knownServers: [ServerId] {
        [.local] + settings.servers.map(\.id)
    }

    func serversDidChange(old: [ServerEntry]) {
        let current = Set(settings.servers.map(\.id))
        for entry in old where !current.contains(entry.id) {
            connections.removeValue(forKey: entry.id)?.disconnect()
            browserProxies.removeValue(forKey: entry.id)?.stop()
            portForwards.removeValue(forKey: entry.id)?.values.forEach { $0.stop() }
        }
        for entry in settings.servers {
            guard let previous = old.first(where: { $0.id == entry.id }), !previous.hasSameConnection(as: entry) else { continue }
            connections.removeValue(forKey: entry.id)?.disconnect()
            connectOnDemand(entry.id)
        }
    }

    private func connectionChanged(_ connection: ServerConnection) {
        integrationsConnectionChanged(connection)
        if connection.state.isOffline {
            for (id, controller) in panes.all where state.paneServer(id) == connection.id {
                (controller as? TerminalPane)?.connectionChanged()
                (controller as? AgentPaneController)?.connectionChanged()
                (controller as? SimulatorPaneController)?.serverDisconnected()
            }
            edit { $0.forgetRemoteStatuses(connection.id) }
        }
        let readOnly: Bool
        switch connection.state {
        case .reconnecting, .needsUser: readOnly = !connection.id.isLocal
        case .idle, .connecting, .ready: readOnly = false
        }
        if state.canEditTabs(connection.id) == readOnly { edit { $0.setTabsReadOnly(connection.id, readOnly) } }
        notify(.activity)
        notify(.state)
    }

    // MARK: Ready

    private func serverReady(_ connection: ServerConnection) {
        guard let main = connection.main else { return }
        let server = connection.id
        Task {
            do {
                reportUncleanStop(server, main.server)
                let sessions = try await main.sessions()
                if server.isLocal {
                    localSessionCount = sessions.count
                    updater.reconcile()
                }
                let catalog = try await main.catalog()
                guard connection.main === main else { return }
                applyCatalog(server, catalog)
                await replayIntents(server)
                guard connection.main === main else { return }
                edit { $0.forgetTabAcknowledgements(server) }
                await refreshTabs(server)
                await sendTabIntents(server)
                guard connection.main === main else { return }
                restore(server, sessions: sessions)
                await syncReferences(server)
                await refreshActivity(server)
                for (id, controller) in panes.all where state.paneServer(id) == server {
                    (controller as? TerminalPane)?.connectionChanged()
                    (controller as? AgentPaneController)?.connectionChanged()
                }
                refreshGit(server: server)
                syncGitWatch()
                nativeReconnected(server)
                if pendingRemoteHomes.remove(server) != nil { openRemoteHome(on: server) }
            } catch {
                report("Could not load \(serverLabel(server)): \(error.message)")
            }
        }
    }

    /// Says once per server start that the previous one stopped without
    /// ending its terminals, so missing terminals aren't a mystery.
    private func reportUncleanStop(_ server: ServerId, _ info: ServerInfo) {
        guard info.previousStopUnclean == true, reportedUncleanStops.insert(info.instance).inserted else { return }
        let subject = server.isLocal ? "This Mac's server" : "The server on \(serverName(server) ?? "another computer")"
        presenter?.showToast("\(subject) stopped unexpectedly. Terminals that were running show their last saved output.",
                             error: true)
    }

    func serverLabel(_ server: ServerId) -> String {
        server.isLocal ? "this Mac's server" : (serverName(server) ?? "the server")
    }

    /// Replaces the server's projects with its catalog.
    func applyCatalog(_ server: ServerId, _ catalog: CatalogPage) {
        guard catalog.revision >= state.catalogRevision(server) || state.serverIdentity(server) != catalog.server else {
            return
        }
        let previousProjects = Set(state.projects.filter { $0.serverId == server }.map(\.id))
        edit { try $0.applyCatalog(server, catalog) }
        for project in state.projects where project.serverId == server
            && !previousProjects.contains(project.id) && !project.home && project.status == .available {
            refreshGit(project.id)
        }
    }

    private func refreshCatalog(_ server: ServerId) async {
        guard let main = connections[server]?.main, state.projectIntents(server).isEmpty else { return }
        do {
            applyCatalog(server, try await main.catalog())
        } catch {
            report("Could not refresh projects: \(error.message)")
        }
    }

    /// Sends project edits made while the server was away, oldest first.
    func replayIntents(_ server: ServerId) async {
        guard let main = connections[server]?.main, !replaying.contains(server) else { return }
        replaying.insert(server)
        defer { replaying.remove(server) }
        var sent = false
        while let intent = state.projectIntents(server).first {
            do {
                _ = try await main.mutateProject(intent)
            } catch let error as ClientError where error.serverCode != nil && error.serverCode != .persistenceFailed {
                report(error.description)
            } catch {
                return
            }
            edit { try $0.completeProjectIntent(server, intent.operation) }
            sent = true
        }
        if sent { await refreshCatalog(server) }
    }

    func replayAllIntents() {
        for server in knownServers where !state.projectIntents(server).isEmpty && connectionState(server).isReady {
            Task { await replayIntents(server) }
        }
    }

    /// Starts the terminals never started. The server already removed the
    /// panes of terminals that ended.
    func restore(_ server: ServerId, sessions: [SessionInfo]) {
        createMissingSessions()
    }

    // MARK: Tabs

    /// Shows the tabs `server` keeps now. A server too old to keep tabs
    /// leaves the ones this app kept, unchanged.
    func refreshTabs(_ server: ServerId) async {
        guard let connection = connections[server], let main = connection.main else { return }
        do {
            let snapshot = try await main.tabs()
            guard connection.main === main, snapshot.revision >= connection.tabsRevision ?? 0 else { return }
            connection.tabsRevision = snapshot.revision
            let active = activePane
            edit { $0.applyTabs(server, snapshot) }
            if let active, state.pane(active) == nil { focusActiveContent() }
        } catch let error as ClientError where error.serverCode == .unsupported {
            edit { $0.setTabsReadOnly(server, true) }
            if outdatedTabServers.insert(server).inserted {
                let subject = server.isLocal ? "This Mac's server" : "The server on \(serverName(server) ?? "another computer")"
                report("\(subject) is out of date. Restart it to change its tabs.")
            }
        } catch {
            Log.app.error("tabs of \(self.serverLabel(server), privacy: .public) not loaded: \(error.message, privacy: .public)")
        }
    }

    /// Sends every ready server the tab changes made here.
    func sendAllTabIntents() {
        for server in knownServers where connectionState(server).isReady
            && (state.hasPendingTabs(server) || !state.legacyTabIntents(server).isEmpty)
        {
            Task { await sendTabIntents(server) }
        }
    }

    /// Sends `server` the tabs this app kept before servers kept them, then
    /// the changes made here, oldest first, once its projects are up to
    /// date. A change the server refuses, because another app changed the
    /// same tab first, gives way to the server's tabs.
    func sendTabIntents(_ server: ServerId) async {
        guard let main = connections[server]?.main, state.tabsRevision(server) != nil,
              state.projectIntents(server).isEmpty, sendingTabs.insert(server).inserted
        else { return }
        defer { sendingTabs.remove(server) }
        var sent = false
        let legacy = state.legacyTabIntents(server)
        for mutation in legacy {
            do {
                _ = try await main.mutateTabs(TabIntent(mutation: mutation))
            } catch let error as ClientError where error.serverCode != nil {
                Log.app.error("tabs kept here not taken: \(error.description, privacy: .public)")
            } catch {
                return
            }
        }
        if !legacy.isEmpty {
            edit { $0.completeLegacyTabs(server) }
            sent = true
        }
        // Changes made while the tabs are read back are sent in the next round.
        repeat {
            while let intent = state.nextTabIntent(server) {
                do {
                    let revision = try await main.mutateTabs(intent)
                    edit { $0.acknowledgeTabIntent(server, intent.operation, revision: revision) }
                } catch let error as ClientError where error.serverCode != nil {
                    Log.app.info("tab change refused: \(error.description, privacy: .public)")
                    edit { $0.completeTabIntent(server, intent.operation) }
                } catch {
                    return
                }
                sent = true
            }
            if sent { await refreshTabs(server) }
            sent = false
        } while state.hasPendingTabs(server) && connections[server]?.main === main
    }

    // MARK: Session references

    func scheduleReferenceSync() {
        referencesWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for server in self.knownServers where self.connectionState(server).isReady {
                    Task { await self.syncReferences(server) }
                }
            }
        }
        referencesWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func syncReferences(_ server: ServerId) async {
        guard let main = connections[server]?.main else { return }
        try? await main.syncSessionReferences(owner: nil, revision: 0, sessions: state.sessionReferences(server))
    }

    // MARK: Creating terminals

    /// Asks each ready server to start the terminals its panes are waiting
    /// for: visible panes first, all of them once restored.
    /// Starts the terminals of panes their server already has. Any app may
    /// start one: the pane names the creation, so the server starts it once
    /// and shows it in the pane.
    func createMissingSessions() {
        for project in state.projects where project.status == .available {
            guard let connection = connections[project.serverId], connection.state.isReady,
                  connection.main != nil, state.projectIntents(project.serverId).isEmpty
            else { continue }
            let confirmed = state.confirmedPanes(project.serverId)
            for pane in project.tabs.flatMap(\.panes)
            where pane.content == .terminal(session: nil) && confirmed.contains(pane.id) {
                createSession(pane, in: project)
            }
        }
    }

    private func createSession(_ pane: Pane, in project: Project) {
        guard !creating.contains(pane.id), let main = connections[project.serverId]?.main else { return }
        creating.insert(pane.id)
        let (environment, _) = creationEnvironment(pane.id, server: project.serverId)
        let request = CreateSession(
            project: project.id, operation: pane.id.creationToken, directory: pane.launch?.directory ?? project.directory,
            size: (panes.controller(for: pane.id) as? TerminalPane)?.estimatedSize ?? Size(cols: 80, rows: 24),
            environment: environment, pane: pane.id, input: pane.launch?.command
        )
        let server = project.serverId
        Task {
            defer { creating.remove(pane.id) }
            do {
                _ = try await main.createSession(request)
                proxy.forget(pane.id)
                await refreshTabs(server)
            } catch {
                guard state.pane(pane.id) != nil else { return }
                report("Could not start a terminal: \(error.message)")
            }
        }
    }

    // MARK: Events

    private func receive(_ event: ClientEvent, from connection: ServerConnection) {
        let server = connection.id
        switch event {
        case let .agentChatChanged(session, revision):
            for (id, controller) in panes.all where state.paneServer(id) == server {
                (controller as? AgentPaneController)?.sessionChanged(session: session, revision: revision)
            }
        case .changed(let topic, _):
            switch topic {
            case .catalog: Task { await refreshCatalog(server) }
            case .activity: Task { await refreshActivity(server) }
            case .sessions:
                if server.isLocal, let main = connection.main {
                    Task {
                        localSessionCount = (try? await main.sessions().count) ?? localSessionCount
                        updater.reconcile()
                    }
                }
            case .remoteAccess:
                if server.isLocal { notify(.remoteAccess) }
            case .simulators:
                simulatorsChanged(server)
            case .tabs:
                Task { await refreshTabs(server) }
            case .unknown: break
            }
        case .sessionMetadata(let session, let metadata):
            sessionMetadata(server, session, metadata)
        case .progress(let session, let progress):
            let failed = progress.progress?.state == .error && connection.progress[session]?.progress?.state != .error
            connection.progress[session] = progress
            if failed { announce(.error, server: server, session: session) }
            for pane in sessionPanes(server, session) { (panes.controller(for: pane) as? TerminalPane)?.progressChanged() }
            notify(.activity)
        case .sessionEnded(let session, _):
            sessionEnded(server, session)
        case .gitChanged(let project):
            gitChanged(project)
        case .filesChanged(let project, let changes):
            filesChanged(project, changes)
        case .serverRestarting, .disconnected:
            break
        }
    }

    func sessionPanes(_ server: ServerId, _ session: SessionId) -> [PaneId] {
        state.projects.filter { $0.serverId == server }.flatMap(\.tabs).flatMap(\.panes)
            .filter { $0.content.activitySession == session }.map(\.id)
    }

    private func sessionMetadata(_ server: ServerId, _ session: SessionId, _ metadata: SessionMetadata) {
        let title = TerminalTitle.derive(
            metadata.title, processName: metadata.process?.name, processIsShell: metadata.process?.isShell ?? true,
            directory: TerminalSessionController.abbreviate(metadata.directory.rawValue)
        )
        let targets = sessionPanes(server, session).filter { state.pane($0)?.title != title }
        guard !targets.isEmpty else { return }
        edit { state in
            for pane in targets { try state.setPaneTitle(pane, title) }
        }
    }

    /// A terminal's program ended: its server closes its panes everywhere.
    func sessionEnded(_ server: ServerId, _ session: SessionId) {
        connections[server]?.progress[session] = nil
    }

    // MARK: Git

    /// Refreshes the branch, last commit and pull request of every listed
    /// project on `server`.
    func refreshGit(server: ServerId) {
        for project in state.projects where project.serverId == server && !project.home && project.status == .available {
            refreshGit(project.id)
        }
    }

    /// Watches the current project's working tree on its side connection,
    /// so its card follows changes made in a shell.
    /// The server keeps one watch per connection; a new connection needs it
    /// again.
    func syncGitWatch() {
        let project = currentProject
        guard !project.home, project.status == .available, let side = sideClient(for: project.id) else { return }
        let connection = ObjectIdentifier(side as AnyObject)
        if let gitWatch, gitWatch.project == project.id, gitWatch.connection == connection { return }
        gitWatch = (project.id, connection)
        let id = project.id
        Task { _ = try? await side.git(GitRequest(project: id, action: .watch)) }
    }

    public func refreshGit(_ project: ProjectId) {
        guard !gitRefreshing.contains(project), let side = sideClient(for: project) else { return }
        gitRefreshing.insert(project)
        Task {
            defer { gitRefreshing.remove(project) }
            let summary = try? await side.gitSummary(project)
            var info = GitInfo(summary: summary ?? nil, pullRequest: git[project]?.pullRequest)
            if summary != nil {
                info.pullRequest = try? await side.pullRequestNumber(project)
            }
            if git[project] != info {
                git[project] = info
                notify(.activity)
                notify(.state)
            }
        }
    }

    // MARK: Activity

    func refreshActivity(_ server: ServerId) async {
        guard let connection = connections[server], let main = connection.main else { return }
        if connection.activityRefreshing {
            connection.activityDirty = true
            return
        }
        connection.activityRefreshing = true
        defer { connection.activityRefreshing = false }
        repeat {
            connection.activityDirty = false
            guard let snapshot = try? await main.activity(), connection.main === main else { return }
            let previous = connection.activity
            if connection.activityLoaded { announceStartedWork(server, before: previous.agents, after: snapshot.agents) }
            let latest = previous.events.map(\.id).max() ?? 0
            let unread = Set(snapshot.events.filter { !$0.read }.map(\.id))
            notifier.clear(previous.events.filter { !unread.contains($0.id) }.map(\.id), server: server)
            let loaded = connection.activityLoaded
            connection.activity = snapshot
            connection.activityLoaded = true
            clearUnreferencedNotifications()
            notify(.activity)
            let fresh = loaded ? notificationEvents(server).filter {
                $0.id > latest && !(deliveredNotifications[server]?.contains($0.id) ?? false)
            } : []
            acknowledgeFocusedActivity()
            let notifications = settings.notifications
            let wanted = fresh.filter { notifications.notifies($0.kind.status) || notifications.sound($0.kind.status) != nil }
            guard !wanted.isEmpty else { continue }
            guard let claimed = try? await main.claimActivity(wanted.map(\.id)), connection.main === main else { continue }
            deliveredNotifications[server, default: []].formUnion(claimed)
            let events = notificationEvents(server).filter { claimed.contains($0.id) }
            for event in events where notifier.available && settings.notifications.notifies(event.kind.status) {
                notifier.deliver(event, server: server, title: notificationTitle(server, event))
            }
            playSound(events.map(\.kind.status))
        } while connection.activityDirty
    }

    /// Rechecks pane ownership and visibility after a notification claim returns.
    private func notificationEvents(_ server: ServerId) -> [AgentEvent] {
        let focused = focusedSession()
        let referenced = Set(state.projects.filter { $0.serverId == server }.flatMap(\.tabs).flatMap(\.panes).compactMap(\.content.activitySession))
        return connections[server]?.activity.events.filter { event in
            !event.read && reports(event) && referenced.contains(event.session)
                && !(focused?.0 == server && focused?.1 == event.session)
        } ?? []
    }

    /// Detached and closed terminals no longer leave a notification behind.
    func clearUnreferencedNotifications() {
        for (server, connection) in connections {
            let referenced = Set(state.projects.filter { $0.serverId == server }.flatMap(\.tabs).flatMap(\.panes).compactMap(\.content.activitySession))
            let removed = connection.activity.events.filter { !referenced.contains($0.session) }.map(\.id)
            notifier.clear(removed, server: server)
        }
    }

    func notificationTitle(_ server: ServerId, _ event: AgentEvent) -> String {
        let pane = sessionPanes(server, event.session).first
        let project = pane.flatMap { state.paneProject($0) }.flatMap { state.project($0) }
        let name = project?.name ?? "Tab"
        let remote = server.isLocal ? nil : serverName(server)
        let source = event.kind == .notification ? (event.body == nil ? nil : event.title) ?? "Terminal" : event.provider.displayName
        return [source, name, remote].compactMap { $0 }.joined(separator: " · ")
    }

    /// The server and session the user is looking at, if any.
    func focusedSession() -> (ServerId, SessionId)? {
        guard windowActive, presenter?.terminalActivityObscured != true, let pane = activePane, let server = state.paneServer(pane),
              let session = state.pane(pane)?.content.activitySession else { return nil }
        return (server, session)
    }

    /// Looking at a pane reads its agent's events, here and on every app.
    func acknowledgeFocusedActivity() {
        guard let (server, session) = focusedSession(), let connection = connections[server],
              let main = connection.main else { return }
        let ids = connection.unread(session).map(\.id)
        guard !ids.isEmpty else { return }
        for index in connection.activity.events.indices where ids.contains(connection.activity.events[index].id) {
            connection.activity.events[index].read = true
        }
        notifier.clear(ids, server: server)
        notify(.activity)
        Task { try? await main.acknowledgeActivity(ids) }
    }

    /// Opens the pane a notification is about.
    public func openNotification(server: ServerId, session: SessionId) {
        guard let pane = sessionPanes(server, session).first else { return }
        edit { try $0.focusPane(pane) }
        presenter?.bringToFront()
        controller(for: pane)?.focusContent()
    }

    /// The agent associated with a terminal or native chat pane.
    public func agent(in pane: PaneId) -> AgentActivity? {
        guard let server = state.paneServer(pane), let session = state.pane(pane)?.content.activitySession else { return nil }
        return connections[server]?.agent(session)
    }

    /// The pane's terminal progress.
    public func progress(in pane: PaneId) -> TerminalProgress? {
        guard let server = state.paneServer(pane), let session = state.pane(pane)?.content.session else { return nil }
        return connections[server]?.progress[session]?.progress
    }

    /// Whether an unread event waits in one of `sessions`.
    func hasUnread(_ server: ServerId, _ sessions: [SessionId]) -> Bool {
        guard let connection = connections[server] else { return false }
        return connection.activity.events.contains { !$0.read && sessions.contains($0.session) }
    }
}

extension ServerEntry {
    /// Presentation edits preserve the SSH connection and its attachments.
    func hasSameConnection(as other: ServerEntry) -> Bool {
        ssh == other.ssh && port == other.port && identityFile == other.identityFile
            && sshCommand == other.sshCommand && passwordLogin == other.passwordLogin
    }
}
