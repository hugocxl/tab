import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// Moving between tabs reuses what is on screen: no sidebar card or pane card
/// is remade, a pane's content stays in the window, a terminal redraws only
/// what changed, and a tab readied while hidden shows its screen at once.
@MainActor
final class TabSwitchingTests: XCTestCase {
    private struct Window {
        let model: AppModel
        let server: ModelFakeServer
        let workspace: WorkspaceView
        let window: NSWindow
        let tabs: [TabId]
    }

    private func spin(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    private func settle(_ window: NSWindow) {
        while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func open(tabs count: Int) throws -> Window {
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(
            server: identity, home: home.id, revision: 1, projects: [home]))
        server.screen = { _, size in
            let rows = (0..<Int(size.rows)).map { Row(index: UInt16($0), runs: [TerminalFixtures.run("row \($0)")]) }
            return AttachSnapshot(channel: ChannelId(1), size: size, rows: rows, cursor: Cursor(), directory: "/tmp")
        }
        let model = ModelFixtures.model(try ModelFixtures.profile(), server: server)
        model.start()
        // The server's first tabs arrive before the test opens its own, and
        // the server keeps them, so no later read of its tabs drops them.
        XCTAssertTrue(spin { model.state.serverIdentity(.local) != nil && model.state.tabsRevision(.local) != nil })
        let homeId = try XCTUnwrap(model.state.serverHome(.local)?.id)
        var tabs: [TabId] = []
        model.edit { state in
            for _ in 0..<count { tabs.append(try state.openTerminalTab(homeId)) }
            for pane in state.project(homeId)?.tabs.flatMap(\.panes) ?? [] { try state.setPaneSession(pane.id, SessionId()) }
        }
        server.keepTabs(of: model.state)
        let workspace = WorkspaceView(model: model, sidebar: SidebarViewController(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = workspace
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            model.connection(.local)?.disconnect()
        }
        settle(window)
        return Window(model: model, server: server, workspace: workspace, window: window, tabs: tabs)
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    func testSelectingAnotherTabRemakesNoSidebarCard() throws {
        let shown = try open(tabs: 6)
        // Each terminal's first attachment names its folder on its card.
        for tab in shown.tabs {
            shown.model.selectTab(tab)
            settle(shown.window)
            XCTAssertTrue(spin { (shown.model.panes.controller(for: shown.model.activeTab?.panes.first?.id ?? PaneId()) as? TerminalPane)?.session?.state == .live })
        }
        _ = spin(0.2) { false }
        settle(shown.window)
        let before = Set(views(SidebarCardView.self, in: shown.workspace).map(ObjectIdentifier.init))
        XCTAssertEqual(before.count, 6)

        for tab in shown.tabs.reversed() {
            shown.model.selectTab(tab)
            settle(shown.window)
        }

        let cards = views(SidebarCardView.self, in: shown.workspace)
        XCTAssertEqual(Set(cards.map(ObjectIdentifier.init)), before)
        XCTAssertEqual(cards.filter(\.data.selected).count, 1)
    }

    func testSwitchingBackKeepsTheTabsCardsAndContentInTheWindow() throws {
        let shown = try open(tabs: 3)
        shown.model.selectTab(shown.tabs[0])
        settle(shown.window)
        let pane = try XCTUnwrap(shown.model.activeTab?.panes.first?.id)
        let card = try XCTUnwrap(views(PaneCardView.self, in: shown.workspace).first { $0.pane == pane })
        let content = try XCTUnwrap(card.controller?.view)

        shown.model.selectTab(shown.tabs[1])
        settle(shown.window)
        XCTAssertTrue(card.isHiddenOrHasHiddenAncestor)
        XCTAssertNotNil(content.window, "a hidden tab's panes stay in the window")
        XCTAssertEqual(shown.workspace.splits.surfaceFrames.count, 1, "hidden cards cut no glass")

        shown.model.selectTab(shown.tabs[0])
        settle(shown.window)
        XCTAssertTrue(views(PaneCardView.self, in: shown.workspace).contains { $0 === card })
        XCTAssertFalse(card.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(content.superview?.isDescendant(of: card) ?? false)
    }

    func testClosingATabForgetsItsCards() throws {
        let shown = try open(tabs: 3)
        for tab in shown.tabs { shown.model.selectTab(tab); settle(shown.window) }
        let closed = try XCTUnwrap(shown.model.state.serverHome(.local)?.tabs.first { $0.id == shown.tabs[0] })
        let pane = try XCTUnwrap(closed.panes.first?.id)
        XCTAssertTrue(views(PaneCardView.self, in: shown.workspace).contains { $0.pane == pane })

        shown.model.edit { try $0.closeTab(XCTUnwrap($0.serverHome(.local)?.id), closed.id) }
        settle(shown.window)

        XCTAssertFalse(views(PaneCardView.self, in: shown.workspace).contains { $0.pane == pane })
    }

    func testAReadiedTabHasItsScreenBeforeItShows() throws {
        // The last tab opened shows first; the middle one never has.
        let shown = try open(tabs: 3)
        shown.model.selectTab(shown.tabs[0])
        settle(shown.window)
        let hidden = try XCTUnwrap(shown.model.state.serverHome(.local)?.tabs.first { $0.id == shown.tabs[1] })
        let pane = try XCTUnwrap(hidden.panes.first?.id)

        XCTAssertTrue(shown.workspace.splits.prepare(hidden.id))
        XCTAssertFalse(shown.workspace.splits.prepare(hidden.id), "a tab is readied once")
        let terminal = { shown.model.panes.controller(for: pane) as? TerminalPane }
        XCTAssertTrue(spin { terminal()?.session?.view.grid != nil })
        let session = try XCTUnwrap(terminal()?.session)
        XCTAssertEqual(session.state, .detached, "readying fetches the screen and lets the session go")
        XCTAssertEqual(session.view.grid?.size, session.view.viewport, "fetched at the size it will show at")
        XCTAssertEqual(shown.model.activeTab?.id, shown.tabs[0])

        shown.model.selectTab(hidden.id)
        settle(shown.window)
        XCTAssertTrue(spin { session.state == .live })
        XCTAssertTrue(terminal()?.session === session)
    }

    func testARedrawCoversOnlyTheRowsThatChanged() {
        let rows = (0..<4).map { [TerminalFixtures.run("row \($0)")] }
        let grid = TerminalFixtures.grid(rows, cols: 10)
        XCTAssertEqual(TerminalView.changedRows(from: grid, to: grid), IndexSet())

        var changed = rows
        changed[2] = [TerminalFixtures.run("other")]
        XCTAssertEqual(TerminalView.changedRows(from: grid, to: TerminalFixtures.grid(changed, cols: 10)), IndexSet(integer: 2))

        let moved = TerminalFixtures.grid(rows, cols: 10, cursor: Cursor(row: 3, col: 1))
        XCTAssertEqual(TerminalView.changedRows(from: grid, to: moved), IndexSet([0, 3]))

        XCTAssertNil(TerminalView.changedRows(from: grid, to: TerminalFixtures.grid(rows, cols: 12)))
    }

    func testSwitchingProjectsWritesTheRecentOrderOnceAfterwards() throws {
        let dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(
            server: identity, home: home.id, revision: 1, projects: [home]))
        let model = ModelFixtures.model(dirs, server: server)
        model.start()
        defer { model.connection(.local)?.disconnect() }
        XCTAssertTrue(spin { model.state.serverIdentity(.local) != nil })
        let first = try XCTUnwrap(model.addProject(try ModelFixtures.folder("first")))
        let second = try XCTUnwrap(model.addProject(try ModelFixtures.folder("second")))
        func saved() throws -> [ProjectId] { try Settings.load(dirs.settings).appearance.projectRecent }
        let before = try saved()

        model.selectProject(first)
        model.selectProject(second)

        XCTAssertEqual(model.appearance.projectRecent.prefix(2), [second, first])
        XCTAssertEqual(try saved(), before, "switching writes nothing at once")
        // Settings saved elsewhere meanwhile keep the order not yet written.
        var edited = model.settings
        edited.appearance.projectRecent = before
        model.apply(settings: edited)
        XCTAssertEqual(model.appearance.projectRecent.prefix(2), [second, first])
        model.saveNow()
        XCTAssertEqual(try saved().prefix(2), [second, first])
    }
}
