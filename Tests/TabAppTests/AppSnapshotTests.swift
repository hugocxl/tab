import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

/// Renders the main window offscreen to PNGs for comparing with
/// `design/reference`. Runs only with `TAB_SNAPSHOT_DIR` set.
@MainActor
final class AppSnapshotTests: XCTestCase {
    func testRenderMainWindowAndPalette() async throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render snapshots")
        }
        _ = NSApplication.shared
        let dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
        let model = AppModel(dirs: dirs, theme: theme) { id, _ in id.isLocal ? FakeConnector(server: server) : nil }
        model.start()
        _ = await ModelFixtures.wait { model.state.serverIdentity(.local) != nil }
        let codesh = try XCTUnwrap(model.addProject(try ModelFixtures.folder("codesh")))
        _ = await ModelFixtures.wait { model.state.projectIntents(.local).isEmpty }
        let worktree = try ModelFixtures.folder("cmd-palette")
        try Data("gitdir: /tmp/x".utf8).write(to: URL(fileURLWithPath: worktree + "/.git"))
        var page = server.catalogPage
        page.projects.append(ProjectDescriptor(directory: ServerPath(worktree), name: "cmd-palette", kind: .worktree, parentId: codesh))
        page.revision += 1
        model.applyCatalog(.local, page)
        model.git[codesh] = GitInfo(summary: GitSummary(branch: "main"), pullRequest: 616)
        model.newHomeTerminal()
        model.selectProject(codesh)
        model.newTerminal(in: codesh)
        model.split(.right)
        _ = await ModelFixtures.wait { (model.activeTab?.panes.count ?? 0) == 2 }
        let controller = MainWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        controller.showWindow(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        try render(window.contentView, to: output + "/window.png")
        controller.openPalette(.root)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(window.contentView?.subviews.contains { $0 is PaletteRootView } == true)
        try render(window.contentView, to: output + "/palette.png")
        controller.openPalette(.themes)
        try? await Task.sleep(nanoseconds: 200_000_000)
        try render(window.contentView, to: output + "/themes.png")
        model.connection(.local)?.disconnect()
    }

    private func render(_ view: NSView?, to path: String) throws {
        let view = try XCTUnwrap(view)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
