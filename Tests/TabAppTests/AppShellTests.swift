import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class AppKeyDispatchTests: XCTestCase {
    private let keymap = Keymap()

    private func resolve(_ key: String, paneTakes: Bool = false, editing: Bool = false,
                         commands: [CustomCommand] = [], keymap: Keymap? = nil) -> KeyResolution {
        KeyDispatcher.resolve(chord: try? KeyChord(key), paneTakes: paneTakes, editingText: editing,
                              keymap: keymap ?? self.keymap, commands: commands)
    }

    /// A focused terminal's own bindings win over app shortcuts; then the
    /// keymap; then normal handling.
    func testTerminalBindingsComeBeforeTheKeymap() {
        XCTAssertEqual(resolve("cmd-d", paneTakes: true), .pane)
        XCTAssertEqual(resolve("cmd-d"), .action(.splitRight))
        XCTAssertEqual(resolve("ctrl-tab"), .action(.nextTab), "secondary default keys run too")
        XCTAssertEqual(resolve("ctrl-3"), .action(.selectProject3))
        XCTAssertEqual(resolve("a"), .pass)
        XCTAssertEqual(resolve("cmd-q"), .pass, "the menu bar's standard items keep their keys")
    }

    func testTextFieldsKeepEditingKeys() {
        XCTAssertEqual(resolve("cmd-c", editing: true), .pass)
        XCTAssertEqual(resolve("cmd-left", editing: true), .pass)
        XCTAssertEqual(resolve("cmd-shift-p", editing: true), .action(.toggleCommandPalette))
    }

    func testRebindingsAndCustomCommands() throws {
        let command = CustomCommand(id: "deploy", name: "Deploy", command: "make deploy")
        let rebound = try Keymap.fromOverrides(["split_right": "cmd-alt-d", "command.deploy": "cmd-ctrl-d"])
        XCTAssertEqual(resolve("cmd-alt-d", keymap: rebound), .action(.splitRight))
        XCTAssertEqual(resolve("cmd-d", keymap: rebound), .pass, "the old key no longer splits")
        XCTAssertEqual(resolve("cmd-ctrl-d", commands: [command], keymap: rebound), .command("deploy"))
    }

    func testMenuKeyEquivalents() throws {
        let item = NSMenuItem()
        MenuBarBuilder.apply(try KeyChord("cmd-shift-enter"), to: item)
        XCTAssertEqual(item.keyEquivalent, "\r")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNotNil(MenuBarBuilder.keyEquivalent("left"))
        XCTAssertNil(MenuBarBuilder.keyEquivalent("unknown"))
    }

    func testNavigationHistoryGoesBackAndForwardOverLivePlaces() {
        var history = NavigationHistory()
        let (a, b, c) = (ProjectId(), ProjectId(), ProjectId())
        for project in [a, b, c] { history.record(.init(project: project, tab: nil)) }
        let back = history.target(forward: false) { $0.project != b }
        XCTAssertEqual(back?.1.project, a, "a removed project is skipped")
        history.commit(back!.0)
        XCTAssertEqual(history.target(forward: true) { _ in true }?.1.project, b)
        history.record(.init(project: c, tab: nil))
        XCTAssertNil(history.target(forward: true) { _ in true }, "going somewhere new drops what was forward")
    }
}

@MainActor
final class AppSocketOpenTests: XCTestCase {
    func testOpenAddsOrSelectsTheFolderAndRefusesFiles() async throws {
        let dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let model = ModelFixtures.model(dirs, server: server)
        model.start()
        _ = await ModelFixtures.wait { model.state.serverIdentity(.local) != nil }
        let handler = AppSocketHandler(model: model)
        let folder = try ModelFixtures.folder("opened")

        let reply = await handler.handle(.open(path: folder))
        XCTAssertEqual(reply, .ok(.bool(true)))
        let project = try XCTUnwrap(model.state.projects.first { $0.directory.rawValue == folder })
        XCTAssertEqual(model.currentProject.id, project.id)

        model.selectProject(model.state.home.id)
        _ = await handler.handle(.open(path: folder + "/"))
        XCTAssertEqual(model.state.projects.filter { $0.directory.rawValue == folder }.count, 1, "opening again selects it")
        XCTAssertEqual(model.currentProject.id, project.id)

        let file = folder + "/file.txt"
        try Data().write(to: URL(fileURLWithPath: file))
        if case .ok = await handler.handle(.open(path: file)) { XCTFail("a file is not a project") }
        let empty = await handler.handle(.open(path: ""))
        XCTAssertEqual(empty, .ok(.bool(true)), "an empty path only brings the window")
        if case .ok = await handler.handle(.unknown("future")) { XCTFail("unknown requests fail") }
        model.connection(.local)?.disconnect()
    }

    func testSecondLaunchHandsItsFolderToTheRunningApp() async throws {
        let dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let model = ModelFixtures.model(dirs, server: server)
        model.start()
        _ = await ModelFixtures.wait { model.state.serverIdentity(.local) != nil }
        XCTAssertFalse(SingleInstance.handOver(folder: nil, dirs: dirs), "no app answers yet")
        let handler = AppSocketHandler(model: model)
        try handler.listen()
        defer { handler.close() }
        let folder = try ModelFixtures.folder("handed")
        let handed = await Task.detached { SingleInstance.handOver(folder: folder, dirs: dirs) }.value
        XCTAssertTrue(handed)
        let added = await ModelFixtures.wait { model.state.projects.contains { $0.directory.rawValue == folder } }
        XCTAssertTrue(added)
        model.connection(.local)?.disconnect()
    }
}
