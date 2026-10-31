import Foundation

extension AppState {
    /// Opens an Agent Tab beside the project's panes, or standalone in Home.
    @discardableResult
    public mutating func openAgent(_ project: ProjectId, provider: AgentChatProvider = .claude) throws -> PaneId {
        try openAgent(project, session: SessionId(), provider: provider)
    }

    /// Opens a persisted conversation from an in-message link without allocating a new session.
    @discardableResult
    public mutating func openAgent(_ project: ProjectId, session: SessionId, provider: AgentChatProvider) throws -> PaneId {
        if let existing = self.project(project)?.tabs.flatMap(\.panes).first(where: {
            if case .agent(let found, _) = $0.content { return found == session }; return false
        }) {
            try focusPane(existing.id)
            revealCurrentProject()
            return existing.id
        }
        let pane = Pane(title: "Agent", content: .agent(session: session, provider: provider))
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
