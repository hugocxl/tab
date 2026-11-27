import Foundation

/// What the app keeps per server: its identity, queued project edits, and
/// its tabs with this app's changes on their way to it.
struct ServerState: Codable, Equatable, Sendable {
    /// The server that answered last time; another one is refused.
    var identity: ServerId?
    var catalogRevision: UInt64 = 0
    var projectIntents: [ProjectIntent] = []
    /// The server's tabs as it last sent them, shown until it sends newer.
    var tabs: TabsSnapshot?
    /// Tabs this app kept before servers kept them, until the server takes them.
    var legacyTabs: [ProjectTabs] = []
    /// Tab changes made here that the server hasn't confirmed, oldest first.
    /// Saved, so a change made while the server can't be reached survives a
    /// relaunch; its operation id makes sending it again safe.
    var pendingTabs: [TabIntent] = []
    /// The revision at which the server took each pending change, which
    /// stays shown until a snapshot that new arrives. Not saved: sending a
    /// change again is safe.
    var acknowledgedTabs: [OperationId: UInt64] = [:]

    init() {}

    enum CodingKeys: String, CodingKey {
        case identity, catalogRevision, projectIntents, tabs, legacyTabs, pendingTabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decodeIfPresent(ServerId.self, forKey: .identity)
        catalogRevision = try container.value(.catalogRevision, 0)
        projectIntents = try container.value(.projectIntents, [])
        tabs = try container.decodeIfPresent(TabsSnapshot.self, forKey: .tabs)
        legacyTabs = try container.value(.legacyTabs, [])
        pendingTabs = try container.value(.pendingTabs, [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(identity, forKey: .identity)
        try container.encode(catalogRevision, forKey: .catalogRevision)
        if !projectIntents.isEmpty { try container.encode(projectIntents, forKey: .projectIntents) }
        try container.encodeIfPresent(tabs, forKey: .tabs)
        if !legacyTabs.isEmpty { try container.encode(legacyTabs, forKey: .legacyTabs) }
        if !pendingTabs.isEmpty { try container.encode(pendingTabs, forKey: .pendingTabs) }
    }
}

// Which server each project and pane belongs to, and the edits waiting for
// each server. Session ids are per server, so session state lives with it.
extension AppState {
    /// The most project edits a server can have waiting.
    public static let maximumProjectIntents = 1024

    public func projectServer(_ project: ProjectId) -> ServerId? { self.project(project)?.serverId }

    public func paneServer(_ pane: PaneId) -> ServerId? {
        projects.first { $0.tabs.contains { $0.pane(pane) != nil } }?.serverId
    }

    /// A remote server has a Home once its catalog has been applied.
    public func serverHome(_ server: ServerId) -> Project? {
        projects.first { $0.home && $0.serverId == server }
    }

    /// Sessions shown by `server`'s panes, sorted and without repeats.
    public func sessionReferences(_ server: ServerId) -> [SessionId] {
        Set(projects.filter { $0.serverId == server }.flatMap(\.tabs).flatMap(\.panes).compactMap(\.content.session))
            .sorted()
    }

    // MARK: Catalog

    public func projectIntents(_ server: ServerId) -> [ProjectIntent] { servers[server]?.projectIntents ?? [] }

    /// Whether `project` still waits for its server to create it, even if it
    /// was removed in the meantime.
    public func projectCreationPending(_ project: ProjectId) -> Bool {
        servers.values.flatMap(\.projectIntents).contains {
            if case .create(let record) = $0.mutation { return record.id == project }
            return false
        }
    }

    public func catalogRevision(_ server: ServerId) -> UInt64 { servers[server]?.catalogRevision ?? 0 }

    /// The identity of the server that answered for the `server` entry last time.
    public func serverIdentity(_ server: ServerId) -> ServerId? { servers[server]?.identity }

    /// How many more project edits `server` can hold before it confirms some.
    public func projectIntentCapacity(_ server: ServerId) -> Int {
        max(0, Self.maximumProjectIntents - projectIntents(server).count)
    }

    mutating func queueProject(_ server: ServerId, _ mutation: ProjectMutation) throws {
        try mutation.check()
        guard projectIntentCapacity(server) > 0 else {
            throw AppError.invalidState("pending project edits are full; reconnect before editing more projects")
        }
        var state = servers[server] ?? ServerState()
        state.projectIntents.append(ProjectIntent(mutation: mutation))
        servers[server] = state
    }

    /// The server confirmed its oldest waiting edit.
    public mutating func completeProjectIntent(_ server: ServerId, _ operation: OperationId) throws {
        guard servers[server]?.projectIntents.first?.operation == operation else {
            throw AppError.invalidState("project acknowledgement is out of order")
        }
        servers[server]?.projectIntents.removeFirst()
    }

    /// Removes a worktree project deleted outside Tab, unless it has panes
    /// or edits waiting.
    public mutating func pruneWorktree(_ id: ProjectId) throws {
        guard let project = project(id), project.kind == .worktree, project.parentId != nil, project.tabs.isEmpty else {
            return
        }
        let waiting = projectIntents(project.serverId).contains { intent in
            switch intent.mutation {
            case .create(let record): return record.id == id
            case .delete(let other), .pruneWorktree(let other): return other == id
            case .rename: return false
            }
        }
        guard !waiting else { return }
        _ = try removeProject(id, mutation: .pruneWorktree(id))
    }

    /// Replaces `server`'s projects with its catalog, overlaid with the
    /// edits still waiting for it. Other servers' projects are untouched.
    /// Nothing changes when the catalog is refused.
    public mutating func applyCatalog(_ server: ServerId, _ catalog: CatalogPage) throws {
        guard catalog.next == nil else { throw AppError.invalidState("incomplete project catalog") }
        if let identity = servers[server]?.identity, identity != catalog.server {
            throw AppError.serverChanged(server)
        }
        if let existing = servers.first(where: { $0.key != server && $0.value.identity == catalog.server })?.key {
            throw AppError.duplicateServer(server: server, existing: existing)
        }
        var next = self
        try next.mergeCatalog(server, catalog)
        try next.validate()
        var state = next.servers[server] ?? ServerState()
        state.identity = catalog.server
        state.catalogRevision = catalog.revision
        next.servers[server] = state
        self = next
    }

    private mutating func mergeCatalog(_ server: ServerId, _ catalog: CatalogPage) throws {
        remapHome(server, to: catalog.home)
        var descriptors = Dictionary(catalog.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for intent in projectIntents(server) {
            switch intent.mutation {
            case .create(let project):
                descriptors[project.id] = project
            case let .rename(project, name):
                descriptors[project]?.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            case .delete(let project), .pruneWorktree(let project):
                descriptors = descriptors.filter { $0.key != project && $0.value.parentId != project }
            }
        }
        projects.removeAll { $0.serverId == server && descriptors[$0.id] == nil }
        for index in projects.indices where projects[index].serverId == server {
            if let descriptor = descriptors.removeValue(forKey: projects[index].id) {
                projects[index].apply(descriptor)
            }
        }
        for descriptor in catalog.projects where descriptors[descriptor.id] != nil {
            projects.append(Project(server: server, descriptor: descriptor))
            descriptors[descriptor.id] = nil
        }
        for descriptor in descriptors.values.sorted(by: { $0.id < $1.id }) {
            projects.append(Project(server: server, descriptor: descriptor))
        }
        guard let home = projects.firstIndex(where: { $0.id == catalog.home && $0.serverId == server }) else {
            throw AppError.invalidState("catalog has no Home")
        }
        placeHome(home)
        retainWorkspaceMembers()
        let projectIds = Set(projects.map(\.id))
        window.selectedTab = window.selectedTab.filter { projectIds.contains($0.key) }
        if !projectIds.contains(window.currentProject) { window.currentProject = catalog.home }
        materializeTabs(server)
    }

    /// A server whose Home has a new id keeps its old Home's tabs.
    private mutating func remapHome(_ server: ServerId, to home: ProjectId) {
        guard let old = serverHome(server)?.id, old != home else { return }
        if let index = projects.firstIndex(where: { $0.id == old }) { projects[index].id = home }
        if window.currentProject == old { window.currentProject = home }
        if let tab = window.selectedTab.removeValue(forKey: old) { window.selectedTab[home] = tab }
        guard var state = servers[server] else { return }
        for index in state.projectIntents.indices {
            switch state.projectIntents[index].mutation {
            case let .rename(project, name) where project == old:
                state.projectIntents[index].mutation = .rename(project: home, name: name)
            case .delete(let project) where project == old:
                state.projectIntents[index].mutation = .delete(home)
            default:
                break
            }
        }
        for index in state.pendingTabs.indices {
            switch state.pendingTabs[index].mutation {
            case let .createTab(project, tab, after) where project == old:
                state.pendingTabs[index].mutation = .createTab(project: home, tab: tab, after: after)
            case let .adoptTabs(project, tabs) where project == old:
                state.pendingTabs[index].mutation = .adoptTabs(project: home, tabs: tabs)
            default:
                break
            }
        }
        for index in state.legacyTabs.indices where state.legacyTabs[index].project == old {
            state.legacyTabs[index].project = home
        }
        if var snapshot = state.tabs {
            for index in snapshot.projects.indices where snapshot.projects[index].project == old {
                snapshot.projects[index].project = home
            }
            state.tabs = snapshot
        }
        servers[server] = state
    }

    /// Removes `server`'s projects with their tabs and workspace memberships,
    /// and what the app kept for it. Nothing changes on the server.
    public mutating func forgetServer(_ server: ServerId) throws {
        guard !server.isLocal else { throw AppError.invalidState("this computer's server cannot be forgotten") }
        removeRemoteProjects(server)
        servers[server] = nil
    }

    /// Removes a remote server's projects and every reference to them. The
    /// window moves to the local Home if it showed one of them.
    mutating func removeRemoteProjects(_ server: ServerId) {
        guard !server.isLocal else { return }
        let removed = projects.filter { $0.serverId == server }
        projects.removeAll { $0.serverId == server }
        let projectIds = Set(removed.map(\.id))
        let panes = Set(removed.flatMap(\.tabs).flatMap(\.panes).map(\.id))
        window.selectedTab = window.selectedTab.filter { !projectIds.contains($0.key) }
        window.focusHistory.removeAll { panes.contains($0) }
        paneTitles = paneTitles.filter { !panes.contains($0.key) }
        window.zoomed = window.zoomed.filter { !panes.contains($0.value) }
        retainWorkspaceMembers()
        if projectIds.contains(window.currentProject) {
            window.currentProject = home.id
            window.activePane = nil
            focusSelectedTab()
        }
    }
}

// MARK: Workspaces

extension AppState {
    public func workspace(_ id: WorkspaceId) -> Workspace? { workspaces.first { $0.id == id } }

    /// The workspace filtering the sidebar; `nil` lists every project.
    public var activeWorkspace: Workspace? { window.workspace.flatMap(workspace) }

    /// Whether the fixed Remote Servers workspace filters the sidebar.
    public var remoteServersSelected: Bool { window.remoteServers }

    /// Whether the sidebar lists `project` now. Remote Servers lists each
    /// remote server's Home and nothing else; every other workspace lists
    /// this computer's Home, and worktrees follow their parent.
    public func isListed(_ project: Project) -> Bool {
        if project.isRemoteHome || window.remoteServers {
            return project.isRemoteHome && window.remoteServers
        }
        guard let workspace = activeWorkspace else { return true }
        return project.home || workspace.projects.contains(project.parentId ?? project.id)
    }

    @discardableResult
    public mutating func createWorkspace(_ name: String) throws -> WorkspaceId {
        let workspace = Workspace(name: try Self.workspaceName(name))
        workspaces.append(workspace)
        return workspace.id
    }

    public mutating func renameWorkspace(_ id: WorkspaceId, to name: String) throws {
        let index = try workspaceIndex(id)
        workspaces[index].name = try Self.workspaceName(name)
    }

    public mutating func deleteWorkspace(_ id: WorkspaceId) throws {
        workspaces.remove(at: try workspaceIndex(id))
        if window.workspace == id { window.workspace = nil }
    }

    public mutating func selectWorkspace(_ id: WorkspaceId?) throws {
        if let id { _ = try workspaceIndex(id) }
        window.workspace = id
        window.remoteServers = false
    }

    /// Remembers whether New Terminal in Project makes a new worktree.
    public mutating func setNewTerminalInWorktree(_ inWorktree: Bool) {
        window.newTerminalInWorktree = inWorktree
    }

    /// Filters the sidebar to each remote server's Home.
    public mutating func selectRemoteServers() {
        window.workspace = nil
        window.remoteServers = true
    }

    /// Adds or removes a top-level project other than Home.
    public mutating func setWorkspaceMember(_ id: WorkspaceId, project: ProjectId, member: Bool) throws {
        guard let candidate = self.project(project) else { throw AppError.unknownProject(project) }
        guard !candidate.home, candidate.parentId == nil else {
            throw AppError.invalidState("only top-level projects other than Home can join a workspace")
        }
        let index = try workspaceIndex(id)
        if member {
            workspaces[index].projects.insert(project)
        } else {
            workspaces[index].projects.remove(project)
        }
    }

    /// Adds an opened project, or a worktree's parent, to the active
    /// workspace; Home is skipped. No project joins Remote Servers, so the
    /// sidebar goes back to all projects instead.
    public mutating func joinActiveWorkspace(_ project: ProjectId) {
        let root = self.project(project).map { $0.parentId ?? $0.id } ?? project
        if let id = window.workspace { try? setWorkspaceMember(id, project: root, member: true) }
        window.remoteServers = false
    }

    /// Whether the sidebar shows `project`'s tabs: every Home's tabs are
    /// listed under their host whatever the workspace, other projects only
    /// when listed.
    public func showsTabs(of project: Project) -> Bool {
        project.home || isListed(project)
    }

    /// Keeps the current project shown by switching to a workspace that
    /// contains it, or to all projects.
    public mutating func revealCurrentProject() {
        let current = currentProject
        guard !showsTabs(of: current) else { return }
        let root = current.parentId ?? current.id
        window.remoteServers = false
        window.workspace = workspaces.first { $0.projects.contains(root) }?.id
    }

    mutating func retainWorkspaceMembers() {
        let members = Set(projects.filter { !$0.home && $0.parentId == nil }.map(\.id))
        for index in workspaces.indices { workspaces[index].projects.formIntersection(members) }
        if activeWorkspace == nil { window.workspace = nil }
        if !projects.contains(where: \.isRemoteHome) { window.remoteServers = false }
    }

    private func workspaceIndex(_ id: WorkspaceId) throws -> Int {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw AppError.invalidState("unknown workspace")
        }
        return index
    }

    private static func workspaceName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidState("workspace name cannot be empty") }
        return name
    }
}

// MARK: Browser panes

extension AppState {
    /// Opens a browser pane in `project`'s tab, or as a new tab in Home.
    /// With `select`, the window shows it; otherwise it waits there without
    /// moving the user's view.
    @discardableResult
    public mutating func openBrowser(_ project: ProjectId, _ browser: BrowserPane, select: Bool) throws -> (TabId, PaneId) {
        let pane = Pane(content: .browser(browser))
        if isSingleTab(project) {
            let (tab, id) = try openPaneInContainer(project, pane: pane, focusLeaf: window.activePane)
            if select {
                try selectProject(project)
                try selectTab(project, tab)
                try focusPane(id)
            }
            return (tab, id)
        }
        try projects[projectIndex(project)].requireAvailable()
        let tab = try addTab(project, Tab(pane: pane))
        if select {
            try selectProject(project)
            try selectTab(project, tab)
        }
        return (tab, pane.id)
    }

    /// Splits `pane` with a browser on its right.
    @discardableResult
    public mutating func splitBrowser(_ pane: PaneId, _ browser: BrowserPane, focus: Bool,
                                      edge: Direction = .right) throws -> PaneId {
        let new = Pane(content: .browser(browser))
        try insertSplitPane(after: pane, new, edge: edge)
        if focus { try focusPane(new.id) }
        return new.id
    }

    public func browser(_ pane: PaneId) -> BrowserPane? {
        if case .browser(let browser) = self.pane(pane)?.content { return browser }
        return nil
    }

    /// The browser pane `id` names: that pane, or the one a tab of that id
    /// shows, else the tab's first browser pane.
    public func browserPane(named id: String) -> PaneId? {
        if let pane = PaneId(id), browser(pane) != nil { return pane }
        guard let tabId = TabId(id), let tab = projects.lazy.flatMap(\.tabs).first(where: { $0.id == tabId }) else {
            return nil
        }
        if let shown = shownPane(tab), browser(shown) != nil { return shown }
        return tab.layout.leaves.first { browser($0) != nil }
    }

    /// Records the page a browser pane shows, reporting whether it changed.
    @discardableResult
    public mutating func setBrowserURL(_ pane: PaneId, _ url: String?) throws -> Bool {
        guard var browser = browser(pane) else { throw AppError.invalidState("pane is not a browser") }
        let url = url.flatMap { BrowserAddress.isBlank($0) ? nil : $0 }
        guard browser.url != url else { return false }
        browser.url = url
        try changePane(pane, .browser(browser))
        return true
    }

    @discardableResult
    public mutating func setBrowserProfile(_ pane: PaneId, _ profile: String?) throws -> Bool {
        guard var browser = browser(pane) else { throw AppError.invalidState("pane is not a browser") }
        guard browser.profile != profile else { return false }
        browser.profile = profile
        try changePane(pane, .browser(browser))
        return true
    }

    /// Changes what a browser or simulator pane shows, on its server.
    private mutating func changePane(_ pane: PaneId, _ content: PaneContent) throws {
        guard let server = paneServer(pane) else { throw AppError.unknownPane(pane) }
        try perform(server, .updatePane(pane, content: content))
    }
}

// MARK: Simulator panes

extension AppState {
    /// Opens a simulator pane in `project`'s tab, or as a new tab in Home, like
    /// `openBrowser`.
    @discardableResult
    public mutating func openSimulator(_ project: ProjectId, _ simulator: SimulatorPane, select: Bool) throws -> (TabId, PaneId) {
        let pane = Pane(content: .simulator(simulator))
        if isSingleTab(project) {
            let (tab, id) = try openPaneInContainer(project, pane: pane, focusLeaf: window.activePane)
            if select {
                try selectProject(project)
                try selectTab(project, tab)
                try focusPane(id)
            }
            return (tab, id)
        }
        try projects[projectIndex(project)].requireAvailable()
        let tab = try addTab(project, Tab(pane: pane))
        if select {
            try selectProject(project)
            try selectTab(project, tab)
        }
        return (tab, pane.id)
    }

    public func simulator(_ pane: PaneId) -> SimulatorPane? {
        if case .simulator(let simulator) = self.pane(pane)?.content { return simulator }
        return nil
    }

    /// Records the simulator a simulator pane shows, reporting whether it changed.
    @discardableResult
    public mutating func setSimulator(_ pane: PaneId, _ simulator: SimulatorPane) throws -> Bool {
        guard let current = self.simulator(pane) else { throw AppError.invalidState("pane is not a simulator") }
        guard current != simulator else { return false }
        try changePane(pane, .simulator(simulator))
        if paneTitles[pane] == nil { try updatePane(pane) { $0.title = $0.content.defaultTitle } }
        return true
    }
}

// MARK: Restore

/// A pane and the session it shows.
public struct PaneSession: Hashable, Sendable {
    public var pane: PaneId
    public var session: SessionId

    public init(_ pane: PaneId, _ session: SessionId) {
        self.pane = pane
        self.session = session
    }
}

/// A session a server lists, with the project it belongs to.
public struct LiveSession: Hashable, Sendable {
    public var project: ProjectId
    public var session: SessionId

    public init(project: ProjectId, session: SessionId) {
        self.project = project
        self.session = session
    }
}

/// What to do with a server's terminal panes after connecting to it. Panes
/// whose terminal ended are the server's to remove.
public struct RestorePlan: Equatable, Sendable {
    /// Panes whose session is still running.
    public var attach: [PaneSession] = []
    /// Panes that never got a session, in available projects.
    public var create: [PaneId] = []

    public init() {}

    /// Plans `server`'s panes against the sessions that server listed.
    public static func plan(_ state: AppState, server: ServerId, sessions: [LiveSession]) -> RestorePlan {
        let live = Set(sessions)
        var plan = RestorePlan()
        for project in state.projects where project.serverId == server {
            for pane in project.tabs.flatMap(\.panes) {
                guard case .terminal(let session) = pane.content else { continue }
                if let session {
                    if live.contains(LiveSession(project: project.id, session: session)) {
                        plan.attach.append(PaneSession(pane.id, session))
                    }
                } else if project.status == .available {
                    plan.create.append(pane.id)
                }
            }
        }
        return plan
    }
}

// MARK: Store

/// Reads and writes `state.json`.
public enum AppStateStore {
    /// The saved state, or a fresh one when there is no file. A file that
    /// does not load is an error naming it, and is left as it is.
    public static func load(_ url: URL) throws -> AppState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return try AppState.bootstrap()
        } catch {
            throw AppError.io(path: url.path, message: error.localizedDescription)
        }
        do {
            return try decode(data)
        } catch {
            throw AppError.json(path: url.path, message: SettingsJSON.describe(error))
        }
    }

    public static func decode(_ data: Data) throws -> AppState {
        try JSONDecoder().decode(AppState.self, from: data)
    }

    public static func encode(_ state: AppState) throws -> Data {
        try SettingsJSON.encode(state)
    }

    /// Replaces the file atomically, readable only by this user.
    public static func save(_ state: AppState, to url: URL) throws {
        do {
            try AtomicFile.write(encode(state), to: url)
        } catch {
            throw AppError.io(path: url.path, message: error.localizedDescription)
        }
    }
}
