import AppKit
import Combine
import TabClient
import TabCore
import TabProtocol

/// What changed in the model, so views redraw only what depends on it.
public enum ModelChange: Hashable, Sendable {
    /// Projects, tabs, panes, focus or workspaces.
    case state
    /// Connections, activity, Git metadata: what cards and banners show.
    case activity
    /// Settings, keymap or appearance.
    case settings
    /// The right panel opened, closed or changed width.
    case panel
}

/// The window's UI, as the model needs it: dialogs, the palette, toasts.
@MainActor
public protocol AppPresenter: AnyObject {
    var window: NSWindow? { get }
    /// Asks a question as a sheet; the answer is whether the user confirmed.
    func confirm(title: String, message: String, confirm: String, destructive: Bool) async -> Bool
    func showToast(_ message: String, error: Bool)
    /// Add Project on another computer: its folder browser.
    func showRemoteFolderBrowser(_ server: ServerId)
    func bringToFront()
}

/// Git facts the sidebar cards show.
public struct GitInfo: Equatable, Sendable {
    public var summary: GitSummary?
    public var pullRequest: UInt64?
    public var isRepository: Bool { summary != nil }
}

/// The app's state and its connections to servers. Views observe
/// `changes`; every mutation goes through the model, which saves
/// `state.json` shortly after and keeps the servers in step.
@MainActor
public final class AppModel {
    public let dirs: TabDirs
    public let theme: AppTheme
    public let panes = PaneRegistry()

    public internal(set) var settings: Settings
    public private(set) var terminalSettings: TerminalSettings
    public internal(set) var state: AppState
    /// Problems found while loading, shown once the window is up.
    public private(set) var loadProblems: [String] = []

    /// Coalesced change notifications, at most one per run loop turn.
    public let changes = PassthroughSubject<Set<ModelChange>, Never>()

    public weak var presenter: AppPresenter?
    /// Browser profiles, their data stores and the live browser panes.
    public let browserProfiles: BrowserProfiles
    /// Runs `tab browser` commands.
    public private(set) lazy var browserAutomation = BrowserAutomation(host: self)
    /// The Agents panel, wherever it is placed.
    public private(set) lazy var agentsPanel = AgentsPanelController(host: self)
    /// The Agent Sessions panel.
    public private(set) lazy var agentSessions = AgentSessionsController(host: self)
    /// Opens Settings, on a page when given; set by the window.
    public var showSettingsAction: ((SettingsCategory?) -> Void)?
    var projectHosts: [ProjectId: ProjectHost] = [:]
    /// Makes the right panel's content; set by the panels module.
    public var rightPanelFactory: RightPanelFactory?

    /// The sidebar's name filter. Not saved.
    public var nameFilter = "" {
        didSet { if nameFilter != oldValue { notify(.state) } }
    }

    /// Git facts by project, filled by the side connections.
    public internal(set) var git: [ProjectId: GitInfo] = [:]
    var connections: [ServerId: ServerConnection] = [:]
    var navigation = NavigationHistory()
    var creating: Set<PaneId> = []
    var replaying: Set<ServerId> = []
    var shownPanes: Set<PaneId> = []
    var deliveredNotifications: [ServerId: Set<UInt64>] = [:]
    var gitRefreshing: Set<ProjectId> = []
    var rightPanels: [RightPanelKind: RightPanelContent] = [:]
    var editorLocations: [PaneId: (line: Int, column: Int)] = [:]
    var projectIcons: [ProjectId: NSImage?] = [:]
    var iconSearches: Set<ProjectId> = []
    /// The modifiers held long enough to show shortcut numbers in the
    /// sidebar, or `nil`.
    public var shortcutHints: ChordModifiers? {
        didSet { if shortcutHints != oldValue { notify(.state) } }
    }
    /// The Agents panel's popup is open: its left placement while the
    /// sidebar is collapsed. Not saved, as in Codesh.
    public var agentsPopupOpen = false {
        didSet { if agentsPopupOpen != oldValue { notify(.panel) } }
    }
    /// Worktree names being created, by parent project.
    public internal(set) var worktreeCreations: [ProjectId: [String]] = [:]
    /// Worktree projects being removed.
    public internal(set) var worktreeRemovals: Set<ProjectId> = []
    let connectorOverride: ((ServerId, ServerEntry?) -> ServerConnector?)?
    /// The app's proxy from `proxy.json`.
    public let proxy: ProxyModel
    let askpass: AskpassServer
    /// Remote Servers: entries, statuses, passwords, installs.
    public private(set) lazy var remoteServers = RemoteServersModel(entries: settings.servers, askpass: askpass, host: self)
    /// The host menu, the Remote Servers pane and its dialogs.
    public private(set) lazy var remoteController = RemoteServersController(model: remoteServers)
    public private(set) lazy var proxyController = ProxyController(model: proxy, host: self)
    /// AI commit and pull request actions.
    public private(set) lazy var ai = AIActionsController(host: self)
    /// Updates from GitHub Releases.
    public private(set) lazy var updater = UpdaterController(host: self, dirs: dirs, configuration: proxy.sessionConfiguration())
    /// Icons of this computer's project folders.
    public let iconCache = ProjectIconCache()
    /// Remote Homes asked for before their server's catalog arrived.
    var pendingRemoteHomes: Set<ServerId> = []
    /// Terminals on this computer's server, for the updater.
    var localSessionCount = 0
    let notifier: Notifier
    var windowActive = true

    private var pending: Set<ModelChange> = []
    private var flushScheduled = false
    private var saveWork: DispatchWorkItem?
    var referencesWork: DispatchWorkItem?
    private var savedAppearance: Appearance

    /// Loads the profile: a waiting backup first, then settings, terminal
    /// settings and `state.json`. A file that does not load keeps the
    /// defaults and is reported.
    public init(
        dirs: TabDirs,
        theme: AppTheme? = nil,
        notifier: Notifier? = nil,
        connectorFactory: ((ServerId, ServerEntry?) -> ServerConnector?)? = nil
    ) {
        self.dirs = dirs
        let theme = theme ?? .shared
        self.theme = theme
        browserProfiles = BrowserProfiles(dirs: dirs)
        var problems: [String] = []
        do {
            try BackupArchive.applyPending(in: dirs) { imported, current in
                try BackupStateMerge.merge(imported: imported, current: current)
            }
        } catch {
            problems.append("Could not restore the backup: \(error.localizedDescription)")
        }
        var settings: Settings
        do {
            settings = try Settings.load(dirs.settings)
        } catch {
            settings = Settings()
            problems.append("settings.json: \(error)")
        }
        do {
            terminalSettings = try TerminalSettings.load(dirs.terminalSettings)
        } catch {
            terminalSettings = TerminalSettings()
            problems.append("terminal.json: \(error)")
        }
        var state: AppState
        do {
            state = try AppStateStore.load(dirs.state)
        } catch {
            problems.append("\(error)")
            state = (try? AppState.bootstrap()) ?? Self.emergencyState()
        }
        for server in Set(state.projects.map(\.serverId)) where !server.isLocal {
            state.forgetRemoteStatuses(server)
        }
        self.settings = settings
        savedAppearance = settings.appearance
        self.state = state
        loadProblems = problems
        self.notifier = notifier ?? Notifier()
        connectorOverride = connectorFactory
        proxy = ProxyModel(file: dirs.proxy)
        askpass = AskpassServer(socket: dirs.root.appendingPathComponent("askpass.sock"))
        theme.setThemes(dark: settings.appearance.darkTheme, light: settings.appearance.lightTheme)
        self.notifier.model = self
        panes.register(.terminal) { TerminalPane(context: $0) }
        registerNativeContent()
        browserProfiles.defaultProfileId = settings.browser.defaultProfile
        browserProfiles.notify = { [weak self] message, isError in self?.presenter?.showToast(message, error: isError) }
        iconCache.onChange = { [weak self] _ in self?.notify(.activity) }
        recordNavigation()
    }

    private static func emergencyState() -> AppState {
        // `bootstrap` only fails without a home folder; decode a minimal one.
        let home = ProjectId()
        let json = """
        {"version":1,"projects":[{"id":"\(home)","home":true,"name":"Home","serverId":"\(ServerId.local)","directory":"/","tabs":[]}],"window":{"currentProject":"\(home)"}}
        """
        return (try? AppStateStore.decode(Data(json.utf8)))!
    }

    // MARK: Starting

    /// Connects this computer's server and starts following activity.
    public func start() {
        connection(.local)?.start()
        startIntegrations()
        notifier.start()
        syncVisible()
    }

    // MARK: Reading

    public var appearance: Appearance { settings.appearance }
    public var currentProject: Project { state.currentProject }
    public var activePane: PaneId? { state.window.activePane }

    /// The tab the window shows for the current project.
    public var activeTab: Tab? {
        let project = currentProject
        let selected = state.window.selectedTab[project.id]
        return project.tabs.first { $0.id == selected } ?? project.tabs.first
    }

    /// The panes on screen now.
    public var visiblePanes: [PaneId] { activeTab?.visiblePanes ?? [] }

    /// The main connection of `project`'s server.
    public func client(for project: ProjectId) -> ServerAPI? {
        guard let server = state.projectServer(project) else { return nil }
        return connections[server]?.main
    }

    /// The side connection of `project`'s server, for Git, files, search and
    /// uploads.
    public func sideClient(for project: ProjectId) -> ServerAPI? {
        guard let server = state.projectServer(project) else { return nil }
        return connections[server]?.side
    }

    public func connectionState(_ server: ServerId) -> ConnectionState {
        connections[server]?.state ?? .idle
    }

    /// The name a project goes by: another computer's Home by its server.
    public func title(of project: Project) -> String {
        listingBuilder().title(project)
    }

    /// The server entry's name, for remote projects.
    public func serverName(_ server: ServerId) -> String? {
        server.isLocal ? nil : settings.server(server)?.name
    }

    func listingBuilder() -> SidebarListingBuilder {
        SidebarListingBuilder(
            state: state, appearance: appearance, servers: settings.servers, query: nameFilter,
            repositories: Set(git.filter { $0.value.isRepository }.keys)
        )
    }

    /// What the sidebar lists now.
    public var sidebarListing: SidebarListing { listingBuilder().build() }

    // MARK: Changing

    /// Applies `change` to a copy of the state and keeps it when it
    /// succeeds; a refused change is reported and nothing changes.
    @discardableResult
    public func edit(_ change: (inout AppState) throws -> Void) -> Bool {
        var next = state
        do {
            try change(&next)
        } catch {
            report(error)
            return false
        }
        guard next != state else { return true }
        state = next
        stateDidChange()
        return true
    }

    func stateDidChange() {
        scheduleSave()
        scheduleReferenceSync()
        replayAllIntents()
        flushClosures()
        recordNavigation()
        syncVisible()
        notify(.state)
    }

    /// Queues a notification of `change` for the end of this run loop turn.
    public func notify(_ change: ModelChange) {
        pending.insert(change)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushChanges() }
        }
    }

    private func flushChanges() {
        flushScheduled = false
        let changed = pending
        pending = []
        if !changed.isEmpty { changes.send(changed) }
    }

    /// Shows a problem in the window.
    public func report(_ error: Error) {
        report((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    public func report(_ message: String) {
        Log.app.error("\(message, privacy: .public)")
        presenter?.showToast(message, error: true)
    }

    // MARK: Saving

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Writes `state.json` now, such as when quitting.
    public func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try AppStateStore.save(state, to: dirs.state)
        } catch {
            report(error)
        }
    }

    /// Saves what changed in Appearance, keeping edits made elsewhere.
    public func updateAppearance(_ change: (inout Appearance) -> Void) {
        var appearance = settings.appearance
        change(&appearance)
        guard appearance != settings.appearance else { return }
        settings.appearance = appearance
        do {
            let saved = try appearance.saveChanges(since: savedAppearance, to: dirs.settings)
            settings.appearance = saved
            savedAppearance = saved
        } catch {
            report(error)
        }
        theme.setThemes(dark: settings.appearance.darkTheme, light: settings.appearance.lightTheme)
        notify(.settings)
        notify(.state)
    }

    /// Settings changed elsewhere, such as in the Settings window.
    public func apply(settings: Settings) {
        let servers = self.settings.servers
        self.settings = settings
        savedAppearance = settings.appearance
        theme.setThemes(dark: settings.appearance.darkTheme, light: settings.appearance.lightTheme)
        if servers != settings.servers {
            serversDidChange(old: servers)
            remoteServers.sync(settings.servers)
        }
        notify(.settings)
        notify(.state)
    }

    /// Applies new terminal settings to every terminal.
    public func apply(terminalSettings: TerminalSettings, preview: Bool = false) {
        if !preview { self.terminalSettings = terminalSettings }
        for (_, controller) in panes.all {
            (controller as? TerminalPane)?.apply(settings: terminalSettings)
        }
    }

    // MARK: Visibility

    /// Shows and hides pane contents to match the window, attaching the
    /// terminals on screen and detaching the rest.
    func syncVisible() {
        let allPanes = Set(state.projects.flatMap(\.tabs).flatMap(\.panes).map(\.id))
        panes.retain(allPanes)
        let visible = Set(visiblePanes)
        for pane in shownPanes.subtracting(visible) {
            panes.controller(for: pane)?.didHide()
        }
        let appeared = visible.subtracting(shownPanes)
        shownPanes = visible
        for pane in appeared {
            controller(for: pane)?.didShow()
        }
        for pane in visible {
            (panes.controller(for: pane) as? TerminalPane)?.refresh()
        }
        createMissingSessions()
        acknowledgeFocusedActivity()
    }

    /// The controller for a pane in the current state, made if needed.
    public func controller(for pane: PaneId) -> PaneContentController? {
        guard let found = state.pane(pane), let projectId = state.paneProject(pane),
              let project = state.project(projectId) else { return nil }
        return panes.controller(for: PaneContext(pane: found, project: project, model: self))
    }

    // MARK: Navigation

    func recordNavigation() {
        let project = currentProject
        let tab = project.home ? state.window.selectedTab[project.id] : nil
        navigation.record(NavigationHistory.Location(project: project.id, tab: tab))
    }

    /// Goes back or forward to the last project or Home terminal shown.
    public func navigate(forward: Bool) {
        let live: (NavigationHistory.Location) -> Bool = { [state] location in
            guard let project = state.project(location.project), project.status == .available else { return false }
            guard let tab = location.tab else { return true }
            return project.tabs.contains { $0.id == tab }
        }
        guard let (index, location) = navigation.target(forward: forward, live: live) else { return }
        navigation.commit(index)
        edit { state in
            if let tab = location.tab {
                try state.selectTab(location.project, tab)
            } else {
                try state.selectProject(location.project)
            }
        }
    }

    // MARK: Window

    public func saveWindowFrame(_ frame: NSRect) {
        let bounds = WindowBounds(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        guard state.window.bounds != bounds else { return }
        edit { try $0.setWindowBounds(bounds) }
    }

    public func windowDidChangeActive(_ active: Bool) {
        windowActive = active
        if active { acknowledgeFocusedActivity() }
    }
}
