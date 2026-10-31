import AppKit
import TabCore

/// Everything the sidebar draws, compared before rebuilding so unrelated
/// model changes cost one comparison.
struct SidebarSnapshot: Equatable {
    struct CardEntry: Equatable {
        var target: SidebarListing.Target
        var data: ActivityCardData
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
    }

    var expanded: Bool
    var filterShown: Bool
    var hints: ChordModifiers?
    var showsHostHeaders: Bool
    var hosts: [HostEntry]

    @MainActor
    init(model: AppModel, filterShown: Bool) {
        expanded = model.appearance.sidebarExpanded
        self.filterShown = filterShown
        hints = model.shortcutHints
        let listing = model.sidebarListing
        showsHostHeaders = model.knownServers.count > 1
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
            return HostEntry(server: host.server, title: host.server.isLocal ? "This Mac" : model.serverName(host.server) ?? "Remote",
                             terminals: terminals, groups: groups)
        }
    }
}
