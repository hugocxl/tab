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

    /// Every server the app knows, this computer's first.
    public var knownServers: [ServerId] {
        [.local] + settings.servers.map(\.id)
    }

    func serversDidChange(old: [ServerEntry]) {
        let current = Set(settings.servers.map(\.id))
        for entry in old where !current.contains(entry.id) {
            connections.removeValue(forKey: entry.id)?.disconnect()
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
            }
            edit { $0.forgetRemoteStatuses(connection.id) }
        }
        notify(.activity)
        notify(.state)
    }

    // MARK: Ready

    private func serverReady(_ connection: ServerConnection) {
        guard let main = connection.main else { return }
        let server = connection.id
        Task {
            do {
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
                restore(server, sessions: sessions)
                await flushClosures(server)
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

    func serverLabel(_ server: ServerId) -> String {
        server.isLocal ? "this Mac's server" : (serverName(server) ?? "the server")
    }

    /// Replaces the server's projects with its catalog.
    func applyCatalog(_ server: ServerId, _ catalog: CatalogPage) {
        guard catalog.revision >= state.catalogRevision(server) || state.serverIdentity(server) != catalog.server else {
            return
        }
        edit { try $0.applyCatalog(server, catalog) }
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

    /// Closes panes whose session is gone and starts the ones never started.
    func restore(_ server: ServerId, sessions: [SessionInfo]) {
        let live = sessions.map { LiveSession(project: $0.project, session: $0.id) }
        let plan = RestorePlan.plan(state, server: server, sessions: live)
        if !plan.close.isEmpty {
            edit { state in
                for entry in plan.close { try state.closeSessionPanes(server: server, session: entry.session) }
            }
        }
        createMissingSessions()
    }

    // MARK: Closures

    /// Ends sessions closed while offline and cancels creations that were
    /// abandoned, on every ready server.
    func flushClosures() {
        for server in knownServers where connectionState(server).isReady
            && (!state.pendingDiscards(server).isEmpty || !state.pendingCancellations(server).isEmpty)
        {
            Task { await flushClosures(server) }
        }
    }

    /// Sends the current session references before the closes: the server
    /// keeps a terminal its requester still lists as shown.
    func flushClosures(_ server: ServerId) async {
        guard let main = connections[server]?.main else { return }
        for operation in state.pendingCancellations(server) {
            do {
                try await main.cancelCreation(operation)
            } catch let error as ClientError where error.serverCode == nil {
                return
            } catch {}
            edit { $0.completeCancellation(server, operation) }
        }
        edit { $0.prepareCloses(server) }
        guard !state.pendingDiscards(server).isEmpty else { return }
        do {
            try await main.syncSessionReferences(owner: nil, revision: 0, sessions: state.sessionReferences(server))
        } catch {
            return
        }
        for session in state.pendingDiscards(server) {
            guard let operation = state.closeOperation(server, session) else { continue }
            do {
                try await main.closeSession(session, operation: operation)
            } catch let error as ClientError where error.serverCode == nil {
                return
            } catch {}
            edit { $0.completeDiscard(server, session) }
        }
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
    func createMissingSessions() {
        for project in state.projects where project.status == .available {
            guard let connection = connections[project.serverId], connection.state.isReady,
                  connection.main != nil, state.projectIntents(project.serverId).isEmpty
            else { continue }
            for pane in project.tabs.flatMap(\.panes) where pane.content == .terminal(session: nil) {
                createSession(pane.id, in: project)
            }
        }
    }

    private func createSession(_ pane: PaneId, in project: Project) {
        guard !creating.contains(pane), let main = connections[project.serverId]?.main else { return }
        creating.insert(pane)
        var directory = project.directory
        edit { directory = $0.prepareCreation(pane, directory: project.directory) }
        let (environment, proxied) = creationEnvironment(pane, server: project.serverId)
        if proxied { edit { try $0.setPaneProxy(pane, true) } }
        let request = CreateSession(
            project: project.id, operation: pane.creationToken, directory: directory,
            size: (panes.controller(for: pane) as? TerminalPane)?.estimatedSize ?? Size(cols: 80, rows: 24),
            environment: environment
        )
        let server = project.serverId
        Task {
            defer { creating.remove(pane) }
            do {
                let info = try await main.createSession(request)
                guard state.pane(pane) != nil else {
                    edit { $0.queueDiscard(server, info.id) }
                    return
                }
                proxy.forget(pane)
                edit { try $0.setPaneSession(pane, info.id) }
                var command: String?
                edit { command = $0.takeStartupCommand(pane) }
                if let command {
                    try? await main.writeInput(session: info.id, bytes: Data((command + "\r").utf8))
                }
            } catch {
                guard state.pane(pane) != nil else { return }
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
            case .unknown: break
            }
        case .sessionMetadata(let session, let metadata):
            sessionMetadata(server, session, metadata)
        case .progress(let session, let progress):
            connection.progress[session] = progress
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
            .filter { $0.content.session == session }.map(\.id)
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

    /// A terminal's program ended: its panes close everywhere.
    func sessionEnded(_ server: ServerId, _ session: SessionId) {
        connections[server]?.progress[session] = nil
        let closing = sessionPanes(server, session)
        guard !closing.isEmpty else { return }
        let hadFocus = activePane.map(closing.contains) ?? false
        edit { try $0.closeSessionPanes(server: server, session: session) }
        if hadFocus { focusActiveContent() }
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
    /// so its card follows changes made in a shell, as Codesh's `sync_git`.
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
            guard !fresh.isEmpty, notifier.available else { continue }
            guard let claimed = try? await main.claimActivity(fresh.map(\.id)), connection.main === main else { continue }
            deliveredNotifications[server, default: []].formUnion(claimed)
            for event in notificationEvents(server) where claimed.contains(event.id) {
                notifier.deliver(event, server: server, title: notificationTitle(server, event))
            }
        } while connection.activityDirty
    }

    /// Rechecks pane ownership and visibility after a notification claim returns.
    private func notificationEvents(_ server: ServerId) -> [AgentEvent] {
        let focused = focusedSession()
        let referenced = Set(state.sessionReferences(server))
        return connections[server]?.activity.events.filter { event in
            !event.read && referenced.contains(event.session)
                && !(focused?.0 == server && focused?.1 == event.session)
        } ?? []
    }

    /// Detached and closed terminals no longer leave a notification behind.
    func clearUnreferencedNotifications() {
        for (server, connection) in connections {
            let referenced = Set(state.sessionReferences(server))
            let removed = connection.activity.events.filter { !referenced.contains($0.session) }.map(\.id)
            notifier.clear(removed, server: server)
        }
    }

    private func notificationTitle(_ server: ServerId, _ event: AgentEvent) -> String {
        let pane = sessionPanes(server, event.session).first
        let project = pane.flatMap { state.paneProject($0) }.flatMap { state.project($0) }
        let name = project?.name ?? "Tab"
        let remote = server.isLocal ? nil : serverName(server)
        return [event.provider.displayName, name, remote].compactMap { $0 }.joined(separator: " · ")
    }

    /// The server and session the user is looking at, if any.
    func focusedSession() -> (ServerId, SessionId)? {
        guard windowActive, presenter?.terminalActivityObscured != true, let pane = activePane, let server = state.paneServer(pane),
              let session = state.pane(pane)?.content.session else { return nil }
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

    /// The agent running in a pane's terminal.
    public func agent(in pane: PaneId) -> AgentActivity? {
        guard let server = state.paneServer(pane), let session = state.pane(pane)?.content.session else { return nil }
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
