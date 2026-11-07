import AppKit
import TabCore
import TabProtocol

extension EventKind {
    /// The status an event reports: an agent waiting for you is blocked;
    /// a finished turn or a program's own notification is done.
    var status: ActivityStatus { self == .attention ? .blocked : .done }
}

extension AppModel {
    /// Whether Notifications settings let `event` show at all.
    func reports(_ event: AgentEvent) -> Bool {
        let notifications = settings.notifications
        if event.kind == .notification && !notifications.terminalNotifications { return false }
        return notifications[event.kind.status].enabled
    }

    /// Tells about `status` in a pane you aren't looking at: a macOS
    /// notification and a sound, as Notifications settings ask.
    func announce(_ status: ActivityStatus, server: ServerId, session: SessionId) {
        guard let pane = sessionPanes(server, session).first, focusedSession().map({ $0 != (server, session) }) ?? true else { return }
        let notifications = settings.notifications
        if notifications.notifies(status) {
            let project = state.paneProject(pane).flatMap { state.project($0) }
            let source = connections[server]?.activity.agents.first { $0.session == session }?.provider.displayName ?? "Terminal"
            let title = [source, project?.name ?? Release.appName, server.isLocal ? nil : serverName(server)]
                .compactMap { $0 }.joined(separator: " · ")
            let body = status == .working ? "Started working" : "Reported an error"
            notifier.post(id: "\(status.rawValue):\(server):\(session)", title: title, body: body, server: server, session: session)
        }
        playSound([status])
    }

    /// Agents that started working since the last snapshot.
    func announceStartedWork(_ server: ServerId, before: [AgentActivity], after: [AgentActivity]) {
        let working = Set(before.filter { $0.state == .working }.map(\.session))
        for agent in after where agent.state == .working && !working.contains(agent.session) {
            announce(.working, server: server, session: agent.session)
        }
    }

    /// Plays the sound of the most pressing of `statuses`, once.
    func playSound(_ statuses: [ActivityStatus]) {
        let order: [ActivityStatus] = [.error, .blocked, .done, .working]
        guard let status = order.first(where: statuses.contains), let sound = settings.notifications.sound(status) else { return }
        notifier.play(sound)
    }

    /// The panes Notifications settings badge the Dock icon for.
    var dockBadgeCount: Int {
        let notifications = settings.notifications
        var count = 0
        for (server, connection) in connections {
            let referenced = Set(state.projects.filter { $0.serverId == server }.flatMap(\.tabs).flatMap(\.panes)
                .compactMap(\.content.activitySession))
            for session in referenced {
                let agent = connection.activity.agents.first { $0.session == session }?.state
                let progress = connection.progress[session]?.progress?.state
                let unread = connection.activity.events.filter { !$0.read && $0.session == session && reports($0) }
                if unread.contains(where: { notifications.badges($0.kind.status) })
                    || agent == .blocked && notifications.badges(.blocked)
                    || progress == .error && notifications.badges(.error)
                    || (agent == .working || progress == .running || progress == .indeterminate) && notifications.badges(.working) {
                    count += 1
                }
            }
        }
        return count
    }

    func updateDockBadge() {
        guard let app = NSApp else { return }
        let count = dockBadgeCount
        let label = count > 0 ? "\(count)" : nil
        if app.dockTile.badgeLabel != label { app.dockTile.badgeLabel = label }
    }
}
