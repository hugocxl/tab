import Foundation

/// The app's projects, workspaces and window state, saved as `state.json`.
/// Every change keeps it valid: Home first, layouts matching their panes,
/// focus inside the selected tab.
///
/// Each server keeps its projects' tabs. `Project.tabs` shows them: the
/// server's last word with this app's changes still on their way on top,
/// and this app's own titles and zoom. Every non-Home project has zero or
/// one tab holding its split layout; Home keeps one tab per card.
public struct AppState: Codable, Equatable, Sendable {
    /// The state format this build writes.
    public static let currentVersion = 1

    public var agentComposerDefaults: AgentComposerPreferences?
    public internal(set) var agentComposerDrafts: [PaneId: AgentComposerPreferences] = [:]
    var servers: [ServerId: ServerState]
    /// The titles panes reported here, such as a terminal's or a page's.
    var paneTitles: [PaneId: String]
    /// Servers whose tabs can't change now: they are offline.
    var readOnlyServers: Set<ServerId> = []
    public private(set) var version: Int
    public internal(set) var projects: [Project]
    public internal(set) var workspaces: [Workspace]
    public internal(set) var window: WindowState

    enum CodingKeys: String, CodingKey {
        case agentComposerDefaults, agentComposerDrafts, servers, paneTitles, version, projects, workspaces, window
    }

    /// A fresh state: just this computer's Home.
    public static func bootstrap() throws -> AppState {
        let home = try newHome(directory: homeDirectory())
        return AppState(
            servers: [:],
            paneTitles: [:],
            version: currentVersion,
            projects: [home],
            workspaces: [],
            window: WindowState(currentProject: home.id)
        )
    }

    private init(
        servers: [ServerId: ServerState],
        paneTitles: [PaneId: String],
        version: Int,
        projects: [Project],
        workspaces: [Workspace],
        window: WindowState
    ) {
        self.servers = servers
        self.paneTitles = paneTitles
        self.version = version
        self.projects = projects
        self.workspaces = workspaces
        self.window = window
    }

    /// Only repairs focus on a removed management pane; unknown references remain errors.
    private static func isRetiredPane(_ id: PaneId, in container: KeyedDecodingContainer<CodingKeys>) throws -> Bool {
        enum ContentKeys: String, CodingKey { case type }
        enum TabKeys: String, CodingKey { case panes }
        enum PaneKeys: String, CodingKey { case id, content }
        var projects = try container.nestedUnkeyedContainer(forKey: .projects)
        while !projects.isAtEnd {
            let project = try projects.nestedContainer(keyedBy: Project.CodingKeys.self)
            guard project.contains(.tabs) else { continue }
            var tabs = try project.nestedUnkeyedContainer(forKey: .tabs)
            while !tabs.isAtEnd {
                let tab = try tabs.nestedContainer(keyedBy: TabKeys.self)
                var panes = try tab.nestedUnkeyedContainer(forKey: .panes)
                while !panes.isAtEnd {
                    let pane = try panes.nestedContainer(keyedBy: PaneKeys.self)
                    guard try pane.decode(PaneId.self, forKey: .id) == id else { continue }
                    let content = try pane.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
                    return try content.decode(String.self, forKey: .type) == "servers"
                }
            }
        }
        return false
    }

    /// Loads saved state, repairing what can be repaired (Home, selection,
    /// focus, single-tab projects) and refusing what cannot.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: AppError.unsupportedVersion(version).description
            )
        }
        self.init(
            servers: try container.value(.servers, [:]),
            paneTitles: try container.value(.paneTitles, [:]),
            version: version,
            projects: try container.decode([Project].self, forKey: .projects),
            workspaces: try container.value(.workspaces, []),
            window: try container.decode(WindowState.self, forKey: .window)
        )
        if let active = window.activePane, pane(active) == nil,
           try Self.isRetiredPane(active, in: container) {
            window.activePane = nil
        }
        agentComposerDefaults = try container.decodeIfPresent(AgentComposerPreferences.self, forKey: .agentComposerDefaults)
        agentComposerDrafts = try container.value(.agentComposerDrafts, [:])
        keepLegacyTabs()
        do {
            try repairLoaded()
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(agentComposerDefaults, forKey: .agentComposerDefaults)
        if !agentComposerDrafts.isEmpty { try container.encode(agentComposerDrafts, forKey: .agentComposerDrafts) }
        try container.encode(servers, forKey: .servers)
        if !paneTitles.isEmpty { try container.encode(paneTitles, forKey: .paneTitles) }
        try container.encode(version, forKey: .version)
        try container.encode(projects, forKey: .projects)
        if !workspaces.isEmpty { try container.encode(workspaces, forKey: .workspaces) }
        try container.encode(window, forKey: .window)
    }

    /// Moves tabs `state.json` kept before servers kept them aside, to give
    /// to their servers, with this app's titles and zoom.
    private mutating func keepLegacyTabs() {
        for index in projects.indices where !projects[index].tabs.isEmpty {
            let project = projects[index]
            var state = servers[project.serverId] ?? ServerState()
            state.legacyTabs.append(ProjectTabs(project: project.id, tabs: project.tabs))
            servers[project.serverId] = state
            for tab in project.tabs {
                if let zoomed = tab.zoomed { window.zoomed[tab.id] = zoomed }
                for pane in tab.panes where pane.title != pane.content.defaultTitle { paneTitles[pane.id] = pane.title }
            }
        }
    }

    private mutating func repairLoaded() throws {
        let previousProject = window.currentProject
        let previousTab = window.selectedTab[previousProject]
        try ensureHome()
        retainWorkspaceMembers()
        for server in Set(projects.map(\.serverId)) { materializeTabs(server, repair: false) }
        let panes = Set(projects.flatMap(\.tabs).flatMap(\.panes).map(\.id))
        if window.currentProject != previousProject { window.activePane = nil }
        if let active = window.activePane, !panes.contains(active) { window.activePane = nil }
        if let active = window.activePane {
            // Tabs kept from before may have merged into one: focus stays.
            if let tab = currentProject.tabs.first(where: { $0.layout.contains(active) }) {
                window.selectedTab[window.currentProject] = tab.id
            } else {
                window.activePane = nil
            }
        }
        window.selectedTab = window.selectedTab.filter { projectId, tab in
            project(projectId)?.tabs.contains { $0.id == tab } ?? false
        }
        for project in projects {
            if let tab = project.tabs.first, window.selectedTab[project.id] == nil {
                window.selectedTab[project.id] = tab.id
            }
        }
        if window.selectedTab[window.currentProject] != previousTab, let active = window.activePane,
           !currentProject.tabs.contains(where: { $0.id == window.selectedTab[window.currentProject] && $0.layout.contains(active) })
        {
            window.activePane = nil
        }
        window.focusHistory.removeAll { !panes.contains($0) }
        focusSelectedTab()
        try validate()
    }

    // MARK: Reading

    public func project(_ id: ProjectId) -> Project? { projects.first { $0.id == id } }

    /// This computer's Home, always first.
    public var home: Project { projects[0] }

    public var currentProject: Project { project(window.currentProject) ?? home }

    /// The pane `tab` shows as its own: the active pane, or the one last
    /// focused in it.
    public func shownPane(_ tab: Tab) -> PaneId? {
        ([window.activePane].compactMap { $0 } + window.focusHistory.reversed()).first { tab.layout.contains($0) }
    }

    public func neighbor(of pane: PaneId, _ direction: Direction) -> PaneId? {
        projects.lazy.flatMap(\.tabs).first { $0.layout.contains(pane) }?.layout.neighbor(of: pane, direction)
    }

    /// The project whose tab holds `pane`.
    public func paneProject(_ pane: PaneId) -> ProjectId? {
        projects.first { $0.tabs.contains { $0.pane(pane) != nil } }?.id
    }

    /// The pane showing the terminal or agent conversation `session`.
    public func paneShowing(_ session: SessionId) -> PaneId? {
        projects.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.content.activitySession == session }?.id
    }

    public func pane(_ id: PaneId) -> Pane? {

        for project in projects {
            for tab in project.tabs {
                if let pane = tab.pane(id) { return pane }
            }
        }
        return nil
    }

    // MARK: Projects

    public mutating func refreshProjectStatuses() {
        for index in projects.indices { projects[index].refreshStatus() }
    }

    /// Another computer's server says whether the project's folder is there.
    /// This computer's projects are checked on disk instead.
    public mutating func setRemoteProjectStatus(_ project: ProjectId, _ status: ProjectStatus) throws {
        let index = try projectIndex(project)
        guard !projects[index].serverId.isLocal else {
            throw AppError.invalidState("this computer's projects are checked on disk")
        }
        projects[index].status = status
    }

    /// An offline server's projects are available: nothing says otherwise.
    public mutating func forgetRemoteStatuses(_ server: ServerId) {
        guard !server.isLocal else { return }
        for index in projects.indices where projects[index].serverId == server {
            projects[index].status = .available
        }
    }

    public mutating func selectProject(_ id: ProjectId) throws {
        try projects[projectIndex(id)].requireAvailable()
        window.currentProject = id
        focusSelectedTab()
    }

    /// Adds the folder as a project of `server` and selects it. A remote
    /// server checks the folder itself when it creates the project.
    @discardableResult
    public mutating func addProject(server: ServerId, directory: String) throws -> ProjectId {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
        if server.isLocal && !(directory.hasPrefix("/") && exists) {
            throw AppError.invalidState("project path must be an existing absolute directory")
        }
        guard directory.hasPrefix("/") else { throw AppError.invalidState("project path must be absolute") }
        guard serverHome(server) != nil else {
            throw AppError.invalidState("connect to the server before adding projects to it")
        }
        let descriptor = ProjectDescriptor.new(directory: ServerPath(directory))
        let project = Project(server: server, descriptor: descriptor)
        try queueProject(server, .create(descriptor))
        projects.append(project)
        joinActiveWorkspace(project.id)
        window.currentProject = project.id
        window.activePane = nil
        return project.id
    }

    public mutating func renameProject(_ id: ProjectId, to name: String) throws {
        try projects[projectIndex(id)].requireAvailable()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidState("project name cannot be empty") }
        guard let server = projectServer(id) else { throw AppError.unknownProject(id) }
        try queueProject(server, .rename(project: id, name: name))
        projects[try projectIndex(id)].name = name
    }

    /// Moves a project in the sidebar order. Each server's Home stays first
    /// among its projects.
    public mutating func moveProject(_ id: ProjectId, to destination: Int) throws {
        let from = try projectIndex(id)
        try projects[from].requireAvailable()
        let server = projects[from].serverId
        let serverHome = projects.firstIndex { $0.home && $0.serverId == server }
        guard !projects[from].home, destination < projects.count, let serverHome, destination > serverHome else {
            throw AppError.invalidState("Home stays first; project destination must be in range")
        }
        let project = projects.remove(at: from)
        projects.insert(project, at: destination)
    }

    /// Removes a project with its tabs, returning the sessions its terminals
    /// showed for the caller to end.
    @discardableResult
    public mutating func removeProject(_ id: ProjectId) throws -> [SessionId] {
        try removeProject(id, mutation: .delete(id))
    }

    mutating func removeProject(_ id: ProjectId, mutation: ProjectMutation) throws -> [SessionId] {
        let index = try projectIndex(id)
        guard !projects[index].home else { throw AppError.invalidState("Home cannot be removed") }
        try queueProject(projects[index].serverId, mutation)
        let project = projects.remove(at: index)
        retainWorkspaceMembers()
        window.selectedTab[id] = nil
        window.focusHistory.removeAll { pane in project.tabs.contains { $0.layout.contains(pane) } }
        if window.currentProject == id {
            window.currentProject = home.id
            focusSelectedTab()
        }
        var sessions: [SessionId] = []
        for pane in project.tabs.flatMap(\.panes) {
            paneTitles[pane.id] = nil
            if let session = pane.content.session, !sessions.contains(session) { sessions.append(session) }
        }
        return sessions
    }

    // MARK: Tabs

    /// Opens a terminal: in a project, a new pane in its layout; in Home, a
    /// new standalone tab. Returns the new pane.
    @discardableResult
    public mutating func openTerminal(_ project: ProjectId, launch: TerminalLaunch? = nil) throws -> PaneId {
        let pane = Pane.terminal(launch: launch)
        try openPane(project, pane)
        return pane.id
    }

    /// Opens `pane` in `project` and focuses it: a new tab in Home, else a
    /// pane in the project's tab.
    public mutating func openPane(_ project: ProjectId, _ pane: Pane) throws {
        try projects[projectIndex(project)].requireAvailable()
        let tab: TabId
        if isSingleTab(project) {
            tab = try openPaneInContainer(project, pane: pane, focusLeaf: window.activePane).0
        } else {
            tab = try addTab(project, Tab(pane: pane))
        }
        window.selectedTab[project] = tab
        window.currentProject = project
        try focusPane(pane.id)
    }

    /// Closes a tab with its panes. Focus moves to a neighboring tab, or for
    /// a Home terminal to the most recently focused surviving pane.
    public mutating func closeTab(_ project: ProjectId, _ tab: TabId) throws {
        guard self.project(project)?.tabs.contains(where: { $0.id == tab }) == true else {
            throw AppError.unknownTab(project: project, tab: tab)
        }
        try perform(projects[projectIndex(project)].serverId, .closeTab(tab, keepSessions: false))
    }

    public mutating func selectTab(_ project: ProjectId, _ tab: TabId) throws {
        let p = try projectIndex(project)
        try projects[p].requireAvailable()
        guard projects[p].tabs.contains(where: { $0.id == tab }) else {
            throw AppError.unknownTab(project: project, tab: tab)
        }
        window.selectedTab[project] = tab
        window.currentProject = project
        focusSelectedTab()
    }

    /// Opens a pane in the project's layout, right of `focusLeaf` or its
    /// last pane, creating the layout when the project has none. Does not
    /// change focus.
    @discardableResult
    public mutating func openPaneInContainer(_ project: ProjectId, pane: Pane, focusLeaf: PaneId?) throws -> (TabId, PaneId) {
        let p = try projectIndex(project)
        try projects[p].requireAvailable()
        guard let tab = projects[p].tabs.first else {
            return (try addTab(project, Tab(pane: pane)), pane.id)
        }
        guard let leaf = focusLeaf.flatMap({ tab.layout.contains($0) ? $0 : nil }) ?? tab.layout.leaves.last else {
            throw AppError.invalidState("container has no panes")
        }
        try insertSplitPane(after: leaf, pane, edge: .right)
        return (tab.id, pane.id)
    }

    /// Opens `pane` as a new tab of `project`, which must be Home: other
    /// projects hold a single tab. Selects and focuses it.
    @discardableResult
    public mutating func openTab(_ project: ProjectId, _ pane: Pane) throws -> TabId {
        try projects[projectIndex(project)].requireAvailable()
        guard !isSingleTab(project) else { throw AppError.invalidState("only Home holds several tabs") }
        let tab = try addTab(project, Tab(pane: pane))
        try selectProject(project)
        try selectTab(project, tab)
        try focusPane(pane.id)
        revealCurrentProject()
        return tab
    }

    func isSingleTab(_ project: ProjectId) -> Bool {
        self.project(project).map { !$0.home } ?? false
    }

    /// Adds `tab` to `project`, returning the tab that holds its panes: a
    /// project other than Home that has a tab already merges it in.
    @discardableResult
    mutating func addTab(_ project: ProjectId, _ tab: Tab) throws -> TabId {
        let p = try projectIndex(project)
        try perform(projects[p].serverId, .createTab(project: project, tab: tab, after: nil))
        guard let leaf = tab.layout.leaves.first else { return tab.id }
        return projects[p].tabs.first { $0.layout.contains(leaf) }?.id ?? tab.id
    }

    // MARK: Panes

    public mutating func closePane(_ pane: PaneId) throws {
        _ = try availablePaneTab(pane)
        try removePane(pane, keepSession: false)
    }

    /// Closes the pane but leaves its terminal running.
    public mutating func detachPane(_ pane: PaneId) throws {
        _ = try availablePaneTab(pane)
        try removePane(pane, keepSession: true)
    }

    /// Removes a pane, even in a project whose folder is missing. Its
    /// neighbor takes focus, and the row it leaves is equalized. Its server
    /// ends its terminal unless `keepSession` or another pane shows it.
    mutating func removePane(_ pane: PaneId, keepSession: Bool) throws {
        guard let server = paneServer(pane) else { throw AppError.unknownPane(pane) }
        try perform(server, .removePane(pane, keepSession: keepSession))
    }

    /// Splits `pane` with a new terminal on its `edge` and focuses it.
    @discardableResult
    public mutating func splitPane(_ pane: PaneId, edge: Direction, launch: TerminalLaunch? = nil) throws -> PaneId {
        let new = Pane.terminal(launch: launch)
        try insertSplitPane(after: pane, new, edge: edge)
        try focusPane(new.id)
        return new.id
    }

    /// Every typed pane goes in through here: split beside `pane`, equalize
    /// the row it joins, and leave zoom.
    public mutating func insertSplitPane(after pane: PaneId, _ new: Pane, edge: Direction) throws {
        _ = try availablePaneTab(pane)
        guard let server = paneServer(pane) else { throw AppError.unknownPane(pane) }
        try perform(server, .insertPane(new, anchor: pane, edge: edge))
    }

    /// Puts a new terminal where `pane` is, with its title, and returns it.
    /// The server ends the old terminal.
    public mutating func restartTerminal(_ pane: PaneId, launch: TerminalLaunch? = nil) throws -> PaneId {
        let (p, t) = try availablePaneTab(pane)
        guard let old = projects[p].tabs[t].pane(pane) else { throw AppError.unknownPane(pane) }
        guard old.content.isTerminal else { throw AppError.notTerminal(pane) }
        let new = Pane.terminal(title: old.title, launch: launch)
        let saved = (window, paneTitles)
        paneTitles[new.id] = paneTitles[pane]
        window.focusHistory = window.focusHistory.map { $0 == pane ? new.id : $0 }
        if window.activePane == pane { window.activePane = new.id }
        if projects[p].tabs[t].zoomed == pane { window.zoomed[projects[p].tabs[t].id] = new.id }
        do {
            try perform(projects[p].serverId, .replacePane(pane, with: new))
        } catch {
            (window, paneTitles) = saved
            throw error
        }
        return new.id
    }

    /// Drops `pane` on `target`: on its `edge`, or swapping places.
    public mutating func movePane(_ pane: PaneId, onto target: PaneId, edge: Direction?) throws {
        if let edge { return try dockPane(pane, beside: target, edge: edge, level: 0) }
        let (p, t) = try availablePaneTab(pane)
        guard projects[p].tabs[t].layout.moved(pane, onto: target, edge: nil) != nil else {
            throw AppError.invalidState("invalid pane drop")
        }
        try perform(projects[p].serverId, .swapPanes(pane, target))
        try focusPane(pane)
    }

    /// Docks `pane` on `edge` of `anchor` or the enclosing row or column
    /// `level` picks.
    public mutating func dockPane(_ pane: PaneId, beside anchor: PaneId, edge: Direction, level: Int) throws {
        let (p, t) = try availablePaneTab(pane)
        guard projects[p].tabs[t].layout.docked(pane, beside: anchor, edge: edge, level: level) != nil else {
            throw AppError.invalidState("invalid pane dock")
        }
        try perform(projects[p].serverId, .dockPane(pane, anchor: anchor, edge: edge, level: level))
        try focusPane(pane)
    }

    /// Focuses `pane`, selecting its project and tab. A zoomed tab zooms it.
    public mutating func focusPane(_ pane: PaneId) throws {
        let (p, t) = try availablePaneTab(pane)
        if projects[p].tabs[t].zoomed != nil { setZoom(projects[p].tabs[t].id, pane) }
        window.currentProject = projects[p].id
        window.selectedTab[projects[p].id] = projects[p].tabs[t].id
        window.activate(pane)
    }

    /// Zooms `pane` alone in its tab, or shows the whole tab again. Only this
    /// app's view changes.
    public mutating func toggleZoom(_ pane: PaneId) throws {
        try focusPane(pane)
        let (p, t) = try availablePaneTab(pane)
        setZoom(projects[p].tabs[t].id, projects[p].tabs[t].zoomed == pane ? nil : pane)
    }

    mutating func setZoom(_ tab: TabId, _ pane: PaneId?) {
        window.zoomed[tab] = pane
        for p in projects.indices {
            guard let t = projects[p].tabs.firstIndex(where: { $0.id == tab }) else { continue }
            projects[p].tabs[t].zoomed = pane
        }
    }

    /// Applies an edge preset atomically and reveals the resulting layout.
    public mutating func positionPane(_ pane: PaneId, edge: Direction, share: Double) throws {
        let (p, t) = try availablePaneTab(pane)
        let tab = projects[p].tabs[t]
        guard tab.layout.positioned(pane, edge: edge, share: share) != nil else {
            throw AppError.invalidState("pane positioning requires another pane and a valid share")
        }
        try perform(projects[p].serverId, .positionPane(pane, edge: edge, share: share))
        setZoom(tab.id, nil)
        try focusPane(pane)
    }

    public mutating func setRatio(_ tab: TabId, path: [Branch], ratio: Double) throws {
        let (p, t) = try availableTab(tab)
        guard ratio.isFinite, let split = projects[p].tabs[t].layout.anchor(at: path) else {
            throw AppError.invalidState("unknown split path")
        }
        try perform(projects[p].serverId, .setRatio(tab, split: split, ratio: ratio))
    }

    /// Gives every row and column of `pane`'s layout equal shares.
    public mutating func equalizeSplits(_ pane: PaneId) throws {
        let (p, t) = try availablePaneTab(pane)
        try perform(projects[p].serverId, .equalize(projects[p].tabs[t].id))
    }

    /// Records the title a pane shows here.
    public mutating func setPaneTitle(_ pane: PaneId, _ title: String) throws {
        guard let found = self.pane(pane) else { throw AppError.unknownPane(pane) }
        let title = found.content.isTerminal ? TerminalTitle.sanitizeOrDefault(title) : title
        paneTitles[pane] = title == found.content.defaultTitle ? nil : title
        try updatePane(pane) { $0.title = title }
    }

    public mutating func setWindowBounds(_ bounds: WindowBounds?) throws {
        try bounds?.validate()
        window.bounds = bounds
    }

    /// Opens `path` in an editor pane beside the focused pane, or focuses the
    /// project's existing editor for it.
    @discardableResult
    public mutating func openEditorPane(_ project: ProjectId, path: String) throws -> PaneId {
        try openNativePane(project, .editor(path: PaneContent.relativePath(path)))
    }

    /// Opens `path`'s diff beside the focused pane, or focuses the project's
    /// existing diff of the same path and side.
    @discardableResult
    public mutating func openDiffPane(_ project: ProjectId, path: String, staged: Bool) throws -> PaneId {
        try openNativePane(project, .diff(path: PaneContent.relativePath(path), staged: staged))
    }

    private mutating func openNativePane(_ project: ProjectId, _ content: PaneContent) throws -> PaneId {
        guard let target = self.project(project) else { throw AppError.unknownProject(project) }
        if let existing = target.tabs.flatMap(\.panes).first(where: { $0.content == content }) {
            try selectProject(project)
            try focusPane(existing.id)
            return existing.id
        }
        let pane = Pane(content: content)
        if isSingleTab(project) {
            let (tab, id) = try openPaneInContainer(project, pane: pane, focusLeaf: window.activePane)
            try selectProject(project)
            try selectTab(project, tab)
            try focusPane(id)
            return id
        }
        let tab = try addTab(project, Tab(pane: pane))
        try selectProject(project)
        try selectTab(project, tab)
        return pane.id
    }

    // MARK: Focus

    /// Focuses the selected tab's own pane: the active one when it is there,
    /// else the zoomed one, else the last focused, else the first.
    mutating func focusSelectedTab() {
        let selected = window.selectedTab[window.currentProject]
        let tab = currentProject.tabs.first { $0.id == selected }
        let pane = tab.flatMap { tab in
            window.activePane.flatMap { tab.layout.contains($0) ? $0 : nil }
                ?? tab.zoomed
                ?? window.focusHistory.reversed().first { tab.layout.contains($0) }
                ?? tab.layout.leaves.first
        }
        window.activate(pane)
    }

    // MARK: Lookup

    func projectIndex(_ id: ProjectId) throws -> Int {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw AppError.unknownProject(id) }
        return index
    }

    /// The project and tab whose layout holds `pane`.
    func paneTab(_ pane: PaneId) -> (Int, Int)? {
        for (p, project) in projects.enumerated() {
            if let t = project.tabs.firstIndex(where: { $0.layout.contains(pane) }) { return (p, t) }
        }
        return nil
    }

    /// `paneTab` in a project whose folder is there.
    func availablePaneTab(_ pane: PaneId) throws -> (Int, Int) {
        guard let (p, t) = paneTab(pane) else { throw AppError.unknownPane(pane) }
        try projects[p].requireAvailable()
        return (p, t)
    }

    func availableTab(_ tab: TabId) throws -> (Int, Int) {
        for (p, project) in projects.enumerated() {
            guard let t = project.tabs.firstIndex(where: { $0.id == tab }) else { continue }
            try project.requireAvailable()
            return (p, t)
        }
        throw AppError.invalidState("unknown tab")
    }

    mutating func updatePane(_ pane: PaneId, _ change: (inout Pane) -> Void) throws {
        for p in projects.indices {
            for t in projects[p].tabs.indices {
                if let i = projects[p].tabs[t].panes.firstIndex(where: { $0.id == pane }) {
                    change(&projects[p].tabs[t].panes[i])
                    return
                }
            }
        }
        throw AppError.unknownPane(pane)
    }

    // MARK: Validation

    func validate() throws {
        guard let first = projects.first, first.home, first.serverId.isLocal else {
            throw AppError.invalidState("exactly one Home project must be first")
        }
        var projectIds = Set<ProjectId>()
        var serversSeen = Set<ServerId>()
        for project in projects {
            guard projectIds.insert(project.id).inserted else {
                throw AppError.invalidState("duplicate project ID \(project.id)")
            }
            if serversSeen.insert(project.serverId).inserted != project.home {
                throw AppError.invalidState("exactly one Home project must be first")
            }
            try project.descriptor.check()
            if let parentId = project.parentId {
                guard let parent = self.project(parentId), !parent.home, parent.kind == nil, parent.parentId == nil else {
                    throw AppError.invalidState("invalid project parent")
                }
            }
        }
        var tabs = Set<TabId>()
        var panes = Set<PaneId>()
        for tab in projects.flatMap(\.tabs) {
            guard tabs.insert(tab.id).inserted else { throw AppError.invalidState("duplicate tab ID \(tab.id)") }
            try tab.validate()
            for pane in tab.panes where !panes.insert(pane.id).inserted {
                throw AppError.invalidState("duplicate pane ID \(pane.id)")
            }
        }
        if let active = window.activePane {
            let selected = window.selectedTab[window.currentProject]
            guard currentProject.tabs.contains(where: { $0.id == selected && $0.layout.contains(active) }) else {
                throw AppError.invalidState("window active pane must belong to the selected tab")
            }
        }
        try window.bounds?.validate()
    }

    // MARK: Home

    /// The local Home goes first, in the home folder; each remote server's
    /// Home goes first among its projects.
    mutating func ensureHome() throws {
        let directory = try Self.homeDirectory()
        if let index = projects.firstIndex(where: { $0.home && $0.serverId.isLocal }) {
            var home = projects.remove(at: index)
            home.home = true
            home.directory = ServerPath(directory)
            projects.insert(home, at: 0)
        } else {
            projects.insert(Self.newHome(directory: directory), at: 0)
        }
        for id in projects.filter({ $0.home && !$0.serverId.isLocal }).map(\.id) {
            if let index = projects.firstIndex(where: { $0.id == id }) { placeHome(index) }
        }
        refreshProjectStatuses()
        if project(window.currentProject) == nil { window.currentProject = home.id }
    }

    /// Moves the Home at `index` in front of its server's other projects, and
    /// the local Home in front of all.
    mutating func placeHome(_ index: Int) {
        let server = projects[index].serverId
        let first = server.isLocal ? 0 : projects.firstIndex { $0.serverId == server } ?? index
        guard first < index else { return }
        let home = projects.remove(at: index)
        projects.insert(home, at: first)
    }

    static func homeDirectory() throws -> String {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        guard !home.isEmpty else { throw AppError.homeDirectoryUnavailable }
        return home
    }

    static func newHome(directory: String) -> Project {
        Project(server: .local, descriptor: .home(directory: ServerPath(directory)))
    }
}
