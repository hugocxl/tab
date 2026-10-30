import Foundation

extension AppState {
    /// Opens an Agent Tab beside the project's panes, or standalone in Home.
    @discardableResult
    public mutating func openAgent(_ project: ProjectId, provider: AgentChatProvider = .claude) throws -> PaneId {
        let pane = Pane(title: "Agent", content: .agent(session: SessionId(), provider: provider))
        let tab: TabId
        if isSingleTab(project) {
            tab = try openPaneInContainer(project, pane: pane, focusLeaf: window.activePane).0
        } else {
            try projects[projectIndex(project)].requireAvailable()
            let standalone = Tab(pane: pane)
            try addTab(project, standalone)
            tab = standalone.id
        }
        try selectTab(project, tab)
        try focusPane(pane.id)
        revealCurrentProject()
        return pane.id
    }
}
