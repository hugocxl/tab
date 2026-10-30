import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// Exercises the real workspace shell around agent panes, using in-memory conversations.
@MainActor
final class AgentWorkspaceSnapshotTests: XCTestCase {
    func testAgentTabsAlongsideTerminalAndEmptyProjectEntry() async throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render the agent workspace")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity,
            catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
        let model = AppModel(dirs: dirs, theme: theme) { id, _ in
            id.isLocal ? FakeConnector(server: server) : nil
        }
        model.panes.register(.agent) { context in
            guard case let .agent(session, provider) = context.pane.content else {
                preconditionFailure("Expected an agent pane")
            }
            let snapshot = AgentChatSnapshot(session: session, project: context.project.id,
                provider: provider, revision: 1, items: [
                    AgentChatItem(kind: .user, text: "How does this workspace fit together?"),
                    AgentChatItem(kind: .tool, text: "Read README.md", detail: "Native macOS workspace · Swift · AppKit"),
                    AgentChatItem(kind: .assistant, text: "### One workspace, everything in reach\n\nEach project can contain **terminals**, editors and agent conversations.\n\n- Keep your shell beside the chat.\n- Choose a model and effort below.\n- Reopen Tab to resume your conversation.\n\nThe background server keeps the conversation connected while you work."),
                ])
            return AgentPaneController(session: session, project: context.project.id,
                                       provider: provider, request: { _ in snapshot })
        }
        model.start()
        defer { model.connection(.local)?.disconnect() }
        let connected = await ModelFixtures.wait { model.state.serverIdentity(.local) != nil }
        XCTAssertTrue(connected)
        let project = try XCTUnwrap(model.addProject(try ModelFixtures.folder("Agent Workspace")))
        let synced = await ModelFixtures.wait { model.state.projectIntents(.local).isEmpty }
        XCTAssertTrue(synced)
        model.selectProject(project)
        let controller = MainWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer {
            // AppKit can autorelease the window after the local model is gone.
            // Detach its workspace while the model's unowned references are valid.
            window.orderOut(nil)
            window.contentView = nil
        }
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 850), display: false)
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(150))
        try render(window.contentView, to: output + "/agent-empty-project.png")

        let claude = try XCTUnwrap(model.newAgent(in: project, provider: .claude))
        model.newTerminal(in: project)
        let codex = try XCTUnwrap(model.newAgent(in: project, provider: .codex))
        let loaded = await ModelFixtures.wait {
            (model.panes.controller(for: claude) as? AgentPaneController)?.snapshot != nil &&
            (model.panes.controller(for: codex) as? AgentPaneController)?.snapshot != nil
        }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.activeTab?.panes.count, 3)
        XCTAssertEqual(model.activeTab?.panes.filter { $0.content.isTerminal }.count, 1)
        try await Task.sleep(for: .milliseconds(150))
        try render(window.contentView, to: output + "/agent-workspace.png")
    }

    private func render(_ view: NSView?, to path: String) throws {
        let view = try XCTUnwrap(view)
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }
}
