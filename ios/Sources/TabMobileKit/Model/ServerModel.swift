import Foundation
import Observation
import TabProtocol
import TabShared

/// One paired Mac as this app sees it: the connection, its projects, its tabs
/// with this app's unconfirmed changes on top, and what its agents and
/// terminals are doing.
///
/// Tabs follow the desktop app's rules: every change goes through the same
/// `TabReducer` the server runs, shows at once, and is sent as a `TabIntent`
/// the server applies exactly once, even when a reconnect sends it again.
@MainActor
@Observable
public final class ServerModel: Identifiable {
    public enum Status: Equatable {
        case connecting
        case connected
        /// Lost or unreachable; retrying on its own after the backoff.
        case offline(String)
        /// The server refused this device; only pairing again helps.
        case needsPairing(String)
    }

    public nonisolated let id: ServerId
    public private(set) var server: PairedServer
    public private(set) var status: Status = .connecting
    public private(set) var home: ProjectId?
    /// Projects in catalog order.
    public private(set) var projects: [ProjectDescriptor] = []
    /// The server's tabs with this app's pending changes applied.
    public private(set) var board: TabBoard?
    public private(set) var activity = ActivitySnapshot(revision: 0)
    public private(set) var metadata: [SessionId: SessionMetadata] = [:]
    public private(set) var progress: [SessionId: SessionProgress] = [:]
    /// Branch and base of projects with open tabs; nil for a folder that isn't a repository.
    public private(set) var gitSummaries: [ProjectId: GitSummary?] = [:]
    /// Project icon file bytes, once found.
    public private(set) var projectIcons: [ProjectId: Data] = [:]

    /// The colors this app draws terminals in, so programs that ask for them
    /// get the same answer. The server keeps them per connection.
    @ObservationIgnored public var terminalColors: TerminalColors? {
        didSet {
            guard terminalColors != oldValue, let terminalColors, let client else { return }
            Task { try? await client.setTerminalColors(terminalColors) }
        }
    }

    /// The live connection; nil while connecting or offline.
    @ObservationIgnored public private(set) var client: ServerClient?
    @ObservationIgnored private let store: PairedServerStore
    @ObservationIgnored private let clientId: ClientId
    @ObservationIgnored private var snapshot: TabsSnapshot?
    @ObservationIgnored private var pending: [TabIntent] = []
    @ObservationIgnored private var acknowledged: [OperationId: UInt64] = [:]
    @ObservationIgnored private var sending = false
    /// Terminal panes this app added, whose sessions it starts once the server keeps the pane.
    @ObservationIgnored private var panesToStart: [PaneId: TerminalStart] = [:]
    @ObservationIgnored private var starting: Set<PaneId> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshingTabs = false
    @ObservationIgnored private var tabsDirty = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var terminals: [SessionId: TerminalController] = [:]
    @ObservationIgnored private var simulators: [PaneId: SimulatorController] = [:]
    @ObservationIgnored private var listingSimulators = false
    @ObservationIgnored private var simulatorsDirty = false
    // Observed, so cards that read a pane's chosen agent follow it from the moment the pane opens.
    private var agents: [SessionId: AgentChatController] = [:]
    @ObservationIgnored private var gitRead: [ProjectId: Date] = [:]
    @ObservationIgnored private var watchedProject: ProjectId?
    @ObservationIgnored private var iconSearches: Set<ProjectId> = []
    /// Decides whether found icon bytes decode; set by the app.
    @ObservationIgnored public var isImage: (Data) -> Bool = { _ in true }

    struct TerminalStart {
        var project: ProjectId
        var size: Size
    }

    public init(server: PairedServer, store: PairedServerStore, clientId: ClientId) {
        id = server.id
        self.server = server
        self.store = store
        self.clientId = clientId
    }

    // MARK: Connecting

    /// Connects, and keeps reconnecting until `suspend`.
    public func start() {
        guard !active else { return }
        active = true
        connect()
    }

    /// Drops the connection, as iOS does to a suspended app anyway.
    public func suspend() {
        active = false
        retryTask?.cancel()
        generation += 1
        client?.close()
        client = nil
        for terminal in terminals.values { terminal.connectionLost() }
        for simulator in simulators.values { simulator.connectionLost() }
    }

    /// Connects now instead of waiting out the backoff.
    public func retryNow() {
        guard active, client == nil else { return }
        failures = 0
        connect()
    }

    private func connect() {
        retryTask?.cancel()
        generation += 1
        let attempt = generation
        if case .needsPairing = status { return }
        status = .connecting
        guard let token = store.token(for: server) else {
            status = .needsPairing("This device's pairing is missing. Pair again.")
            return
        }
        let server = server
        let clientId = clientId
        Task {
            do {
                let (client, host) = try await Connector.connect(server, token: token, clientId: clientId)
                guard attempt == generation, active else {
                    client.close()
                    return
                }
                store.remember(host: host, for: server.id)
                self.server.lastHost = host
                await connected(client, attempt: attempt)
            } catch let error as ConnectError {
                guard attempt == generation else { return }
                if error.recoverable {
                    scheduleRetry(error.localizedDescription)
                } else {
                    status = .needsPairing(error.localizedDescription)
                }
            } catch {
                guard attempt == generation else { return }
                scheduleRetry(String(describing: error))
            }
        }
    }

    private func scheduleRetry(_ reason: String) {
        status = .offline(reason)
        failures += 1
        guard active else { return }
        // 1, 2, 4, 8, 15 seconds: a phone moves between networks often and briefly.
        let delay = min(Double(1 << min(failures - 1, 4)), 15)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func connected(_ client: ServerClient, attempt: Int) async {
        self.client = client
        failures = 0
        acknowledged = [:]
        let events = client.events
        Task { [weak self] in
            for await event in events {
                guard let self, attempt == self.generation else { return }
                self.handle(event, attempt: attempt)
            }
        }
        do {
            try await readCatalog()
            try await readTabs()
            try await readActivity()
        } catch {
            guard attempt == generation else { return }
            client.close()
            return
        }
        guard attempt == generation else { return }
        status = .connected
        gitRead = [:]
        refreshGit()
        if let watchedProject { watchGit(watchedProject) }
        if let terminalColors { try? await client.setTerminalColors(terminalColors) }
        sendIntents()
        for terminal in terminals.values { terminal.connectionRestored(client) }
        for agent in agents.values { agent.connectionRestored(client) }
        for simulator in simulators.values { simulator.refresh() }
    }

    private func handle(_ event: ClientEvent, attempt: Int) {
        switch event {
        case .changed(let topic, _):
            switch topic {
            case .tabs: refreshTabs()
            case .catalog: Task { try? await readCatalog() }
            case .activity: Task { try? await readActivity() }
            case .simulators: listSimulators()
            default: break
            }
        case .agentChatChanged(let session, let revision):
            agents[session]?.changed(revision: revision)
        case .sessionMetadata(let session, let value):
            metadata[session] = value
        case .progress(let session, let value):
            progress[session] = value
        case .sessionEnded(let session, _):
            metadata[session] = nil
            progress[session] = nil
        case .serverRestarting:
            client?.close()
        case .disconnected(let error):
            guard attempt == generation else { return }
            client = nil
            for terminal in terminals.values { terminal.connectionLost() }
            for simulator in simulators.values { simulator.connectionLost() }
            if active { scheduleRetry(error.description) }
        case .gitChanged(let project):
            refreshGit(force: [project])
        case .filesChanged:
            break
        }
    }

    // MARK: Reading shared state

    func readCatalog() async throws {
        guard let client else { return }
        let page = try await client.catalog()
        home = page.home
        projects = page.projects
        materialize()
    }

    private func readActivity() async throws {
        guard let client else { return }
        let next = try await client.activity()
        if next.revision >= activity.revision || next.revision == 0 { activity = next }
    }

    /// Reads the tabs again; a burst of changes costs one read at a time.
    private func refreshTabs() {
        guard !refreshingTabs else {
            tabsDirty = true
            return
        }
        refreshingTabs = true
        Task {
            defer { refreshingTabs = false }
            repeat {
                tabsDirty = false
                try? await readTabs()
            } while tabsDirty
        }
    }

    private func readTabs() async throws {
        guard let client else { return }
        let next = try await client.tabs()
        if let snapshot, next.revision < snapshot.revision { return }
        let applied = Set(next.applied)
        let included = { [acknowledged] (intent: TabIntent) in
            applied.contains(intent.operation) || acknowledged[intent.operation].map { $0 <= next.revision } == true
        }
        for intent in pending where included(intent) { acknowledged[intent.operation] = nil }
        pending.removeAll(where: included)
        snapshot = next
        materialize()
        startConfirmedTerminals()
        syncReferences()
        refreshGit()
    }

    /// The board: the server's tabs, then every pending change, through the reducer.
    private func materialize() {
        guard let home else { return }
        var next = TabBoard(home: home, projects: snapshot?.projects ?? [])
        let known = Set(projects.map(\.id))
        for intent in pending {
            _ = try? TabReducer.apply(intent.mutation, to: &next) { known.contains($0) }
        }
        board = next
        followSimulatorPanes()
    }

    // MARK: Changing tabs

    /// Applies `mutation` here at once and queues it for the server.
    public func perform(_ mutation: TabMutation) throws {
        guard var next = board else { throw ConnectError.failed("Not connected to \(server.name) yet.") }
        let known = Set(projects.map(\.id))
        try TabReducer.apply(mutation, to: &next) { known.contains($0) }
        pending.append(TabIntent(mutation: mutation))
        board = next
        followSimulatorPanes()
        sendIntents()
    }

    /// Sends waiting changes one at a time, oldest first.
    private func sendIntents() {
        guard !sending, let client, status == .connected else { return }
        guard let intent = pending.first(where: { acknowledged[$0.operation] == nil }) else { return }
        sending = true
        Task {
            defer {
                sending = false
                if self.client === client { sendIntents() }
            }
            do {
                let revision = try await client.mutateTabs(intent)
                acknowledged[intent.operation] = revision
            } catch let error as ClientError where error.serverCode != nil {
                // Another app changed the same tab first; the server's tabs win.
                pending.removeAll { $0.operation == intent.operation }
                materialize()
            } catch {
                return
            }
            refreshTabs()
        }
    }

    // MARK: Tabs and panes

    public func project(_ id: ProjectId) -> ProjectDescriptor? { projects.first { $0.id == id } }

    public func tab(_ id: TabId) -> (project: ProjectId, tab: Tab)? {
        guard let board else { return nil }
        for entry in board.projects {
            if let tab = entry.tabs.first(where: { $0.id == id }) { return (entry.project, tab) }
        }
        return nil
    }

    /// A new tab in Home showing one pane of `kind`.
    @discardableResult
    public func newTab(_ kind: MobilePaneKind, size: Size) throws -> TabId {
        guard let home else { throw ConnectError.failed("Not connected to \(server.name) yet.") }
        return try newTab(kind, in: home, size: size)
    }

    /// A new tab after `project`'s last one, showing one pane of `kind`. With
    /// `setup`, a terminal first types it, and an agent opens beside that
    /// terminal, as the desktop opens a new worktree.
    @discardableResult
    public func newTab(_ kind: MobilePaneKind, in project: ProjectId, setup: String? = nil, size: Size) throws -> TabId {
        let after = board?.projects.first { $0.project == project }?.tabs.last?.id
        guard let setup else {
            let tab = Tab(pane: makePane(kind, project: project, size: size))
            try perform(.createTab(project: project, tab: tab, after: after))
            return tab.id
        }
        let terminal = makePane(.terminal, project: project, size: size, launch: TerminalLaunch(command: setup))
        let tab = Tab(pane: terminal)
        try perform(.createTab(project: project, tab: tab, after: after))
        if kind != .terminal {
            try perform(.insertPane(makePane(kind, project: project, size: size), anchor: terminal.id, edge: .right))
        }
        return tab.id
    }

    /// A pane of `kind` beside `anchor` in `tab`, or the first tab of a
    /// project that has none.
    @discardableResult
    public func newPane(_ kind: MobilePaneKind, project: ProjectId, beside anchor: PaneId?, edge: Direction = .right,
                        size: Size) throws -> PaneId {
        let pane = makePane(kind, project: project, size: size)
        if let anchor {
            try perform(.insertPane(pane, anchor: anchor, edge: edge))
        } else {
            try perform(.createTab(project: project, tab: Tab(pane: pane), after: nil))
        }
        return pane.id
    }

    /// Records the simulator a simulator pane shows, on every device.
    public func setSimulator(_ pane: PaneId, _ simulator: SimulatorPane) throws {
        try perform(.updatePane(pane, content: .simulator(simulator)))
    }

    public func closePane(_ pane: PaneId) throws {
        try perform(.removePane(pane, keepSession: false))
    }

    public func closeTab(_ tab: TabId) throws {
        try perform(.closeTab(tab, keepSessions: false))
    }

    private func makePane(_ kind: MobilePaneKind, project: ProjectId, size: Size, launch: TerminalLaunch? = nil) -> Pane {
        switch kind {
        case .terminal:
            let pane = Pane(content: .terminal(session: nil), launch: launch)
            panesToStart[pane.id] = TerminalStart(project: project, size: size)
            return pane
        case .agent(let provider):
            return Pane(content: .agent(session: SessionId(), provider: provider))
        case .simulator:
            return Pane(content: .simulator(SimulatorPane()))
        }
    }

    /// Starts the terminals of panes this app added once the server keeps them.
    private func startConfirmedTerminals() {
        guard let client, let snapshot, !panesToStart.isEmpty else { return }
        for entry in snapshot.projects {
            for pane in entry.tabs.flatMap(\.panes) {
                guard let start = panesToStart[pane.id], !starting.contains(pane.id) else { continue }
                guard case .terminal(nil) = pane.content else {
                    panesToStart[pane.id] = nil
                    continue
                }
                let directory = pane.launch?.directory ?? project(entry.project)?.directory ?? ServerPath("~")
                starting.insert(pane.id)
                let request = CreateSession(project: start.project, operation: pane.id.creationToken,
                                            directory: directory, size: start.size, pane: pane.id,
                                            input: pane.launch?.command)
                Task {
                    defer { starting.remove(pane.id) }
                    do {
                        _ = try await client.createSession(request)
                        panesToStart[pane.id] = nil
                    } catch let error as ClientError where error.serverCode != nil {
                        panesToStart[pane.id] = nil
                    } catch {}
                    refreshTabs()
                }
            }
        }
    }

    /// Tells the server which terminals this app shows, so it sends their titles.
    private func syncReferences() {
        guard let client, let board else { return }
        let sessions = board.projects.flatMap(\.tabs).flatMap(\.panes).compactMap(\.content.session)
        Task { try? await client.syncSessionReferences(owner: nil, revision: 0, sessions: sessions) }
    }

    // MARK: Git and icons

    /// Reads branch and base for projects with open tabs: those not read in
    /// the last half minute, and `force`.
    func refreshGit(force: Set<ProjectId> = []) {
        guard let client, let board else { return }
        let now = Date()
        let open = Set(board.projects.filter { $0.project != home && $0.tabs.contains { !$0.panes.isEmpty } }.map(\.project))
        for project in open where force.contains(project) || gitRead[project].map({ now.timeIntervalSince($0) > 30 }) ?? true {
            gitRead[project] = now
            Task {
                guard case .summary(let summary)? = try? await client.git(GitRequest(project: project, action: .summary)) else {
                    return
                }
                if gitSummaries[project] != .some(summary) { gitSummaries[project] = .some(summary) }
            }
        }
    }

    /// Follows `project`'s working tree, so its branch updates while its tab shows.
    public func watchGit(_ project: ProjectId) {
        watchedProject = project
        guard let client, project != home else { return }
        Task { _ = try? await client.git(GitRequest(project: project, action: .watch)) }
        refreshGit(force: [project])
    }

    /// The project's icon bytes; starts looking for them on first use.
    public func icon(_ project: ProjectId) -> Data? {
        if let icon = projectIcons[project] { return icon }
        guard let client, !iconSearches.contains(project), let target = self.project(project), !target.home else { return nil }
        iconSearches.insert(project)
        let cache = Self.iconCache(project)
        let isImage = isImage
        Task {
            if let cached = try? Data(contentsOf: cache) {
                if !cached.isEmpty { projectIcons[project] = cached }
                return
            }
            let found = await ProjectIconFinder.find(client: client, project: project, isImage: isImage)
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An empty file remembers that there is none.
            try? (found ?? Data()).write(to: cache)
            if let found { projectIcons[project] = found }
        }
        return nil
    }

    private static func iconCache(_ project: ProjectId) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProjectIcons", isDirectory: true).appendingPathComponent(project.description)
    }

    // MARK: Activity

    public func agentActivity(_ session: SessionId) -> AgentActivity? {
        activity.agents.first { $0.session == session }
    }

    public func markRead(sessions: Set<SessionId>) {
        let unread = activity.events.filter { !$0.read && sessions.contains($0.session) }.map(\.id)
        guard !unread.isEmpty, let client else { return }
        Task { try? await client.acknowledgeActivity(unread) }
    }

    // MARK: Panes' controllers

    /// The controller for a terminal session, shared by every view of it.
    public func terminal(_ session: SessionId) -> TerminalController {
        if let existing = terminals[session] { return existing }
        let controller = TerminalController(session: session, server: self)
        terminals[session] = controller
        return controller
    }

    /// The controller for an agent pane's chat.
    public func agent(_ session: SessionId, project: ProjectId, provider: AgentChatProvider) -> AgentChatController {
        if let existing = agents[session] { return existing }
        let controller = AgentChatController(session: session, project: project, provider: provider, server: self)
        agents[session] = controller
        return controller
    }

    /// The controller for a simulator pane, shared by every view of it.
    public func simulator(_ pane: PaneId, choice: SimulatorPane) -> SimulatorController {
        if let existing = simulators[pane] { return existing }
        let controller = SimulatorController(pane: pane, choice: choice, server: self)
        simulators[pane] = controller
        controller.refresh()
        return controller
    }

    /// Lists the server's simulators for every simulator pane: one request
    /// at a time, and a burst of changes costs one more.
    func listSimulators() {
        guard let client, !simulators.isEmpty else { return }
        guard !listingSimulators else {
            simulatorsDirty = true
            return
        }
        listingSimulators = true
        Task {
            defer { listingSimulators = false }
            repeat {
                simulatorsDirty = false
                do {
                    let list = try await client.listSimulators()
                    guard self.client === client else { return }
                    for simulator in simulators.values { simulator.listed(list) }
                } catch {
                    guard self.client === client else { return }
                    for simulator in simulators.values { simulator.fail(error) }
                }
            } while simulatorsDirty
        }
    }

    /// Whether the server shares its simulators: always while offline, so
    /// the choice stays put until it says otherwise.
    public var sharesSimulators: Bool { client?.supports(.simulators) ?? true }

    /// Tells simulator panes what the tabs now say they show.
    private func followSimulatorPanes() {
        guard !simulators.isEmpty, let board else { return }
        for pane in board.projects.flatMap(\.tabs).flatMap(\.panes) {
            guard case .simulator(let choice) = pane.content else { continue }
            simulators[pane.id]?.paneChanged(choice)
        }
    }

    /// The open controller of an agent pane, if one is shown.
    func agentController(_ session: SessionId) -> AgentChatController? { agents[session] }

    /// Drops controllers of panes no longer on the board.
    public func pruneControllers() {
        guard let board else { return }
        let contents = board.projects.flatMap(\.tabs).flatMap(\.panes).map(\.content)
        let liveTerminals = Set(contents.compactMap(\.session))
        let liveAgents = Set(contents.compactMap(\.agentSession))
        for (session, terminal) in terminals where !liveTerminals.contains(session) {
            terminal.detach()
            terminals[session] = nil
        }
        for session in agents.keys where !liveAgents.contains(session) { agents[session] = nil }
        let liveSimulators = Set(board.projects.flatMap(\.tabs).flatMap(\.panes).filter {
            if case .simulator = $0.content { return true }
            return false
        }.map(\.id))
        for (pane, simulator) in simulators where !liveSimulators.contains(pane) {
            simulator.close()
            simulators[pane] = nil
        }
    }
}

/// The pane kinds this app opens.
public enum MobilePaneKind: Hashable, Sendable {
    case terminal
    case agent(AgentChatProvider)
    /// A simulator pane, which then lists the server's simulators to choose one.
    case simulator
}
