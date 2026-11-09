import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentEntryPointTests: XCTestCase {
    func testNativeSidebarUsesSharedActivityForHiddenChats() throws {
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        model.panes.register(.agent) { EntryTestController(title: $0.pane.title) }
        let pane = try XCTUnwrap(model.newAgent(provider: .codex))
        guard case .agent(let session, _) = model.state.pane(pane)?.content else { return XCTFail("Expected agent") }
        let connection = ServerConnection(id: .local, connector: InactiveAgentConnector())
        model.connections[.local] = connection
        connection.activity = ActivitySnapshot(agents: [
            .init(session: session, project: model.currentProject.id, provider: .codex,
                  state: .working, title: "Fix the sidebar")
        ])
        var card = ActivityCardData.make(project: model.currentProject, tab: model.activeTab, primary: false, model: model)
        XCTAssertEqual(card.headline, .agent(provider: .codex, task: "Fix the sidebar"))
        XCTAssertEqual(card.status, .working)
        connection.activity.agents[0].state = .blocked
        card = ActivityCardData.make(project: model.currentProject, tab: model.activeTab, primary: false, model: model)
        XCTAssertEqual(card.status, .attention)
        connection.activity.agents[0].state = .idle
        connection.activity.events = [.init(id: 1, session: session, project: model.currentProject.id,
                                            provider: .codex, timestamp: 0, kind: .completed)]
        card = ActivityCardData.make(project: model.currentProject, tab: model.activeTab, primary: false, model: model)
        XCTAssertEqual(card.status, .attention)
        XCTAssertTrue(model.state.sessionReferences(.local).isEmpty, "Activity must not claim terminal ownership")
    }

    func testClosingTabDoesNotCommitAgentCloseUntilEveryPaneApproves() async throws {
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        let agentController = EntryTestController(title: "Agent")
        let editorController = EntryTestController(title: "Unsaved file")
        editorController.approvesClose = false
        model.panes.register(.agent) { _ in agentController }
        model.panes.register(.editor) { _ in editorController }
        var agent: PaneId?
        var editor: PaneId?
        XCTAssertTrue(model.edit { state in
            let project = try state.addProject(server: .local, directory: FileManager.default.currentDirectoryPath)
            agent = try state.openAgent(project, provider: .codex)
            editor = try state.openEditorPane(project, path: "unsaved.swift")
        })
        let ids = [try XCTUnwrap(agent), try XCTUnwrap(editor)]
        XCTAssertEqual(model.activeTab?.panes.map(\.id), ids)

        model.closeTab()
        let vetoed = await ModelFixtures.wait { editorController.approvalCount == 1 }
        XCTAssertTrue(vetoed)
        XCTAssertEqual(agentController.approvalCount, 1)
        XCTAssertEqual(agentController.commitCount, 0, "An editor veto must not terminate the agent")
        XCTAssertEqual(editorController.commitCount, 0)
        XCTAssertEqual(model.activeTab?.panes.map(\.id), ids)
        XCTAssertTrue(ids.allSatisfy { model.state.pane($0) != nil })

        editorController.approvesClose = true
        model.closeTab()
        let closed = await ModelFixtures.wait { ids.allSatisfy { model.state.pane($0) == nil } }
        XCTAssertTrue(closed)
        XCTAssertEqual(agentController.approvalCount, 2)
        XCTAssertEqual(editorController.approvalCount, 2)
        XCTAssertEqual(agentController.commitCount, 1)
        XCTAssertEqual(editorController.commitCount, 1)
    }

    func testClosingSingleAgentPaneRequiresApprovalAndSuccessfulCommit() async throws {
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        let controller = EntryTestController(title: "Agent")
        model.panes.register(.agent) { _ in controller }
        let pane = try XCTUnwrap(model.newAgent())
        controller.approvesClose = false
        model.closePane(pane)
        let vetoed = await ModelFixtures.wait { controller.approvalCount == 1 }
        XCTAssertTrue(vetoed)
        XCTAssertEqual(controller.commitCount, 0)
        XCTAssertNotNil(model.state.pane(pane))

        controller.approvesClose = true
        controller.commitsClose = false
        model.closePane(pane)
        let failed = await ModelFixtures.wait { controller.commitCount == 1 }
        XCTAssertTrue(failed)
        XCTAssertNotNil(model.state.pane(pane), "A failed server close must keep its pane")

        controller.commitsClose = true
        model.closePane(pane)
        let closed = await ModelFixtures.wait { model.state.pane(pane) == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(controller.commitCount, 2)
    }

    func testNewTabAddsACardWhileNewPaneJoinsAnExistingTab() throws {
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        model.panes.register(.simulator) { EntryTestController(title: $0.pane.title) }
        let before = model.state.home.tabs.count
        let first = try XCTUnwrap(model.newTab(.simulator))
        _ = try XCTUnwrap(model.newTab(.simulator))
        XCTAssertEqual(model.state.home.tabs.count, before + 2, "each New Tab is its own card")
        let card = try XCTUnwrap(model.state.home.tabs.first { $0.panes.contains { $0.id == first } })
        let added = try XCTUnwrap(model.newPane(.simulator, in: model.state.home.id, tab: card.id))
        XCTAssertEqual(model.state.home.tabs.count, before + 2, "New Pane adds no card")
        XCTAssertEqual(model.state.home.tabs.first { $0.id == card.id }?.layout.leaves, [first, added])

        var project: ProjectId?
        XCTAssertTrue(model.edit { project = try $0.addProject(server: .local, directory: FileManager.default.currentDirectoryPath) })
        let id = try XCTUnwrap(project)
        let opened = try XCTUnwrap(model.newPane(.simulator, in: id))
        let beside = try XCTUnwrap(model.newPane(.simulator, in: id))
        XCTAssertEqual(model.state.project(id)?.tabs.count, 1, "a project is one card")
        XCTAssertEqual(model.state.project(id)?.tabs.first?.layout.leaves, [opened, beside])
        XCTAssertEqual(model.activePane, beside)
    }

    func testGenericEntryPointOpensDirectlyAndPersistsStandaloneAgentIdentity() throws {
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        model.panes.register(.agent) { EntryTestController(title: $0.pane.title) }
        let menu = model.newTabMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Terminal Tab", "Agent Tab", "Browser Tab", "Simulator Tab"])
        let item = try XCTUnwrap(menu.items.first { $0.title == "Agent Tab" })
        XCTAssertNil(item.submenu, "An agent opens directly, without choosing a provider")
        for _ in 0..<2 {
            _ = (item.target as? NSObject)?.perform(try XCTUnwrap(item.action), with: item)
        }
        XCTAssertEqual(model.state.home.tabs.count, 2)
        let panes = model.state.home.tabs.flatMap(\.panes)
        guard case let .agent(first, .claude) = panes[0].content,
              case let .agent(second, .claude) = panes[1].content else {
            return XCTFail("Generic entry must create conversations with the internal default provider")
        }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(panes.map(\.title), ["Agent", "Agent"])
        XCTAssertEqual(model.activePane, panes[1].id)
        XCTAssertEqual(PaneKind(panes[0].content), .agent)
        XCTAssertEqual(PaneKind.agent.glyph, .codeBlock)
        XCTAssertEqual(PaneKind.agent.name, "Agent")
        let card = ActivityCardData.make(project: model.currentProject, tab: model.activeTab, primary: false, model: model)
        XCTAssertEqual(card.headline, .agent(provider: .claude, task: nil))
        XCTAssertNil(card.name, "A Home agent has no folder to show")
        model.saveNow()
        let restored = AppModel(dirs: model.dirs, connectorFactory: { _, _ in nil })
        XCTAssertEqual(restored.state.home.tabs, model.state.home.tabs)
        XCTAssertTrue(restored.state.sessionReferences(.local).isEmpty)
        XCTAssertTrue(model.openEditors.isEmpty)
    }

    func testRegistryReusesOnlyTheSameAgentSessionAndProvider() throws {
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        let registry = PaneRegistry()
        registry.register(.agent) { EntryTestController(title: $0.pane.title) }
        var pane = Pane(title: "Agent", content: .agent(session: SessionId(), provider: .codex))
        func controller() -> PaneContentController {
            registry.controller(for: PaneContext(pane: pane, project: model.currentProject, model: model))
        }
        let first = controller()
        pane.title = "Updated"
        XCTAssertTrue(first === controller())
        pane.content = .agent(session: SessionId(), provider: .codex)
        let second = controller()
        XCTAssertFalse(first === second)
        guard case let .agent(session, _) = pane.content else { return XCTFail("Expected agent") }
        pane.content = .agent(session: session, provider: .claude)
        XCTAssertFalse(second === controller())
    }

    func testGenericActionIsTheOnlyAgentMenuAndPaletteEntryWithLegacyBindingsStillWorking() throws {
        let items = ShortcutCatalog.menus(appName: "Tab").flatMap(\.items)
        XCTAssertTrue(items.contains(.shortcut(.newAgent, title: "New Agent")))
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        model.panes.register(.agent) { EntryTestController(title: $0.pane.title) }
        let commands = PaletteSource(model: model).rootCommands()
        XCTAssertEqual(commands.filter { $0.id == ShortcutId.newAgent.rawValue }.map(\.title), ["New Agent"])
        for id in [ShortcutId.newAgent, .newClaudeAgent, .newCodexAgent] {
            XCTAssertTrue(ShortcutCatalog.keymapActions.contains(id))
            XCTAssertTrue(id.definition.keys.isEmpty)
            if id != .newAgent {
                XCTAssertFalse(items.contains {
                    if case .shortcut(let command, _) = $0 { return command == id }
                    return false
                })
                XCTAssertFalse(commands.contains { $0.id == id.rawValue })
            }
            XCTAssertTrue(Actions(model: model).perform(id))
        }
        XCTAssertEqual(model.state.home.tabs.flatMap(\.panes).map(\.title), ["Agent", "Agent", "Agent"])
    }

    func testExplicitLegacyProviderSeedDoesNotChangeGenericPaneOrSidebarIdentity() throws {
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        model.panes.register(.agent) { EntryTestController(title: $0.pane.title) }
        let pane = try XCTUnwrap(model.newAgent(provider: .codex))
        guard case .agent(_, .codex) = model.state.pane(pane)?.content else {
            return XCTFail("Explicit provider seed remains compatible")
        }
        XCTAssertEqual(model.state.pane(pane)?.title, "Agent")
        let card = ActivityCardData.make(project: model.currentProject, tab: model.activeTab, primary: false, model: model)
        XCTAssertEqual(card.headline, .agent(provider: .codex, task: nil))
        XCTAssertNil(card.name, "A Home agent has no folder to show")
    }
}

@MainActor
private final class EntryTestController: PaneContentController {
    let view = NSView()
    let title: String
    var titleDidChange: (() -> Void)?
    var approvesClose = true
    var commitsClose = true
    private(set) var approvalCount = 0
    private(set) var commitCount = 0
    init(title: String) { self.title = title }
    func focusContent() {}
    func willClose() async -> Bool {
        approvalCount += 1
        return approvesClose
    }
    func commitClose() async -> Bool {
        commitCount += 1
        return commitsClose
    }
    func didShow() {}
    func didHide() {}
}


private struct InactiveAgentConnector: ServerConnector {
    func connect() async throws -> ServerAPI { throw CancellationError() }
}
