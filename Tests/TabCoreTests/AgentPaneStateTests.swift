import XCTest
@testable import TabCore

final class AgentPaneStateTests: XCTestCase {
    func testProjectAgentsShareTerminalLayoutAndPersistIdentityWithoutTerminalSemantics() throws {
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: FileManager.default.currentDirectoryPath)
        try state.openTerminalTab(project)
        let terminal = try XCTUnwrap(state.window.activePane)
        let agent = try state.openAgent(project, provider: .codex)
        guard case let .agent(session, provider) = state.pane(agent)?.content else {
            return XCTFail("Expected agent content")
        }
        XCTAssertEqual(provider, .codex)
        XCTAssertEqual(state.pane(agent)?.title, "Agent")
        XCTAssertEqual(state.pane(agent)?.content.nativeTitle, "Agent")
        XCTAssertFalse(try XCTUnwrap(state.pane(agent)).content.isTerminal)
        XCTAssertNil(state.pane(agent)?.content.session)
        XCTAssertEqual(state.project(project)?.tabs.count, 1)
        XCTAssertEqual(state.project(project)?.tabs.first?.layout.leaves, [terminal, agent])
        XCTAssertEqual(state.neighbor(of: terminal, .right), agent)
        XCTAssertEqual(state.window.activePane, agent)
        XCTAssertTrue(state.sessionReferences(.local).isEmpty)
        try state.toggleZoom(agent)
        let restored = try AppStateStore.decode(AppStateStore.encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.pane(agent)?.content, .agent(session: session, provider: .codex))
        try state.closePane(agent)
        XCTAssertEqual(state.project(project)?.tabs.first?.layout, .leaf(terminal))
        XCTAssertTrue(state.pendingDiscards(.local).isEmpty)
        XCTAssertTrue(state.pendingCancellations(.local).isEmpty)
    }

    func testHomeAgentsOpenStandaloneAndCanSplitWithTerminals() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let original = try XCTUnwrap(state.window.activePane)
        let claude = try state.openAgent(state.home.id)
        let codex = try state.openAgent(state.home.id, provider: .codex)
        XCTAssertEqual(state.home.tabs.count, 3)
        XCTAssertEqual(state.pane(claude)?.title, "Agent")
        XCTAssertEqual(state.pane(codex)?.title, "Agent")
        XCTAssertEqual(state.home.tabs.map(\.layout.leaves), [[original], [claude], [codex]])
        let terminal = try state.splitPane(codex, edge: .down)
        XCTAssertEqual(state.home.tabs.last?.layout.leaves, [codex, terminal])
        XCTAssertEqual(try AppStateStore.decode(AppStateStore.encode(state)), state)
        XCTAssertNotEqual(state.pane(claude)?.content, state.pane(codex)?.content)
    }

    func testAgentPersistenceRequiresSessionAndProvider() throws {
        let session = SessionId()
        let valid = "{\"type\":\"agent\",\"session\":\"\(session)\",\"provider\":\"claude\",\"future\":true}"
        XCTAssertEqual(try JSONDecoder().decode(PaneContent.self, from: Data(valid.utf8)),
                       .agent(session: session, provider: .claude))
        for json in ["{\"type\":\"agent\",\"provider\":\"claude\"}",
                     "{\"type\":\"agent\",\"session\":\"\(session)\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(PaneContent.self, from: Data(json.utf8)))
        }
    }

    func testLegacyProviderTitlesRestoreAsGenericAgentsWithoutChangingIdentityOrCustomTabTitle() throws {
        var state = try AppState.bootstrap()
        let pane = try state.openAgent(state.home.id, provider: .codex)
        let content = try XCTUnwrap(state.pane(pane)?.content)
        try state.setPaneTitle(pane, "Codex")
        let tab = try XCTUnwrap(state.home.tabs.first?.id)
        try state.setTabTitle(tab, "My task")
        let restored = try AppStateStore.decode(AppStateStore.encode(state))
        XCTAssertEqual(restored.pane(pane)?.title, "Agent")
        XCTAssertEqual(restored.pane(pane)?.content, content)
        XCTAssertEqual(restored.home.tabs.first?.customTitle, "My task")
    }
}
