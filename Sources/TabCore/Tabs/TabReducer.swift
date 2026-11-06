import Foundation

/// A server's tabs as one value: each project's tabs, in order. The server
/// and every app change it through `TabReducer`, so an app shows exactly
/// what its server will keep.
public struct TabBoard: Equatable, Sendable {
    /// The server's Home, the only project that holds several tabs.
    public var home: ProjectId
    public private(set) var projects: [ProjectTabs]

    public init(home: ProjectId, projects: [ProjectTabs] = []) {
        self.home = home
        self.projects = projects.filter { !$0.tabs.isEmpty }
    }

    public func tabs(_ project: ProjectId) -> [Tab] {
        projects.first { $0.project == project }?.tabs ?? []
    }

    public var allTabs: [Tab] { projects.flatMap(\.tabs) }
    public var allPanes: [Pane] { allTabs.flatMap(\.panes) }

    /// The project and tab holding `pane`.
    public func locate(pane: PaneId) -> (project: ProjectId, tab: TabId)? {
        for entry in projects {
            if let tab = entry.tabs.first(where: { $0.pane(pane) != nil }) { return (entry.project, tab.id) }
        }
        return nil
    }

    public func locate(tab: TabId) -> ProjectId? {
        projects.first { $0.tabs.contains { $0.id == tab } }?.project
    }

    public func tab(_ id: TabId) -> Tab? { allTabs.first { $0.id == id } }

    /// Whether a pane shows the terminal `session`.
    public func shows(session: SessionId) -> Bool {
        allPanes.contains { $0.content.session == session }
    }

    mutating func setTabs(_ project: ProjectId, _ tabs: [Tab]) {
        if let index = projects.firstIndex(where: { $0.project == project }) {
            if tabs.isEmpty {
                projects.remove(at: index)
            } else {
                projects[index].tabs = tabs
            }
        } else if !tabs.isEmpty {
            projects.append(ProjectTabs(project: project, tabs: tabs))
        }
    }

    mutating func editTab(_ id: TabId, _ change: (inout Tab) throws -> Void) throws {
        guard let project = locate(tab: id) else { throw TabChangeError.gone("tab") }
        var tabs = self.tabs(project)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { throw TabChangeError.gone("tab") }
        try change(&tabs[index])
        setTabs(project, tabs)
    }

    /// Removes the projects `keep` refuses, with their tabs.
    public mutating func retainProjects(_ keep: (ProjectId) -> Bool) {
        projects.removeAll { !keep($0.project) }
    }

    /// Checks every tab, and that tab and pane ids are unique.
    public func validate() throws {
        var tabIds = Set<TabId>()
        var paneIds = Set<PaneId>()
        var projectIds = Set<ProjectId>()
        var count = 0
        for entry in projects {
            guard projectIds.insert(entry.project).inserted else { throw LayoutError("a project is listed twice") }
            if entry.project != home && entry.tabs.count > 1 {
                throw LayoutError("only Home holds several tabs")
            }
            for tab in entry.tabs {
                count += 1
                guard tabIds.insert(tab.id).inserted else { throw LayoutError("duplicate tab \(tab.id)") }
                guard tab.panes.count <= Limits.maxPanesPerTab else { throw LayoutError("too many panes in a tab") }
                try tab.validate()
                for pane in tab.panes where !paneIds.insert(pane.id).inserted {
                    throw LayoutError("duplicate pane \(pane.id)")
                }
            }
        }
        if count > Limits.maxTabs { throw LayoutError("too many tabs") }
    }
}

/// Why a tab change can't be applied.
public enum TabChangeError: Error, Equatable, CustomStringConvertible {
    /// What the change is about no longer exists: another app removed it.
    case gone(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .gone(let what): return "the \(what) no longer exists"
        case .invalid(let message): return message
        }
    }
}

/// What a tab change ended, for the server to clean up.
public struct TabChangeEffects: Equatable, Sendable {
    /// Terminal sessions no pane shows anymore that the change didn't keep.
    public var endedSessions: [SessionId] = []
    /// Agent conversations whose pane closed.
    public var closedAgents: [SessionId] = []
    /// Terminals that were still being created for a removed pane.
    public var cancelledCreations: [OperationId] = []

    public init() {}
}

/// Applies tab changes. Every change is checked against the tabs it meets
/// and refused as a whole when its target is gone, leaving the tabs as
/// they were.
public enum TabReducer {
    @discardableResult
    public static func apply(
        _ mutation: TabMutation,
        to board: inout TabBoard,
        isProject: (ProjectId) -> Bool
    ) throws -> TabChangeEffects {
        var next = board
        let removed = try change(mutation, &next, isProject: isProject)
        do {
            try next.validate()
        } catch {
            throw TabChangeError.invalid("\(error)")
        }
        let effects = effects(of: removed, keepSessions: mutation.keepsSessions, in: next)
        board = next
        return effects
    }

    /// The panes `mutation` removed.
    private static func change(
        _ mutation: TabMutation,
        _ board: inout TabBoard,
        isProject: (ProjectId) -> Bool
    ) throws -> [Pane] {
        switch mutation {
        case let .createTab(project, tab, after):
            guard isProject(project) else { throw TabChangeError.gone("project") }
            try requireNew(tab, in: board)
            try add([tab], to: project, after: after, in: &board)
            return []

        case let .closeTab(id, _):
            guard let project = board.locate(tab: id), let tab = board.tab(id) else { throw TabChangeError.gone("tab") }
            board.setTabs(project, board.tabs(project).filter { $0.id != id })
            return tab.panes

        case let .insertPane(pane, anchor, edge):
            guard board.locate(pane: pane.id) == nil else { throw TabChangeError.invalid("the pane already exists") }
            guard let (_, tab) = board.locate(pane: anchor) else { throw TabChangeError.gone("pane") }
            try board.editTab(tab) { tab in
                tab.layout.split(anchor, new: pane.id, edge: edge)
                tab.layout.equalizeParent(of: pane.id)
                tab.panes.append(pane)
                tab.zoomed = nil
            }
            return []

        case let .removePane(id, _):
            guard let (project, tabId) = board.locate(pane: id), let tab = board.tab(tabId),
                  let pane = tab.pane(id)
            else { throw TabChangeError.gone("pane") }
            if tab.panes.count == 1 {
                board.setTabs(project, board.tabs(project).filter { $0.id != tabId })
            } else {
                try board.editTab(tabId) { tab in
                    tab.layout.removeEqualized(id)
                    tab.panes.removeAll { $0.id == id }
                    if tab.zoomed == id { tab.zoomed = nil }
                }
            }
            return [pane]

        case let .replacePane(id, new):
            guard let (_, tabId) = board.locate(pane: id), let old = board.tab(tabId)?.pane(id) else {
                throw TabChangeError.gone("pane")
            }
            guard new.id == id || board.locate(pane: new.id) == nil else {
                throw TabChangeError.invalid("the pane already exists")
            }
            try board.editTab(tabId) { tab in
                guard let index = tab.panes.firstIndex(where: { $0.id == id }) else { return }
                tab.layout.replace(id, with: new.id)
                tab.panes[index] = new
                if tab.zoomed == id { tab.zoomed = new.id }
            }
            return [old]

        case let .swapPanes(pane, other):
            guard let (_, tab) = board.locate(pane: pane) else { throw TabChangeError.gone("pane") }
            try board.editTab(tab) { tab in
                guard let layout = tab.layout.moved(pane, onto: other, edge: nil) else {
                    throw TabChangeError.gone("pane")
                }
                tab.layout = layout
                tab.zoomed = nil
            }
            return []

        case let .dockPane(pane, anchor, edge, level):
            guard let (_, tab) = board.locate(pane: pane) else { throw TabChangeError.gone("pane") }
            try board.editTab(tab) { tab in
                guard tab.pane(anchor) != nil,
                      let layout = tab.layout.docked(pane, beside: anchor, edge: edge, level: level)
                else { throw TabChangeError.gone("pane") }
                tab.layout = layout
                tab.zoomed = nil
            }
            return []

        case let .setRatio(tab, split, ratio):
            try board.editTab(tab) { tab in
                do {
                    try tab.layout.setRatio(of: split, to: ratio)
                } catch {
                    throw TabChangeError.gone("split")
                }
            }
            return []

        case .equalize(let tab):
            try board.editTab(tab) { tab in
                guard let layout = tab.layout.equalized() else { throw TabChangeError.invalid("empty split") }
                tab.layout = layout
            }
            return []

        case let .updatePane(id, content):
            guard let (_, tab) = board.locate(pane: id) else { throw TabChangeError.gone("pane") }
            try board.editTab(tab) { tab in
                guard let index = tab.panes.firstIndex(where: { $0.id == id }) else { return }
                switch (tab.panes[index].content, content) {
                case (.browser, .browser), (.simulator, .simulator):
                    tab.panes[index].content = content
                default:
                    throw TabChangeError.invalid("only a browser's page or a simulator can change")
                }
            }
            return []

        case let .adoptTabs(project, tabs):
            guard isProject(project) else { throw TabChangeError.gone("project") }
            let adopted = tabs.compactMap { leavingOut(board, from: $0) }
            try add(adopted, to: project, after: nil, in: &board)
            return []
        }
    }

    /// Adds `tabs` to Home after `after` and the pinned tabs, or merges them
    /// into another project's one tab, each new layout on the right.
    private static func add(_ tabs: [Tab], to project: ProjectId, after: TabId?, in board: inout TabBoard) throws {
        guard !tabs.isEmpty else { return }
        var existing = board.tabs(project)
        if project == board.home {
            let pinned = existing.prefix { $0.pinned }.count
            var index = after.flatMap { anchor in existing.firstIndex { $0.id == anchor }.map { $0 + 1 } }
                ?? existing.count
            index = max(index, pinned)
            existing.insert(contentsOf: tabs, at: index)
        } else {
            var merged = existing.first ?? tabs[0]
            let joining = existing.isEmpty ? Array(tabs.dropFirst()) : tabs
            for tab in joining {
                merged.layout = .split(axis: .horizontal, ratio: 0.5, first: merged.layout, second: tab.layout)
                merged.panes += tab.panes
            }
            if !joining.isEmpty { merged.zoomed = nil }
            existing = [merged]
        }
        board.setTabs(project, existing)
    }

    private static func requireNew(_ tab: Tab, in board: TabBoard) throws {
        if board.tab(tab.id) != nil || tab.panes.contains(where: { board.locate(pane: $0.id) != nil }) {
            throw TabChangeError.invalid("the tab already exists")
        }
    }

    /// `tab` without the panes the board already has, or showing a terminal
    /// it already shows; `nil` when none are left or the tab is there.
    private static func leavingOut(_ board: TabBoard, from tab: Tab) -> Tab? {
        guard board.tab(tab.id) == nil else { return nil }
        var tab = tab
        for pane in tab.panes where board.locate(pane: pane.id) != nil
            || pane.content.session.map(board.shows(session:)) == true
        {
            tab.layout.remove(pane.id)
            tab.panes.removeAll { $0.id == pane.id }
            if tab.zoomed == pane.id { tab.zoomed = nil }
        }
        return tab.panes.isEmpty ? nil : tab
    }

    private static func effects(of removed: [Pane], keepSessions: Bool, in board: TabBoard) -> TabChangeEffects {
        var effects = TabChangeEffects()
        let remaining = board.allPanes
        for pane in removed where !remaining.contains(where: { $0.id == pane.id }) {
            switch pane.content {
            case .terminal(let session?):
                if !keepSessions, !board.shows(session: session), !effects.endedSessions.contains(session) {
                    effects.endedSessions.append(session)
                }
            case .terminal(nil):
                effects.cancelledCreations.append(pane.id.creationToken)
            case .agent(let session, _):
                if !remaining.contains(where: { $0.content.agentSession == session }) {
                    effects.closedAgents.append(session)
                }
            case .browser, .simulator, .editor, .diff:
                break
            }
        }
        return effects
    }
}

extension TabMutation {
    /// Whether the panes it removes keep their terminals running.
    var keepsSessions: Bool {
        switch self {
        case .closeTab(_, let keep): return keep
        case .removePane(_, let keep): return keep
        default: return false
        }
    }
}

// Changes only a server makes: it alone knows when a terminal started or ended.
extension TabReducer {
    /// Shows a newly started terminal in the pane created for it, which
    /// stops waiting to start. Returns whether the pane is still there.
    public static func bind(_ session: SessionId, to pane: PaneId, proxy: Bool, in board: inout TabBoard) -> Bool {
        guard let (_, tabId) = board.locate(pane: pane),
              board.tab(tabId)?.pane(pane)?.content == .terminal(session: nil)
        else { return false }
        try? board.editTab(tabId) { tab in
            guard let index = tab.panes.firstIndex(where: { $0.id == pane }) else { return }
            tab.panes[index].content = .terminal(session: session)
            tab.panes[index].launch = nil
            tab.panes[index].proxy = proxy
        }
        return true
    }

    /// Removes every pane showing the terminal `session`, which ended.
    public static func removePanes(showing session: SessionId, in board: inout TabBoard) -> Bool {
        let panes = board.allPanes.filter { $0.content.session == session }.map(\.id)
        for pane in panes {
            _ = try? apply(.removePane(pane, keepSession: true), to: &board) { _ in true }
        }
        return !panes.isEmpty
    }
}
