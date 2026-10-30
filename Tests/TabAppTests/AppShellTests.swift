import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class AppKeyDispatchTests: XCTestCase {
    private let keymap = Keymap()

    private func resolve(_ key: String, paneTakes: Bool = false, editing: Bool = false,
                         keymap: Keymap? = nil) -> KeyResolution {
        KeyDispatcher.resolve(chord: try? KeyChord(key), paneTakes: paneTakes, editingText: editing,
                              keymap: keymap ?? self.keymap)
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

    func testRebindings() throws {
        let rebound = try Keymap.fromOverrides(["split_right": "cmd-alt-d"])
        XCTAssertEqual(resolve("cmd-alt-d", keymap: rebound), .action(.splitRight))
        XCTAssertEqual(resolve("cmd-d", keymap: rebound), .pass, "the old key no longer splits")
    }

    func testMenuKeyEquivalents() throws {
        let item = NSMenuItem()
        MenuBarBuilder.apply(try KeyChord("cmd-shift-enter"), to: item)
        XCTAssertEqual(item.keyEquivalent, "\r")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNotNil(MenuBarBuilder.keyEquivalent("left"))
        XCTAssertNil(MenuBarBuilder.keyEquivalent("unknown"))
    }

    func testMenuTreeMatchesCodeshWithNativeAboutAndHelp() throws {
        _ = NSApplication.shared
        let model = AppModel(dirs: try ModelFixtures.profile())
        let menu = MenuBarBuilder.build(keymap: Keymap(), actions: Actions(model: model),
                                        available: Set(ShortcutFeature.allCases))
        let app = Release.appName
        XCTAssertEqual(menu.items.map(\.title), [app, "Edit", "File", "View", "Window", "Help"])
        func titles(_ name: String) -> [String] {
            menu.items.first { $0.title == name }?.submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        }
        XCTAssertEqual(titles(app), [
            "About \(app)", "-", "Settings…", "Check for Updates…", "Install Command Line Tool…", "-",
            "Services", "-", "Hide \(app)", "Hide Others", "Show All", "-", "Quit \(app)", "End All Sessions and Quit",
        ])
        XCTAssertEqual(titles("Edit"), [
            "Cut", "Copy", "Paste", "Select All", "-", "Find…", "Find Next", "Find Previous", "-",
            "Previous Prompt", "Next Prompt", "Select Command Output",
        ])
        XCTAssertEqual(titles("File"), [
            "New Terminal", "New Agent Tab",
            "New Browser Pane", "New Home Terminal", "New Terminal in Project…", "New Worktree…",
            "Switch Worktree…", "Open Project…", "-", "Close Tab",
        ])
        XCTAssertEqual(titles("View"), [
            "Command Palette…", "-", "Toggle Voice Recording", "-", "Toggle Sidebar",
            "Toggle Files", "Toggle Source Control", "Go to File…", "Find in Files…",
            "Toggle Full Screen", "-", "Theme Picker", "-", "Increase Font Size", "Decrease Font Size",
        ])
        XCTAssertEqual(titles("Window"), [
            "Minimize", "Zoom", "-", "Split Right", "Split Down", "Focus Pane Left", "Focus Pane Right", "Focus Pane Up",
            "Focus Pane Down", "Toggle Pane Zoom", "Equalize Splits", "Close Pane", "Close Tab", "-", "Next Tab",
            "Previous Tab", "-", "Previous Project", "Next Project", "-",
        ] + (1...9).map { "Tab \($0)" } + ["-"] + (1...9).map { "Project \($0)" })
        XCTAssertEqual(titles("Help"), ["\(app) Help"])
        let limited = MenuBarBuilder.build(keymap: Keymap(), actions: Actions(model: model), available: [])
        let limitedTitles = limited.items.flatMap { $0.submenu?.items.map(\.title) ?? [] }
        for unavailable in ["Check for Updates…", "Install Command Line Tool…", "Toggle Voice Recording"] {
            XCTAssertFalse(limitedTitles.contains(unavailable))
        }
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
        let presenter = ModelTestPresenter()
        model.presenter = presenter
        let folder = try ModelFixtures.folder("opened")

        let reply = await handler.handle(.open(path: folder))
        XCTAssertEqual(reply, .ok(.bool(true)))
        let project = try XCTUnwrap(model.state.projects.first { $0.directory.rawValue == folder })
        XCTAssertEqual(model.currentProject.id, project.id)
        XCTAssertEqual(presenter.broughtToFront, 1)

        let workspace = try XCTUnwrap(model.createWorkspace("CLI"))
        model.selectWorkspace(workspace)
        model.selectProject(model.state.home.id)
        _ = await handler.handle(.open(path: folder + "/"))
        XCTAssertEqual(model.state.projects.filter { $0.directory.rawValue == folder }.count, 1, "opening again selects it")
        XCTAssertEqual(model.currentProject.id, project.id)
        XCTAssertEqual(model.state.window.workspace, workspace)
        XCTAssertTrue(model.state.workspace(workspace)?.projects.contains(project.id) == true)
        let alias = URL(fileURLWithPath: folder + "-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: folder))
        let aliased = await handler.handle(.open(path: alias.path))
        XCTAssertEqual(aliased, .ok(.bool(true)))
        XCTAssertEqual(model.currentProject.id, project.id)
        XCTAssertEqual(model.state.projects.filter { !$0.home }.count, 1)

        let file = folder + "/file.txt"
        try Data().write(to: URL(fileURLWithPath: file))
        if case .ok = await handler.handle(.open(path: file)) { XCTFail("a file is not a project") }
        let empty = await handler.handle(.open(path: ""))
        XCTAssertEqual(empty, .ok(.bool(true)), "an empty path only brings the window")
        XCTAssertEqual(presenter.broughtToFront, 5)
        let unknown = await handler.handle(.unknown("future"))
        XCTAssertEqual(unknown, .failed("unknown command future"))
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
        let instance = try XCTUnwrap(SingleInstance.claim(folder: nil, dirs: dirs))
        defer { withExtendedLifetime(instance) {} }
        let handler = AppSocketHandler(model: model)
        try handler.listen()
        defer { handler.close() }
        let folder = try ModelFixtures.folder("handed")
        let handed = try await Task.detached { try SingleInstance.claim(folder: folder, dirs: dirs) == nil }.value
        XCTAssertTrue(handed)
        let added = await ModelFixtures.wait { model.state.projects.contains { $0.directory.rawValue == folder } }
        XCTAssertTrue(added)
        model.connection(.local)?.disconnect()
    }
}
