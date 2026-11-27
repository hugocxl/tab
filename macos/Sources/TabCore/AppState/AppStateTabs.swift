import Foundation

// Each server keeps its projects' tabs. A project's `tabs` here are what its
// server last sent, the tabs this app kept before servers kept them, and this
// app's changes still on their way, applied in that order with the reducer
// the server runs, so they look here as they will there.
extension AppState {
    // MARK: Changing tabs

    /// Changes `server`'s tabs here at once, and queues the change for it.
    mutating func perform(_ server: ServerId, _ mutation: TabMutation) throws {
        guard !readOnlyServers.contains(server) else { throw AppError.serverOffline(server) }
        guard var board = currentBoard(server) else {
            throw AppError.invalidState("connect to the server before changing its tabs")
        }
        do {
            try TabReducer.apply(mutation, to: &board) { project($0)?.serverId == server }
        } catch let error as TabChangeError {
            throw AppError.invalidState(error.description)
        }
        var state = servers[server] ?? ServerState()
        state.pendingTabs.append(TabIntent(mutation: mutation))
        servers[server] = state
        show(board, of: server)
    }

    /// The tabs shown for `server`, as the reducer sees them.
    private func currentBoard(_ server: ServerId) -> TabBoard? {
        guard let home = serverHome(server)?.id else { return nil }
        return TabBoard(home: home, projects: projects.filter { $0.serverId == server }
            .map { ProjectTabs(project: $0.id, tabs: $0.tabs) })
    }

    // MARK: Server answers

    /// Whether `server`'s tabs can change now; an offline server's can't.
    public func canEditTabs(_ server: ServerId) -> Bool { !readOnlyServers.contains(server) }

    /// Makes `server`'s tabs read-only while it is offline, or editable again.
    public mutating func setTabsReadOnly(_ server: ServerId, _ readOnly: Bool) {
        if readOnly {
            readOnlyServers.insert(server)
        } else {
            readOnlyServers.remove(server)
        }
    }

    /// The oldest tab change not sent to `server` yet.
    public func nextTabIntent(_ server: ServerId) -> TabIntent? {
        guard let state = servers[server] else { return nil }
        return state.pendingTabs.first { state.acknowledgedTabs[$0.operation] == nil }
    }

    /// `server` took `operation`: its tabs from `revision` on include it.
    public mutating func acknowledgeTabIntent(_ server: ServerId, _ operation: OperationId, revision: UInt64) {
        guard servers[server]?.pendingTabs.contains(where: { $0.operation == operation }) == true else { return }
        servers[server]?.acknowledgedTabs[operation] = revision
    }

    /// A new connection sends every waiting change again; the server takes
    /// each once.
    public mutating func forgetTabAcknowledgements(_ server: ServerId) {
        servers[server]?.acknowledgedTabs = [:]
    }

    public func hasPendingTabs(_ server: ServerId) -> Bool { !(servers[server]?.pendingTabs.isEmpty ?? true) }

    /// Every tab change `server` hasn't confirmed, oldest first.
    public func pendingTabIntents(_ server: ServerId) -> [TabIntent] { servers[server]?.pendingTabs ?? [] }

    /// `server` refused `operation`, because another app changed the same
    /// tab first: the change disappears and the server's tabs show.
    public mutating func completeTabIntent(_ server: ServerId, _ operation: OperationId) {
        guard var state = servers[server] else { return }
        state.pendingTabs.removeAll { $0.operation == operation }
        state.acknowledgedTabs[operation] = nil
        servers[server] = state
        materializeTabs(server)
    }

    public func tabsRevision(_ server: ServerId) -> UInt64? { servers[server]?.tabs?.revision }

    /// The panes `server` has said it keeps.
    public func confirmedPanes(_ server: ServerId) -> Set<PaneId> {
        Set((servers[server]?.tabs?.projects ?? []).flatMap(\.tabs).flatMap(\.panes).map(\.id))
    }

    /// Shows the tabs `server` sent, with this app's changes it hasn't
    /// applied yet on top. The server's word wins: the caller drops a
    /// snapshot older than one it already applied from the same connection.
    public mutating func applyTabs(_ server: ServerId, _ snapshot: TabsSnapshot) {
        var state = servers[server] ?? ServerState()
        let applied = Set(snapshot.applied)
        let acknowledged = state.acknowledgedTabs
        let included = { (intent: TabIntent) in
            applied.contains(intent.operation) || acknowledged[intent.operation].map { $0 <= snapshot.revision } == true
        }
        let done = state.pendingTabs.filter(included).map(\.operation)
        state.pendingTabs.removeAll(where: included)
        for operation in done { state.acknowledgedTabs[operation] = nil }
        state.tabs = snapshot
        servers[server] = state
        materializeTabs(server)
    }

    /// The tabs this app kept for `server` before servers kept them, as the
    /// changes that hand them over.
    public func legacyTabIntents(_ server: ServerId) -> [TabMutation] {
        (servers[server]?.legacyTabs ?? []).map { .adoptTabs(project: $0.project, tabs: $0.tabs) }
    }

    /// `server` took the tabs this app kept for it.
    public mutating func completeLegacyTabs(_ server: ServerId) {
        guard servers[server]?.legacyTabs.isEmpty == false else { return }
        servers[server]?.legacyTabs = []
        materializeTabs(server)
    }

    // MARK: Showing tabs

    /// Recomputes `server`'s tabs from its snapshot, the tabs kept from
    /// before, and the changes on their way, then repairs selection and focus.
    mutating func materializeTabs(_ server: ServerId, repair: Bool = true) {
        guard let home = serverHome(server)?.id else { return }
        let state = servers[server] ?? ServerState()
        var board = TabBoard(home: home, projects: state.tabs?.projects ?? [])
        let isProject: (ProjectId) -> Bool = { [projects] id in projects.contains { $0.id == id && $0.serverId == server } }
        for legacy in state.legacyTabs {
            _ = try? TabReducer.apply(.adoptTabs(project: legacy.project, tabs: legacy.tabs), to: &board, isProject: isProject)
        }
        for intent in state.pendingTabs {
            _ = try? TabReducer.apply(intent.mutation, to: &board, isProject: isProject)
        }
        show(board, of: server, repair: repair)
    }

    /// Puts `board` in `server`'s projects with this app's titles and zoom.
    private mutating func show(_ board: TabBoard, of server: ServerId, repair: Bool = true) {
        var previous: [ProjectId: [Tab]] = [:]
        for index in projects.indices where projects[index].serverId == server {
            previous[projects[index].id] = projects[index].tabs
            projects[index].tabs = board.tabs(projects[index].id).map(decorated)
        }
        if repair { repairWindow(previous: previous) }
    }

    private func decorated(_ tab: Tab) -> Tab {
        var tab = tab
        tab.zoomed = window.zoomed[tab.id].flatMap { tab.layout.contains($0) ? $0 : nil }
        for index in tab.panes.indices {
            tab.panes[index].title = paneTitles[tab.panes[index].id] ?? tab.panes[index].content.defaultTitle
        }
        return tab
    }

    /// Keeps the window valid after tabs or panes went away: a closed tab's
    /// neighbor is selected, a closed pane's neighbor takes focus, and in
    /// Home the most recently focused pane does.
    private mutating func repairWindow(previous: [ProjectId: [Tab]]) {
        let current = projects.flatMap(\.tabs)
        let panes = Set(current.flatMap(\.panes).map(\.id))
        let removed = previous.values.flatMap { $0 }.flatMap(\.panes).map(\.id).filter { !panes.contains($0) }
        for pane in removed {
            paneTitles[pane] = nil
            agentComposerDrafts[pane] = nil
        }
        window.focusHistory.removeAll { !panes.contains($0) }
        window.zoomed = Dictionary(uniqueKeysWithValues: current.compactMap { tab in tab.zoomed.map { (tab.id, $0) } })
        for (projectId, old) in previous {
            guard let project = project(projectId) else { continue }
            if let selected = window.selectedTab[projectId], !project.tabs.contains(where: { $0.id == selected }) {
                window.selectedTab[projectId] = Self.survivor(of: selected, before: old, now: project.tabs)
            }
            if window.selectedTab[projectId] == nil { window.selectedTab[projectId] = project.tabs.first?.id }
        }
        if let active = window.activePane, !panes.contains(active) {
            window.activePane = nil
            refocus(after: active, previous: previous)
        }
        let selected = window.selectedTab[window.currentProject]
        if let active = window.activePane,
           !currentProject.tabs.contains(where: { $0.id == selected && $0.layout.contains(active) })
        {
            window.activePane = nil
        }
        if window.activePane == nil { focusSelectedTab() }
    }

    /// Focuses what takes the place of `pane`, which went away.
    private mutating func refocus(after pane: PaneId, previous: [ProjectId: [Tab]]) {
        guard let (projectId, old) = previous.lazy.compactMap({ entry in
            entry.value.first { $0.layout.contains(pane) }.map { (entry.key, $0) }
        }).first, let project = project(projectId) else { return }
        if let tab = project.tabs.first(where: { $0.id == old.id }) {
            let neighbor = [Direction.right, .left, .down, .up].lazy
                .compactMap { old.layout.neighbor(of: pane, $0) }
                .first { tab.layout.contains($0) }
            window.activate(neighbor ?? tab.layout.leaves.first)
            return
        }
        if project.home, let recent = window.focusHistory.reversed().first(where: { candidate in
            projects.contains { $0.status == .available && $0.tabs.contains { $0.layout.contains(candidate) } }
        }), (try? focusPane(recent)) != nil {
            return
        }
        focusSelectedTab()
    }

    /// The tab shown once `tab` is gone: the next one that is still there,
    /// else the previous one.
    private static func survivor(of tab: TabId, before: [Tab], now: [Tab]) -> TabId? {
        guard let index = before.firstIndex(where: { $0.id == tab }) else { return now.first?.id }
        let kept = Set(now.map(\.id))
        if let next = before[(index + 1)...].first(where: { kept.contains($0.id) }) { return next.id }
        return before[..<index].last { kept.contains($0.id) }?.id ?? now.first?.id
    }
}
