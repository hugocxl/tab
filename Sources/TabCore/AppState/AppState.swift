import Foundation

/// The app's projects, their layouts and panes, workspaces and window state,
/// saved as `state.json`. Every change keeps it valid: Home first, layouts
/// matching their panes, focus inside the selected tab.
///
/// Every non-Home project has zero or one tab holding its split layout;
/// Home keeps standalone terminal tabs, each with its own splits.
public struct AppState: Codable, Equatable, Sendable {
    /// The state format this build writes.
    public static let currentVersion = 1

    var servers: [ServerId: ServerState]
    /// Where each pane's terminal starts, kept until its server creates it.
    var startingDirectories: [PaneId: ServerPath]
    /// Commands to type into each pane's new terminal once it starts.
    var startupCommands: [PaneId: String]
    public private(set) var version: Int
    public internal(set) var projects: [Project]
    public internal(set) var workspaces: [Workspace]
    public internal(set) var window: WindowState

    enum CodingKeys: String, CodingKey {
        case servers, startingDirectories, startupCommands, version, projects, workspaces, window
    }

    /// A fresh state: just this computer's Home.
    public static func bootstrap() throws -> AppState {
        let home = try newHome(directory: homeDirectory())
        return AppState(
            servers: [:],
            startingDirectories: [:],
            startupCommands: [:],
            version: currentVersion,
            projects: [home],
            workspaces: [],
            window: WindowState(currentProject: home.id)
        )
    }

    private init(
        servers: [ServerId: ServerState],
        startingDirectories: [PaneId: ServerPath],
        startupCommands: [PaneId: String],
        version: Int,
        projects: [Project],
        workspaces: [Workspace],
        window: WindowState
    ) {
        self.servers = servers
        self.startingDirectories = startingDirectories
        self.startupCommands = startupCommands
        self.version = version
        self.projects = projects
        self.workspaces = workspaces
        self.window = window
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
            startingDirectories: try container.value(.startingDirectories, [:]),
            startupCommands: try container.value(.startupCommands, [:]),
            version: version,
            projects: try container.decode([Project].self, forKey: .projects),
            workspaces: try container.value(.workspaces, []),
            window: try container.decode(WindowState.self, forKey: .window)
        )
        do {
            try repairLoaded()
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(servers, forKey: .servers)
        try container.encode(startingDirectories, forKey: .startingDirectories)
        if !startupCommands.isEmpty { try container.encode(startupCommands, forKey: .startupCommands) }
        try container.encode(version, forKey: .version)
        try container.encode(projects, forKey: .projects)
        if !workspaces.isEmpty { try container.encode(workspaces, forKey: .workspaces) }
        try container.encode(window, forKey: .window)
    }

    private mutating func repairLoaded() throws {
        let previousProject = window.currentProject
        let previousTab = window.selectedTab[previousProject]
        try ensureHome()
        retainWorkspaceMembers()
        if window.currentProject != previousProject || window.selectedTab[window.currentProject] != previousTab {
            window.activePane = nil
        }
        let selected = window.selectedTab[window.currentProject]
        if window.activePane == nil,
           let tab = projects.lazy.flatMap(\.tabs).first(where: { $0.id == selected })
        {
            window.activePane = tab.layout.leaves.first
        }
        let panes = Set(projects.flatMap(\.tabs).flatMap(\.panes).map(\.id))
        window.focusHistory.removeAll { !panes.contains($0) }
        try validate()
        normalizeProjects()
        try validate()
    }

    // MARK: Reading

    public func project(_ id: ProjectId) -> Project? { projects.first { $0.id == id } }

    /// This computer's Home, always first.
    public var home: Project { projects[0] }

    public var currentProject: Project { project(window.currentProject) ?? home }

    public func startupCommand(_ pane: PaneId) -> String? { startupCommands[pane] }

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
            startupCommands[pane.id] = nil
            if let session = pane.content.session, !sessions.contains(session) { sessions.append(session) }
        }
        return sessions
    }

    // MARK: Tabs

    /// Opens a terminal: in a project, a new pane in its layout; in Home, a
    /// new standalone tab. Returns the tab that holds it.
    @discardableResult
    public mutating func openTerminalTab(_ project: ProjectId) throws -> TabId {
        try openTerminalTab(project, near: window.selectedTab[project])
    }

    private mutating func openTerminalTab(_ project: ProjectId, near: TabId?) throws -> TabId {
        try projects[projectIndex(project)].requireAvailable()
        if isSingleTab(project) {
            let (tab, pane) = try openPaneInContainer(project, pane: .terminal(), focusLeaf: window.activePane)
            window.selectedTab[project] = tab
            window.currentProject = project
            window.activate(pane)
            return tab
        }
        let tab = Tab(pane: .terminal())
        window.activate(tab.layout.leaves.first)
        try addTab(project, tab)
        window.selectedTab[project] = tab.id
        window.currentProject = project
        return tab.id
    }

    /// Opens a terminal tab right after `anchor`, after any pinned tabs.
    @discardableResult
    public mutating func openTerminalTab(_ project: ProjectId, adjacentTo anchor: TabId) throws -> TabId {
        let projectIndex = try projectIndex(project)
        try projects[projectIndex].requireAvailable()
        guard let index = projects[projectIndex].tabs.firstIndex(where: { $0.id == anchor }) else {
            throw AppError.unknownTab(project: project, tab: anchor)
        }
        if isSingleTab(project) { return try openTerminalTab(project, near: anchor) }
        let boundary = projects[projectIndex].tabs.prefix { $0.pinned }.count
        let destination = max(index + 1, boundary)
        let id = try openTerminalTab(project, near: anchor)
        let tab = projects[projectIndex].tabs.removeLast()
        projects[projectIndex].tabs.insert(tab, at: destination)
        return id
    }

    public mutating func setTabTitle(_ tab: TabId, _ title: String?) throws {
        let (p, t) = try availableTab(tab)
        projects[p].tabs[t].customTitle = title
        projects[p].tabs[t].sanitizeTitles()
    }

    public mutating func setTabColor(_ tab: TabId, _ color: TabColor?) throws {
        let (p, t) = try availableTab(tab)
        projects[p].tabs[t].color = color
    }

    /// Pins or unpins a tab; pinned tabs come first.
    public mutating func toggleTabPin(_ tab: TabId) throws {
        let (p, t) = try availableTab(tab)
        var moved = projects[p].tabs.remove(at: t)
        moved.pinned.toggle()
        let boundary = projects[p].tabs.prefix { $0.pinned }.count
        projects[p].tabs.insert(moved, at: boundary)
    }

    /// Closes a tab with its panes. Focus moves to a neighboring tab, or for
    /// a Home terminal to the most recently focused surviving pane.
    public mutating func closeTab(_ project: ProjectId, _ tab: TabId) throws {
        let p = try projectIndex(project)
        guard let t = projects[p].tabs.firstIndex(where: { $0.id == tab }) else {
            throw AppError.unknownTab(project: project, tab: tab)
        }
        for pane in projects[p].tabs[t].panes { cancelPendingCreation(pane.id) }
        let removedActive = window.activePane.map { projects[p].tabs[t].layout.contains($0) } ?? false
        let next = projects[p].tabAfterClose(tab)
        let removed = projects[p].tabs.remove(at: t)
        var nextPane: PaneId?
        if let next, let index = projects[p].tabs.firstIndex(where: { $0.id == next }) {
            nextPane = projects[p].tabs[index].layout.leaves.first
            if removedActive { projects[p].tabs[index].zoomed = nil }
        }
        window.focusHistory.removeAll { removed.layout.contains($0) }
        if window.selectedTab[project] == tab { window.selectedTab[project] = next }
        guard removedActive else { return }
        if projects[p].home {
            let recent = window.focusHistory.reversed().first { pane in
                projects.contains { $0.status == .available && $0.tabs.contains { $0.layout.contains(pane) } }
            }
            if let recent {
                try focusPane(recent)
                return
            }
        }
        window.activate(nextPane)
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

    /// Moves a tab within its project; pinned and unpinned tabs stay apart.
    public mutating func moveTab(_ project: ProjectId, from: Int, to: Int) throws {
        let p = try projectIndex(project)
        try projects[p].requireAvailable()
        let count = projects[p].tabs.count
        for index in [from, to] where !(0..<count).contains(index) {
            throw AppError.invalidTabIndex(index: index, count: count)
        }
        let boundary = projects[p].tabs.prefix { $0.pinned }.count
        let destination = projects[p].tabs[from].pinned ? min(to, max(boundary - 1, 0)) : max(to, boundary)
        let tab = projects[p].tabs.remove(at: from)
        projects[p].tabs.insert(tab, at: destination)
    }

    /// Moves `from` to where `to` is among the tabs listed in `visible`,
    /// leaving hidden tabs where they are.
    public mutating func moveVisibleTab(_ project: ProjectId, from: TabId, to: TabId, visible: [TabId]) throws {
        let p = try projectIndex(project)
        try projects[p].requireAvailable()
        guard let pinned = projects[p].tabs.first(where: { $0.id == from })?.pinned else { return }
        let indices = projects[p].tabs.indices.filter {
            projects[p].tabs[$0].pinned == pinned && visible.contains(projects[p].tabs[$0].id)
        }
        guard let start = indices.firstIndex(where: { projects[p].tabs[$0].id == from }),
              let end = indices.firstIndex(where: { projects[p].tabs[$0].id == to })
        else { return }
        if start < end {
            for position in start..<end { projects[p].tabs.swapAt(indices[position], indices[position + 1]) }
        } else if start > end {
            for position in stride(from: start, to: end, by: -1) {
                projects[p].tabs.swapAt(indices[position - 1], indices[position])
            }
        }
    }

    /// Opens a pane in the project's layout, right of `focusLeaf` or its
    /// last pane, creating the layout when the project has none. Does not
    /// change focus.
    @discardableResult
    public mutating func openPaneInContainer(_ project: ProjectId, pane: Pane, focusLeaf: PaneId?) throws -> (TabId, PaneId) {
        let p = try projectIndex(project)
        try projects[p].requireAvailable()
        guard let tab = projects[p].tabs.first else {
            let tab = Tab(pane: pane)
            try addTab(project, tab)
            return (tab.id, pane.id)
        }
        guard let leaf = focusLeaf.flatMap({ tab.layout.contains($0) ? $0 : nil }) ?? tab.layout.leaves.last else {
            throw AppError.invalidState("container has no panes")
        }
        try insertSplitPane(after: leaf, pane, edge: .right)
        return (tab.id, pane.id)
    }

    func isSingleTab(_ project: ProjectId) -> Bool {
        self.project(project).map { !$0.home } ?? false
    }

    mutating func addTab(_ project: ProjectId, _ tab: Tab) throws {
        let p = try projectIndex(project)
        projects[p].tabs.append(tab)
        if !projects[p].home { Self.normalize(&projects[p]) }
    }

    /// Merges a project's tabs into one in order: the first tab survives and
    /// each later layout is appended on the right intact, keeping every pane
    /// and session. Home keeps its tabs; an empty project stays empty.
    public static func normalize(_ project: inout Project) {
        guard !project.home, var survivor = project.tabs.first else { return }
        if project.tabs.count > 1 { survivor.zoomed = nil }
        for tab in project.tabs.dropFirst() {
            survivor.layout = .split(axis: .horizontal, ratio: 0.5, first: survivor.layout, second: tab.layout)
            survivor.panes += tab.panes
        }
        project.tabs = [survivor]
    }

    /// Normalizes every project and repairs selection and focus.
    mutating func normalizeProjects() {
        for index in projects.indices where !projects[index].home {
            Self.normalize(&projects[index])
            window.selectedTab[projects[index].id] = projects[index].tabs.first?.id
        }
        focusSelectedTab()
    }

    // MARK: Panes

    public mutating func closePane(_ pane: PaneId) throws {
        _ = try availablePaneTab(pane)
        try removePane(pane)
    }

    /// Closes the pane but leaves its terminal running.
    public mutating func detachPane(_ pane: PaneId) throws {
        _ = try availablePaneTab(pane)
        startingDirectories[pane] = nil
        try removePane(pane)
    }

    /// Closes every pane of `server` that shows `session`.
    public mutating func closeSessionPanes(server: ServerId, session: SessionId) throws {
        let panes = projects.filter { $0.serverId == server }.flatMap(\.tabs).flatMap(\.panes)
            .filter { $0.content.session == session }.map(\.id)
        for pane in panes { try removePane(pane) }
        discardUnreferenced(server: server, session: session)
    }

    /// Closes a terminal pane, queuing its session's end when no other pane
    /// shows it.
    public mutating func closeSessionPane(_ pane: PaneId) throws {
        guard let server = paneServer(pane), let content = self.pane(pane)?.content else {
            throw AppError.unknownPane(pane)
        }
        try removePane(pane)
        if let session = content.session { discardUnreferenced(server: server, session: session) }
    }

    /// Closes `server`'s terminal panes.
    public mutating func clearTerminalPanes(server: ServerId) throws {
        let panes = projects.filter { $0.serverId == server }.flatMap(\.tabs).flatMap(\.panes)
            .filter(\.content.isTerminal).map(\.id)
        for pane in panes { try removePane(pane) }
    }

    /// Removes a pane, even in a project whose folder is missing. Its
    /// neighbor takes focus, and the row it leaves is equalized.
    mutating func removePane(_ pane: PaneId) throws {
        guard let (p, t) = paneTab(pane) else { throw AppError.unknownPane(pane) }
        cancelPendingCreation(pane)
        if projects[p].tabs[t].panes.count == 1 {
            try closeTab(projects[p].id, projects[p].tabs[t].id)
            return
        }
        let layout = projects[p].tabs[t].layout
        let neighbor = [Direction.right, .left, .down, .up].lazy.compactMap { layout.neighbor(of: pane, $0) }.first
        projects[p].tabs[t].layout.removeEqualized(pane)
        projects[p].tabs[t].panes.removeAll { $0.id == pane }
        if projects[p].tabs[t].zoomed == pane { projects[p].tabs[t].zoomed = nil }
        let fallback = neighbor ?? projects[p].tabs[t].layout.leaves.first
        window.focusHistory.removeAll { $0 == pane }
        if window.activePane == pane { window.activate(fallback) }
    }

    /// Splits `pane` with a new terminal on its `edge` and focuses it.
    @discardableResult
    public mutating func splitPane(_ pane: PaneId, edge: Direction) throws -> PaneId {
        let new = Pane.terminal()
        try insertSplitPane(after: pane, new, edge: edge)
        try focusPane(new.id)
        return new.id
    }

    /// Every typed pane goes in through here: split beside `pane`, equalize
    /// the row it joins, and leave zoom.
    public mutating func insertSplitPane(after pane: PaneId, _ new: Pane, edge: Direction) throws {
        let (p, t) = try availablePaneTab(pane)
        projects[p].tabs[t].layout.split(pane, new: new.id, edge: edge)
        projects[p].tabs[t].layout.equalizeParent(of: new.id)
        projects[p].tabs[t].zoomed = nil
        projects[p].tabs[t].panes.append(new)
    }

    /// Puts a new terminal where `pane` is, with its title, and returns it.
    /// The old terminal's session is the caller's to end.
    public mutating func restartTerminal(_ pane: PaneId) throws -> PaneId {
        cancelPendingCreation(pane)
        let (p, t) = try availablePaneTab(pane)
        guard let index = projects[p].tabs[t].panes.firstIndex(where: { $0.id == pane }) else {
            throw AppError.unknownPane(pane)
        }
        guard projects[p].tabs[t].panes[index].content.isTerminal else { throw AppError.notTerminal(pane) }
        let new = Pane.terminal(title: projects[p].tabs[t].panes[index].title)
        projects[p].tabs[t].layout.replace(pane, with: new.id)
        projects[p].tabs[t].panes[index] = new
        if projects[p].tabs[t].zoomed == pane { projects[p].tabs[t].zoomed = new.id }
        window.focusHistory = window.focusHistory.map { $0 == pane ? new.id : $0 }
        if window.activePane == pane { window.activePane = new.id }
        return new.id
    }

    public mutating func setPaneProxy(_ pane: PaneId, _ proxy: Bool) throws {
        try updatePane(pane) { $0.proxy = proxy }
    }

    /// Drops `pane` on `target`: on its `edge`, or swapping places.
    public mutating func movePane(_ pane: PaneId, onto target: PaneId, edge: Direction?) throws {
        let (p, t) = try availablePaneTab(pane)
        guard let layout = projects[p].tabs[t].layout.moved(pane, onto: target, edge: edge) else {
            throw AppError.invalidState("invalid pane drop")
        }
        projects[p].tabs[t].layout = layout
        projects[p].tabs[t].zoomed = nil
        try focusPane(pane)
    }

    /// Docks `pane` on `edge` of `anchor` or the enclosing row or column
    /// `level` picks.
    public mutating func dockPane(_ pane: PaneId, beside anchor: PaneId, edge: Direction, level: Int) throws {
        let (p, t) = try availablePaneTab(pane)
        guard let layout = projects[p].tabs[t].layout.docked(pane, beside: anchor, edge: edge, level: level) else {
            throw AppError.invalidState("invalid pane dock")
        }
        projects[p].tabs[t].layout = layout
        projects[p].tabs[t].zoomed = nil
        try focusPane(pane)
    }

    /// Focuses `pane`, selecting its project and tab. A zoomed tab zooms it.
    public mutating func focusPane(_ pane: PaneId) throws {
        let (p, t) = try availablePaneTab(pane)
        if projects[p].tabs[t].zoomed != nil { projects[p].tabs[t].zoomed = pane }
        window.currentProject = projects[p].id
        window.selectedTab[projects[p].id] = projects[p].tabs[t].id
        window.activate(pane)
    }

    public mutating func toggleZoom(_ pane: PaneId) throws {
        try focusPane(pane)
        let (p, t) = try availablePaneTab(pane)
        projects[p].tabs[t].zoomed = projects[p].tabs[t].zoomed == pane ? nil : pane
    }

    public mutating func setRatio(_ tab: TabId, path: [Branch], ratio: Double) throws {
        let (p, t) = try availableTab(tab)
        do {
            try projects[p].tabs[t].layout.setRatio(at: path, to: ratio)
        } catch {
            throw AppError.invalidState("\(error)")
        }
    }

    /// Gives every row and column of `pane`'s layout equal shares.
    public mutating func equalizeSplits(_ pane: PaneId) throws {
        let (p, t) = try availablePaneTab(pane)
        guard let layout = projects[p].tabs[t].layout.equalized() else {
            throw AppError.invalidState("layout has an empty split")
        }
        projects[p].tabs[t].layout = layout
    }

    public mutating func setPaneSession(_ pane: PaneId, _ session: SessionId?) throws {
        guard self.pane(pane)?.content.isTerminal ?? false else {
            throw self.pane(pane) == nil ? AppError.unknownPane(pane) : AppError.notTerminal(pane)
        }
        try updatePane(pane) { $0.content = .terminal(session: session) }
    }

    public mutating func setPaneTitle(_ pane: PaneId, _ title: String) throws {
        try updatePane(pane) { pane in
            pane.title = pane.content.isTerminal ? TerminalTitle.sanitizeOrDefault(title) : title
        }
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
        let pane = Pane(title: content.nativeTitle ?? "", content: content)
        if isSingleTab(project) {
            let (tab, id) = try openPaneInContainer(project, pane: pane, focusLeaf: window.activePane)
            try selectProject(project)
            try selectTab(project, tab)
            try focusPane(id)
            return id
        }
        let tab = Tab(pane: pane)
        try addTab(project, tab)
        try selectProject(project)
        try selectTab(project, tab.id)
        return pane.id
    }

    // MARK: Startup commands

    /// Types `command` into the pane's new terminal once it starts.
    public mutating func setStartupCommand(_ pane: PaneId, _ command: String) throws {
        guard let found = self.pane(pane) else { throw AppError.unknownPane(pane) }
        guard found.content.isTerminal else { throw AppError.notTerminal(pane) }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { startupCommands[pane] = command }
    }

    public mutating func takeStartupCommand(_ pane: PaneId) -> String? {
        startupCommands.removeValue(forKey: pane)
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
        window.selectedTab = window.selectedTab.filter { projectId, tab in
            project(projectId)?.tabs.contains { $0.id == tab } ?? false
        }
        for project in projects {
            if let tab = project.tabs.first, window.selectedTab[project.id] == nil {
                window.selectedTab[project.id] = tab.id
            }
        }
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
