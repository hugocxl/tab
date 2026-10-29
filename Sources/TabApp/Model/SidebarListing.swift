import Foundation
import TabCore

/// What the sidebar lists, in order: Home terminals as cards, then each
/// listed project's header with its primary checkout and worktrees as cards.
/// Pure, so the order and the name filter are tested without views.
public struct SidebarListing: Equatable {
    public struct Group: Equatable {
        public var project: ProjectId
        /// Cards under the header: the project itself (primary) and its
        /// worktrees. Empty for a missing folder.
        public var cards: [Card]
        /// The project is a Git repository whose worktrees are shown.
        public var hasWorktrees: Bool
    }

    public struct Card: Equatable {
        public var project: ProjectId
        /// The repository's own checkout, as opposed to a worktree.
        public var primary: Bool
    }

    /// A card the number shortcuts (Cmd+1–9) jump to.
    public enum Target: Hashable {
        case tab(TabId)
        case project(ProjectId)
    }

    public var terminals: [(project: ProjectId, tab: TabId)]
    public var groups: [Group]

    public static func == (left: SidebarListing, right: SidebarListing) -> Bool {
        left.groups == right.groups
            && left.terminals.map(\.tab) == right.terminals.map(\.tab)
            && left.terminals.map(\.project) == right.terminals.map(\.project)
    }

    /// Cards in sidebar order, for the number shortcuts.
    public var targets: [Target] {
        terminals.map { .tab($0.tab) } + groups.flatMap { $0.cards.map { .project($0.project) } }
    }

    /// Top-level projects in sidebar order, for Ctrl+1–9 and next/previous.
    public var projects: [ProjectId] { groups.map(\.project) }
}

/// Builds the listing from the model's state.
public struct SidebarListingBuilder {
    public var state: AppState
    public var appearance: Appearance
    public var servers: [ServerEntry]
    /// The name filter; empty lists everything.
    public var query: String
    /// Projects known to be Git repositories.
    public var repositories: Set<ProjectId>

    public init(state: AppState, appearance: Appearance, servers: [ServerEntry], query: String,
                repositories: Set<ProjectId>) {
        self.state = state
        self.appearance = appearance
        self.servers = servers
        self.query = query
        self.repositories = repositories
    }

    public func build() -> SidebarListing {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let terminals = standaloneTerminals().filter { project, tab in
            needle.isEmpty || matches(terminalTitle(project, tab), needle)
        }.map { (project: $0.0.id, tab: $0.1.id) }
        var groups: [SidebarListing.Group] = []
        for parent in listedParents() {
            let showsWorktrees = hasWorktrees(parent)
            var cards: [SidebarListing.Card] = []
            if parent.status == .available {
                cards.append(SidebarListing.Card(project: parent.id, primary: repositories.contains(parent.id)))
                if showsWorktrees {
                    cards += children(of: parent.id).map { SidebarListing.Card(project: $0.id, primary: false) }
                }
            }
            if !needle.isEmpty {
                let parentMatches = matches(title(parent), needle)
                if !parentMatches {
                    cards = cards.filter { card in
                        guard let project = state.project(card.project), !card.primary else { return false }
                        return matches(project.name, needle)
                    }
                    if cards.isEmpty { continue }
                }
            }
            groups.append(SidebarListing.Group(project: parent.id, cards: cards, hasWorktrees: showsWorktrees))
        }
        return SidebarListing(terminals: terminals, groups: groups)
    }

    /// The name a project goes by: another computer's Home by its server.
    public func title(_ project: Project) -> String {
        if project.isRemoteHome, let server = servers.first(where: { $0.id == project.serverId }) {
            return server.name
        }
        return project.name
    }

    private func matches(_ text: String, _ needle: String) -> Bool {
        text.lowercased().contains(needle)
    }

    private func terminalTitle(_ project: Project, _ tab: Tab) -> String {
        tab.title(active: state.shownPane(tab))
    }

    /// Home tabs: this computer's always, other computers' with their host.
    func standaloneTerminals() -> [(Project, Tab)] {
        state.projects.filter { project in
            project.home && (project.serverId.isLocal || appearance.sidebarHost.matches(project.serverId))
        }.flatMap { project in project.tabs.map { (project, $0) } }
    }

    /// Whether the project shows its worktrees: a repository, or one with
    /// worktree projects, whose worktrees aren't hidden.
    public func hasWorktrees(_ project: Project) -> Bool {
        guard !project.home, project.parentId == nil, worktreesVisible(project) else { return false }
        return repositories.contains(project.id) || state.projects.contains { $0.parentId == project.id }
    }

    public func worktreesVisible(_ project: Project) -> Bool {
        !appearance.hiddenWorktrees.contains(project.id) && !project.worktreesHidden
    }

    public func children(of parent: ProjectId) -> [Project] {
        state.projects.filter { $0.parentId == parent }
    }

    /// Top-level projects the workspace and host filters list, in sidebar
    /// order: this computer's first, each server's Home first among its own.
    public func listedParents() -> [Project] {
        var parents = state.projects.filter { project in
            project.parentId == nil
                && (!project.home || project.isRemoteHome)
                && state.isListed(project)
                && appearance.sidebarHost.matches(project.serverId)
        }
        sort(&parents)
        let byServer = state.remoteServersSelected || appearance.sidebarProjectOrder != .manual
        let serverIndex: (Project) -> Int = { project in
            guard byServer else { return 0 }
            return (servers.firstIndex { $0.id == project.serverId }).map { $0 + 1 } ?? 0
        }
        return parents.enumerated().sorted { left, right in
            let leftKey = (left.element.serverId.isLocal ? 0 : 1, serverIndex(left.element))
            let rightKey = (right.element.serverId.isLocal ? 0 : 1, serverIndex(right.element))
            if leftKey != rightKey { return leftKey < rightKey }
            return left.offset < right.offset
        }.map(\.element)
    }

    private func sort(_ projects: inout [Project]) {
        switch appearance.sidebarProjectOrder {
        case .manual:
            return
        case .name, .nameDescending:
            let descending = appearance.sidebarProjectOrder == .nameDescending
            projects.sort { left, right in
                if left.home != right.home { return left.home }
                let order = left.name.localizedStandardCompare(right.name)
                return descending ? order == .orderedDescending : order == .orderedAscending
            }
        case .recentlyActive:
            let recent = Dictionary(appearance.projectRecent.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            projects = projects.enumerated().sorted { left, right in
                if left.element.home != right.element.home { return left.element.home }
                let leftRank = recent[left.element.id] ?? Int.max
                let rightRank = recent[right.element.id] ?? Int.max
                return leftRank != rightRank ? leftRank < rightRank : left.offset < right.offset
            }.map(\.element)
        case .dateAdded:
            projects = projects.enumerated().sorted { left, right in
                if left.element.home != right.element.home { return left.element.home }
                let leftDate = left.element.createdAt ?? .distantPast
                let rightDate = right.element.createdAt ?? .distantPast
                return leftDate != rightDate ? leftDate < rightDate : left.offset < right.offset
            }.map(\.element)
        }
    }
}
