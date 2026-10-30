import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentEntryPointTests: XCTestCase {
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

    func testGenericEntryPointOpensDirectlyAndPersistsStandaloneAgentIdentity() throws {
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        model.panes.register(.agent) { EntryTestController(title: $0.pane.title) }
        let menu = model.newPaneMenu()
        XCTAssertEqual(menu.items.map(\.title), ["New Terminal", "New Agent Tab"])
        let item = try XCTUnwrap(menu.items.last)
        XCTAssertNil(item.submenu, "An Agent Tab opens directly, without choosing a provider")
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
        XCTAssertEqual(PaneKind.agent.glyph, .code)
        XCTAssertEqual(PaneKind.agent.name, "Agent")
        let card = ActivityCardData.make(project: model.currentProject, tab: model.activeTab, primary: false, model: model)
        XCTAssertEqual(card.headline, .agentTab)
        XCTAssertEqual(card.name, "Agent")
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
        XCTAssertTrue(items.contains(.shortcut(.newAgent, title: "New Agent Tab")))
        let model = AppModel(dirs: try ModelFixtures.profile(), connectorFactory: { _, _ in nil })
        model.panes.register(.agent) { EntryTestController(title: $0.pane.title) }
        let commands = PaletteSource(model: model).rootCommands()
        XCTAssertEqual(commands.filter { $0.id == ShortcutId.newAgent.rawValue }.map(\.title), ["New Agent Tab"])
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
        XCTAssertEqual(card.headline, .agentTab)
        XCTAssertEqual(card.name, "Agent")
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
