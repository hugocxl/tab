import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

final class AgentsPanelTests: XCTestCase {
    private let server = ServerId()
    private let app = ProjectId()
    private let api = ProjectId()

    private func pane(_ project: ProjectId, _ location: String, _ session: SessionId, title: String = "") -> AgentPaneInfo {
        AgentPaneInfo(project: project, location: location, pane: PaneId(), title: title, session: session)
    }

    func testRunningAgentsUseTheSnapshotStateAndUnreadCompletions() {
        let blocked = SessionId(), working = SessionId(), finished = SessionId(), idle = SessionId(), notShown = SessionId()
        let snapshot = ActivitySnapshot(
            agents: [
                AgentActivity(session: idle, project: app, provider: .codex, state: .idle),
                AgentActivity(session: finished, project: app, provider: .claude, state: .idle),
                AgentActivity(session: working, project: api, provider: .claude, state: .working),
                AgentActivity(session: blocked, project: api, provider: .pi, state: .blocked),
                AgentActivity(session: notShown, project: api, provider: .pi, state: .blocked),
            ],
            events: [
                AgentEvent(id: 1, session: finished, project: app, provider: .claude, timestamp: 0, kind: .completed),
                AgentEvent(id: 2, session: idle, project: app, provider: .codex, timestamp: 0, kind: .completed, read: true),
            ]
        )
        let panes = [
            pane(app, "app", idle, title: "  "),
            pane(app, "app", finished, title: "Refactor"),
            pane(api, "app › api", working),
            pane(api, "app › api", blocked),
            pane(api, "app › api", blocked),
        ]
        let agents = AgentsPanelModel.runningAgents([AgentsPanelSource(server: server, snapshot: snapshot, panes: panes)])
        XCTAssertEqual(agents.map(\.session), [blocked, working, finished, idle], "each session once, most urgent first")
        XCTAssertEqual(agents.map(\.status), [.blocked, .working, .completed, .idle])
        XCTAssertEqual(agents.map(\.title), ["Pi", "Claude Code", "Refactor", "Codex"], "blank pane titles use the provider")
        XCTAssertEqual(AgentsPanelModel.summary(agents), "1 need input · 1 working")
    }

    func testGroupingByProjectCountsStatusesAndSortsByUrgencyThenCount() {
        func agent(_ project: ProjectId, _ status: AgentStatus) -> RunningAgent {
            RunningAgent(server: server, session: SessionId(), project: project, location: project == app ? "app" : "api",
                         pane: PaneId(), title: "t", provider: .claude, status: status)
        }
        let other = ProjectId()
        let agents = [
            agent(api, .working), agent(other, .working), agent(other, .working), agent(app, .idle), agent(api, .idle),
            agent(other, .completed),
        ]
        let entries = AgentsPanelModel.entries(agents, grouping: .worktrees)
        XCTAssertEqual(entries.map(\.key), [.project(other), .project(api), .project(app)])
        guard case .project(_, _, _, let counts) = entries[0] else { return XCTFail("expected a project row") }
        XCTAssertEqual(counts, [0, 2, 1, 0])
        XCTAssertEqual(entries.map(\.status), [.working, .working, .idle])
        XCTAssertEqual(AgentsPanelModel.entries(agents, grouping: .agents).count, agents.count)
        XCTAssertTrue(AgentsPanelModel.entries([], grouping: .worktrees).isEmpty)
    }

    func testPlacementFollowsTheAppearance() {
        var appearance = Appearance()
        XCTAssertEqual(AgentsPanelPlacement(appearance, sidebarExpanded: true), .sidebar)
        XCTAssertEqual(AgentsPanelPlacement(appearance, sidebarExpanded: false), .popup)
        appearance.agentsPanelDock = .right
        XCTAssertEqual(AgentsPanelPlacement(appearance, sidebarExpanded: false), .right)
        appearance.agentsPanelDetached = true
        XCTAssertEqual(AgentsPanelPlacement(appearance, sidebarExpanded: true), .floating)
    }

    func testRememberedSizesStayInsideTheWindow() {
        let size = CGSize(width: 1000, height: 700)
        XCTAssertEqual(AgentsPanelGeometry.floatingFrame(nil, in: size), CGRect(x: 80, y: 80, width: 320, height: 360))
        XCTAssertEqual(AgentsPanelGeometry.floatingFrame([900, -20, 100, 5000], in: size), CGRect(x: 780, y: 0, width: 220, height: 700))
        XCTAssertEqual(AgentsPanelGeometry.floatingFrame([.nan, 0, 300, 300], in: size), CGRect(x: 80, y: 80, width: 320, height: 360))
        XCTAssertEqual(AgentsPanelGeometry.dockedHeight(50, windowHeight: 700), 140)
        XCTAssertEqual(AgentsPanelGeometry.dockedHeight(600, windowHeight: 700), 490, accuracy: 0.001)
        XCTAssertEqual(AgentsPanelGeometry.rightWidth(2000, windowWidth: 2000), 800)
        XCTAssertEqual(AgentsPanelGeometry.rightWidth(100, windowWidth: 2000), 220)
    }

    @MainActor
    func testKeyboardOpensTheSelectedRowAndMovesPersistThroughTheHost() {
        let host = StubAgentsHost()
        let controller = AgentsPanelController(host: host)
        _ = controller.view
        let first = SessionId(), second = SessionId()
        let snapshot = ActivitySnapshot(agents: [
            AgentActivity(session: first, project: app, provider: .claude, state: .blocked),
            AgentActivity(session: second, project: app, provider: .codex, state: .working),
        ])
        controller.update([AgentsPanelSource(server: server, snapshot: snapshot, panes: [pane(app, "app", second), pane(app, "app", first)])])
        XCTAssertEqual(controller.entries.count, 2)
        controller.moveSelection(1)
        controller.openSelection()
        XCTAssertEqual(host.opened, [second])

        controller.moveDock()
        XCTAssertEqual(host.appearance.agentsPanelDock, .right)
        XCTAssertTrue(host.appearance.agentsPanelVisible)
        controller.toggleDetached()
        XCTAssertTrue(host.appearance.agentsPanelDetached)
        XCTAssertEqual(host.appearance.agentsPanelFrame, AgentsPanelGeometry.defaultFrame)
        controller.toggleDetached()
        XCTAssertFalse(host.appearance.agentsPanelDetached)
        XCTAssertEqual(host.appearance.agentsPanelDock, .right, "reattaching keeps the last side")
        XCTAssertEqual(host.placementChanges, 3)

        host.appearance.agentsPanelGrouping = .worktrees
        controller.appearanceDidChange()
        XCTAssertEqual(controller.entries.map(\.key), [.project(app)])
        controller.openSelection()
        XCTAssertEqual(host.openedProjects, [app])
    }
}

@MainActor
final class StubAgentsHost: AgentsPanelHost {
    var theme = AppTheme(systemIsDark: true)
    var appearance = Appearance()
    var agentsPanelActive: (server: ServerId, project: ProjectId, session: SessionId?)?
    var opened: [SessionId] = []
    var openedProjects: [ProjectId] = []
    var placementChanges = 0

    func updateAppearance(_ change: (inout Appearance) -> Void) { change(&appearance) }
    func openAgent(_ agent: RunningAgent) { opened.append(agent.session) }
    func openProject(_ project: ProjectId, server: ServerId) { openedProjects.append(project) }
    func focusActivePane() {}
    func hideAgentsPanel() { appearance.agentsPanelVisible = false }
    func closeAgentsPopup() {}
    func agentsPanelPlacementDidChange() { placementChanges += 1 }
}
