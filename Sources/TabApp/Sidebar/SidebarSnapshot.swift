import AppKit
import TabCore

/// Everything the sidebar draws, compared before rebuilding so unrelated
/// model changes cost one comparison.
struct SidebarSnapshot: Equatable {
    struct CardEntry: Equatable {
        var target: SidebarListing.Target
        var data: ActivityCardData
        /// The project the Open Tabs layout names on the card's first row.
        var header: CardHeader?
    }

    struct CardHeader: Equatable {
        var project: ProjectId
        var title: String
    }

    struct GroupEntry: Equatable {
        var project: ProjectId
        var title: String
        var hasIcon: Bool
        var canCreateWorktree: Bool
        var cards: [CardEntry]
        var creating: [String]
    }

    struct HostEntry: Equatable {
        var server: ServerId
        var title: String
        var terminals: [CardEntry]
        var groups: [GroupEntry]
        /// The Open Tabs layout's cards, in the listing's order.
        var openTabs: [CardEntry]?
    }

    var expanded: Bool
    var hints: ChordModifiers?
    /// The name filter, which the headers mark where it matched.
    var query: String
    var showsHostHeaders: Bool
    var hosts: [HostEntry]

    @MainActor
    init(model: AppModel) {
        expanded = model.appearance.sidebarExpanded
        hints = model.shortcutHints
        query = model.nameFilter
        let listing = model.sidebarListing
        showsHostHeaders = model.appearance.sidebarLayout == .tabs ? listing.hosts.count > 1 : model.knownServers.count > 1
        func header(_ project: Project) -> CardHeader {
            let root = project.parentId.flatMap { model.state.project($0) } ?? project
            return CardHeader(project: root.id, title: model.title(of: root))
        }
        hosts = listing.hosts.map { host in
            let terminals = host.terminals.compactMap { entry -> CardEntry? in
                guard let project = model.state.project(entry.project),
                      let tab = project.tabs.first(where: { $0.id == entry.tab }) else { return nil }
                return CardEntry(target: .tab(entry.tab),
                                 data: ActivityCardData.make(project: project, tab: tab, primary: false, model: model))
            }
            let groups = host.groups.compactMap { group -> GroupEntry? in
                guard let project = model.state.project(group.project) else { return nil }
                let cards = group.cards.compactMap { card -> CardEntry? in
                    guard let target = model.state.project(card.project) else { return nil }
                    return CardEntry(target: .project(card.project),
                                     data: ActivityCardData.make(project: target, tab: nil, primary: card.primary, model: model))
                }
                return GroupEntry(
                    project: project.id, title: model.title(of: project),
                    hasIcon: model.projectIcon(project.id) != nil,
                    canCreateWorktree: project.status == .available && (model.git[project.id]?.isRepository ?? false),
                    cards: cards, creating: model.worktreeCreations[project.id] ?? []
                )
            }
            let openTabs = host.openTabs.map { order -> [CardEntry] in
                var projects: [SidebarListing.Target: ProjectId] = [:]
                for entry in host.terminals { projects[.tab(entry.tab)] = entry.project }
                for card in host.groups.flatMap(\.cards) { projects[.project(card.project)] = card.project }
                let cards = Dictionary((terminals + groups.flatMap(\.cards)).map { ($0.target, $0) }, uniquingKeysWith: { first, _ in first })
                return order.compactMap { target in
                    guard var card = cards[target], let project = projects[target].flatMap({ model.state.project($0) }) else { return nil }
                    card.header = header(project)
                    return card
                }
            }
            return HostEntry(server: host.server, title: host.server.isLocal ? "This Mac" : model.serverName(host.server) ?? "Remote",
                             terminals: terminals, groups: groups, openTabs: openTabs)
        }
    }
}
