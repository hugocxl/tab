import XCTest
@testable import TabCore

final class AppStateTests: XCTestCase {
    private var currentDirectory: String { FileManager.default.currentDirectoryPath }

    private func active(_ state: AppState) throws -> PaneId { try XCTUnwrap(state.activePane) }

    // MARK: Splits and focus

    func testNestedSplitsFocusZoomAndCollapseSurviveRoundTrip() throws {
        var state = try AppState.bootstrap()
        let tab = try state.openTerminalTab(state.home.id)
        let left = state.home.tabs[0].panes[0].id
        let right = try state.splitPane(left, edge: .right)
        let bottom = try state.splitPane(right, edge: .down)
        XCTAssertEqual(state.home.tabs[0].layout.leaves, [left, right, bottom])
        XCTAssertEqual(state.neighbor(of: left, .right), right)
        XCTAssertEqual(state.neighbor(of: right, .down), bottom)
        XCTAssertEqual(state.neighbor(of: bottom, .up), right)
        XCTAssertEqual(state.neighbor(of: bottom, .left), left)
        XCTAssertNil(state.neighbor(of: left, .left))
        try state.setRatio(tab, path: [], ratio: 0.6)
        try state.setRatio(tab, path: [.second], ratio: 0.3)
        try state.focusPane(right)
        try state.setPaneTitle(right, "editor")
        XCTAssertEqual(state.home.tabs[0].title(active: state.activePane), "editor")
        try state.toggleZoom(right)
        XCTAssertEqual(state.home.tabs[0].visiblePanes, [right])
        XCTAssertEqual(try roundTrip(state), state)
        try state.focusPane(bottom)
        XCTAssertEqual(state.home.tabs[0].visiblePanes, [bottom])
        try state.toggleZoom(bottom)
        XCTAssertEqual(state.home.tabs[0].visiblePanes, [left, right, bottom])
        try state.closePane(right)
        XCTAssertEqual(state.home.tabs[0].layout.leaves, [left, bottom])
        for (_, rect) in state.home.tabs[0].layout.rects { assertClose(rect.width, 0.5) }
        XCTAssertEqual(state.activePane, bottom)
        try state.toggleZoom(bottom)
        try state.closePane(bottom)
        XCTAssertEqual(state.home.tabs[0].layout, .leaf(left))
        XCTAssertEqual(state.activePane, left)
        XCTAssertNil(state.home.tabs[0].zoomed)
        try state.closePane(left)
        XCTAssertTrue(state.home.tabs.isEmpty)
        XCTAssertTrue(state.window.selectedTab.isEmpty)
    }

    func testMissingAndMalformedLayoutsAreRejected() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let first = state.home.tabs[0].panes[0].id
        try state.splitPane(first, edge: .right)
        let valid = try jsonObject(state)
        func mutateTab(_ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
            var object = valid
            var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
            var tabs = try XCTUnwrap(projects[0]["tabs"] as? [[String: Any]])
            change(&tabs[0])
            projects[0]["tabs"] = tabs
            object["projects"] = projects
            return object
        }
        let stray = PaneId().description
        let variants: [(inout [String: Any]) -> Void] = [
            { $0["layout"] = nil },
            { $0["zoomed"] = stray },
            { $0["panes"] = [] },
            { $0["layout"] = ["leaf": stray] },
            { tab in
                var layout = tab["layout"] as? [String: Any] ?? [:]
                var split = layout["split"] as? [String: Any] ?? [:]
                split["ratio"] = 1.5
                layout["split"] = split
                tab["layout"] = layout
            },
            { $0["color"] = "blue" },
            { tab in
                var panes = tab["panes"] as? [[String: Any]] ?? []
                panes[0]["content"] = ["type": "unknown"]
                tab["panes"] = panes
            },
        ]
        for (index, variant) in variants.enumerated() {
            XCTAssertThrowsError(try decodeState(mutateTab(variant)), "variant \(index)")
        }
        XCTAssertEqual(try decodeState(valid), state)
    }

    func testWindowOwnsFocusAndClosingChoosesNeighborsWithoutStealingFocus() throws {
        var state = try AppState.bootstrap()
        let home = state.home.id
        let container = try state.openTerminalTab(home)
        let first = try active(state)
        let middle = try state.splitPane(first, edge: .right)
        let last = try state.splitPane(middle, edge: .right)
        try state.closePane(last)
        XCTAssertEqual(state.activePane, middle)
        let added = try state.splitPane(middle, edge: .right)
        let right = try state.splitPane(added, edge: .right)
        try state.focusPane(middle)
        try state.closePane(first)
        XCTAssertEqual(state.activePane, middle)
        let other = try state.addProject(server: .local, directory: currentDirectory)
        try state.openTerminalTab(other)
        let otherPane = state.activePane
        try state.closePane(right)
        XCTAssertEqual(state.activePane, otherPane)
        try state.closeTab(home, container)
        XCTAssertEqual(state.activePane, otherPane)
        XCTAssertTrue(state.home.tabs.isEmpty)
    }

    func testPaneMovesNeverChangePaneIdentityOrContent() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let project = try state.addProject(server: .local, directory: currentDirectory)
        try state.openTerminalTab(project)
        try state.selectTab(state.home.id, state.home.tabs[0].id)
        let first = try active(state)
        let second = try state.splitPane(first, edge: .right)
        let third = try state.splitPane(first, edge: .down)
        let before = state.home.tabs[0].panes
        for edge in [Direction.left, .right, .up, .down, nil] {
            try state.movePane(third, onto: second, edge: edge)
            XCTAssertEqual(state.home.tabs[0].panes, before)
            XCTAssertEqual(state.activePane, third)
            XCTAssertEqual(state.home.tabs[0].layout.leaves.count, 3)
            XCTAssertEqual(try roundTrip(state), state)
        }
        let unchanged = state
        XCTAssertThrowsError(try state.movePane(first, onto: first, edge: nil))
        XCTAssertThrowsError(try state.movePane(first, onto: state.projects[1].tabs[0].panes[0].id, edge: .left))
        XCTAssertEqual(state, unchanged)
    }

    func testStateDockingIsAtomicAndPreservesRecords() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let a = try active(state)
        let b = try state.splitPane(a, edge: .right)
        let c = try state.splitPane(b, edge: .down)
        let records = state.home.tabs[0].panes
        try state.dockPane(a, beside: b, edge: .up, level: 1)
        XCTAssertEqual(state.home.tabs[0].layout.leaves, [a, b, c])
        XCTAssertEqual(state.activePane, a)
        XCTAssertEqual(state.home.tabs[0].panes, records)
        XCTAssertEqual(try roundTrip(state), state)
        let before = state
        XCTAssertThrowsError(try state.dockPane(a, beside: a, edge: .left, level: 0))
        XCTAssertThrowsError(try state.dockPane(a, beside: b, edge: .left, level: 9))
        XCTAssertEqual(state, before)
    }

    func testRestartingATerminalKeepsItsPlaceTitleZoomAndFocus() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let first = try active(state)
        let second = try state.splitPane(first, edge: .right)
        try state.setPaneTitle(second, "Build")
        try state.setPaneProxy(second, true)
        try state.toggleZoom(second)
        let before = state.home.tabs[0].layout.rects.map(\.1)
        let restarted = try state.restartTerminal(second)
        let tab = state.home.tabs[0]
        XCTAssertNotEqual(restarted, second)
        XCTAssertEqual(tab.panes[1].id, restarted)
        XCTAssertEqual(tab.panes[1].title, "Build")
        XCTAssertFalse(tab.panes[1].proxy)
        XCTAssertEqual(tab.panes[1].content, .terminal(session: nil))
        XCTAssertEqual(tab.layout.leaves, [first, restarted])
        XCTAssertEqual(tab.layout.rects.map(\.1), before)
        XCTAssertEqual(tab.zoomed, restarted)
        XCTAssertEqual(state.activePane, restarted)
    }

    func testOnlyProxiedPanesSaveTheProxyFlag() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let pane = try active(state)
        let saved = try AppStateStore.encode(state)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("\"proxy\""))
        try state.setPaneProxy(pane, true)
        XCTAssertTrue(try roundTrip(state).home.tabs[0].panes[0].proxy)
        XCTAssertFalse(try AppStateStore.decode(saved).home.tabs[0].panes[0].proxy)
    }

    // MARK: Single tab per project

    func testTerminalAndAdjacentCreationSplitTheFocusedLeaf() throws {
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: currentDirectory)
        try state.selectProject(project)
        let tab = try state.openTerminalTab(project)
        let first = try active(state)
        XCTAssertEqual(try state.openTerminalTab(project), tab)
        let second = try active(state)
        XCTAssertNotEqual(first, second)
        try state.focusPane(first)
        var expected = [first]
        for _ in 0..<2 {
            XCTAssertEqual(try state.openTerminalTab(project, adjacentTo: tab), tab)
            expected.append(try active(state))
        }
        expected.append(second)
        let container = try XCTUnwrap(state.project(project)).tabs
        XCTAssertEqual(container.count, 1)
        XCTAssertEqual(container[0].layout.leaves, expected)
        for ((pane, rect), (expectedPane, x)) in zip(container[0].layout.rects, zip(expected, [0, 0.25, 0.5, 0.75])) {
            XCTAssertEqual(pane, expectedPane)
            assertClose(rect.x, x)
            assertClose(rect.width, 0.25)
        }
    }

    func testBrowserBackgroundOpensPreserveFocusAndForegroundOpensFocusTheNewPane() throws {
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: currentDirectory)
        try state.selectProject(project)
        let tab = try state.openTerminalTab(project)
        let first = try active(state)
        let (backgroundTab, background) = try state.openBrowser(project, BrowserPane(), select: false)
        XCTAssertEqual(backgroundTab, tab)
        XCTAssertEqual(try active(state), first)
        let (foregroundTab, foreground) = try state.openBrowser(project, BrowserPane(), select: true)
        XCTAssertEqual(foregroundTab, tab)
        XCTAssertEqual(try active(state), foreground)
        XCTAssertNotEqual(background, foreground)
        let other = try state.addProject(server: .local, directory: currentDirectory)
        try state.openTerminalTab(other)
        let window = state.window
        try state.openBrowser(project, BrowserPane(), select: false)
        XCTAssertEqual(state.window, window)
        XCTAssertEqual(state.project(project)?.tabs.count, 1)
    }

    func testLoadMergesSubtreesPreservingSessionsOrderAndSelectedPane() throws {
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: currentDirectory)
        try state.selectProject(project)
        let first = try state.openTerminalTab(project)
        let template = try XCTUnwrap(state.project(project)).tabs[0]
        func newTab() -> Tab { Tab(pane: Pane(title: "Terminal", content: .terminal(session: nil))) }
        var tabs = [template, newTab(), newTab()]
        let extra = Pane(title: "nested", content: .terminal(session: SessionId()))
        tabs[1].layout.split(tabs[1].panes[0].id, new: extra.id, edge: .down)
        tabs[1].panes.append(extra)
        let expected = tabs.flatMap(\.panes)
        let focused = tabs[2].panes[0].id
        tabs[2].zoomed = focused
        let subtrees = tabs.map(\.layout)
        var stored = try jsonObject(state)
        var projects = try XCTUnwrap(stored["projects"] as? [[String: Any]])
        projects[1]["tabs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tabs))
        stored["projects"] = projects
        var window = try XCTUnwrap(stored["window"] as? [String: Any])
        var selected = try XCTUnwrap(window["selectedTab"] as? [String: Any])
        selected[project.description] = tabs[2].id.description
        window["selectedTab"] = selected
        window["activePane"] = focused.description
        stored["window"] = window
        let loaded = try decodeState(stored)
        let tab = try XCTUnwrap(loaded.project(project)?.tabs.first)
        XCTAssertEqual(loaded.project(project)?.tabs.count, 1)
        XCTAssertEqual(tab.id, first)
        XCTAssertEqual(tab.panes, expected)
        XCTAssertEqual(tab.layout.leaves, expected.map(\.id))
        XCTAssertEqual(tab.layout, .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .split(axis: .horizontal, ratio: 0.5, first: subtrees[0], second: subtrees[1]),
            second: subtrees[2]
        ))
        XCTAssertEqual(loaded.window.selectedTab[project], first)
        XCTAssertEqual(loaded.activePane, focused)
        XCTAssertNil(tab.zoomed)
        var normalized = try XCTUnwrap(loaded.project(project))
        AppState.normalize(&normalized)
        XCTAssertEqual(normalized, loaded.project(project))
    }

    func testClosingLastPaneLeavesAnEmptyProjectAndANewTerminalRecreatesIt() throws {
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: currentDirectory)
        try state.selectProject(project)
        let old = try state.openTerminalTab(project)
        let first = try active(state)
        try state.openTerminalTab(project)
        try state.closePane(first)
        try state.closePane(active(state))
        XCTAssertEqual(state.project(project)?.tabs.isEmpty, true)
        XCTAssertNil(state.activePane)
        let new = try state.openTerminalTab(project)
        XCTAssertNotEqual(old, new)
        XCTAssertEqual(state.project(project)?.tabs.first?.panes.count, 1)
    }

    func testServersPaneIsReusedAndFocusedWithoutReplacingTheTerminal() throws {
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: currentDirectory)
        try state.selectProject(project)
        let tab = try state.openTerminalTab(project)
        let terminal = try active(state)
        XCTAssertEqual(try state.showServersTab(project, title: "Servers"), tab)
        let servers = try active(state)
        XCTAssertTrue(state.isServersPane(servers))
        try state.focusPane(terminal)
        XCTAssertEqual(try state.showServersTab(project, title: "Servers"), tab)
        XCTAssertEqual(try active(state), servers)
        XCTAssertEqual(state.project(project)?.tabs.first?.panes.count, 2)
    }

    func testEditorAndDiffPanesReuseAnExistingPane() throws {
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: currentDirectory)
        try state.openTerminalTab(project)
        let editor = try state.openEditorPane(project, path: "./Sources/main.swift")
        XCTAssertEqual(state.pane(editor)?.title, "main.swift")
        let diff = try state.openDiffPane(project, path: "Sources/main.swift", staged: true)
        XCTAssertEqual(state.pane(diff)?.title, "main.swift (staged)")
        try state.focusPane(state.project(project)!.tabs[0].panes[0].id)
        XCTAssertEqual(try state.openEditorPane(project, path: "Sources/main.swift/"), editor)
        XCTAssertEqual(try active(state), editor)
        XCTAssertEqual(state.project(project)?.tabs.first?.panes.count, 3)
        XCTAssertThrowsError(try state.openEditorPane(project, path: "../outside"))
        XCTAssertThrowsError(try state.openEditorPane(project, path: "/etc/passwd"))
    }

    func testWorktreeProjectsObeyTheSamePolicy() throws {
        var state = try AppState.bootstrap()
        let parent = try state.addProject(server: .local, directory: currentDirectory)
        let child = try state.addProject(server: .local, directory: currentDirectory + "/Sources")
        var stored = try jsonObject(state)
        var projects = try XCTUnwrap(stored["projects"] as? [[String: Any]])
        projects[2]["parentId"] = parent.description
        stored["projects"] = projects
        state = try decodeState(stored)
        let tab = try state.openTerminalTab(child)
        XCTAssertEqual(try state.openTerminalTab(child), tab)
        XCTAssertEqual(state.project(child)?.parentId, parent)
        XCTAssertEqual(state.project(child)?.tabs.count, 1)
        XCTAssertEqual(state.project(child)?.tabs.first?.panes.count, 2)
        XCTAssertEqual(state.project(parent)?.tabs.isEmpty, true)
    }

    func testHomeTabsKeepTheirLayoutsSessionsAndSelectionThroughSaveAndLoad() throws {
        let directory = try TemporaryDirectory()
        var state = try AppState.bootstrap()
        let home = state.home.id
        let first = try state.openTerminalTab(home)
        let pane = try active(state)
        try state.setPaneSession(pane, SessionId())
        try state.splitPane(pane, edge: .down)
        let second = try state.openTerminalTab(home)
        let focused = try active(state)
        var project = state.home
        AppState.normalize(&project)
        XCTAssertEqual(project, state.home)
        let path = directory.file("state.json")
        try AppStateStore.save(state, to: path)
        let loaded = try AppStateStore.load(path)
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.home.tabs.map(\.id), [first, second])
        XCTAssertEqual(loaded.window.selectedTab[home], second)
        XCTAssertEqual(loaded.activePane, focused)
    }

    func testClosingAStandaloneTerminalReturnsToTheRecentProjectAndKeepsHome() throws {
        var state = try AppState.bootstrap()
        let home = state.home.id
        let first = try state.openTerminalTab(home)
        let project = try state.addProject(server: .local, directory: currentDirectory)
        let projectTab = try state.openTerminalTab(project)
        let recent = try active(state)
        let last = try state.openTerminalTab(home)
        try state.closePane(active(state))
        XCTAssertEqual(state.window.currentProject, project)
        XCTAssertEqual(try active(state), recent)
        XCTAssertEqual(state.window.selectedTab[project], projectTab)
        XCTAssertEqual(state.home.tabs.count, 1)
        XCTAssertFalse(state.home.tabs.contains { $0.id == last })
        try state.selectTab(home, first)
        try state.closePane(active(state))
        XCTAssertTrue(state.home.tabs.isEmpty)
        XCTAssertEqual(state.window.currentProject, project)
    }

    // MARK: Projects

    func testMissingProjectsPreserveTabsAndOnlyAllowRemoval() throws {
        let directory = try TemporaryDirectory()
        let folder = directory.file("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = try AppState.bootstrap()
        let home = state.home.id
        let project = try state.addProject(server: .local, directory: folder.path)
        let tab = try state.openTerminalTab(project)
        let session = SessionId()
        try state.setPaneSession(state.currentProject.tabs[0].panes[0].id, session)
        try FileManager.default.moveItem(at: folder, to: directory.file("moved"))
        state.refreshProjectStatuses()
        XCTAssertEqual(state.currentProject.status, .missing)
        XCTAssertThrowsError(try state.openTerminalTab(project))
        XCTAssertThrowsError(try state.selectProject(project))
        XCTAssertThrowsError(try state.selectTab(project, tab))
        XCTAssertThrowsError(try state.renameProject(project, to: "Gone"))
        XCTAssertThrowsError(try state.moveProject(project, to: 1))
        let json = try jsonObject(state)
        XCTAssertNil((json["projects"] as? [[String: Any]])?[1]["status"])
        var loaded = try decodeState(json)
        XCTAssertEqual(loaded.currentProject.status, .missing)
        XCTAssertEqual(try loaded.removeProject(project), [session])
        XCTAssertEqual(loaded.currentProject.id, home)
        XCTAssertNil(loaded.window.selectedTab[project])
    }

    func testClosingTabsInAMissingProjectKeepsSavedStateLoadable() throws {
        let directory = try TemporaryDirectory()
        let folder = directory.file("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: folder.path)
        let container = try state.openTerminalTab(project)
        XCTAssertEqual(try state.openTerminalTab(project), container)
        try FileManager.default.removeItem(at: folder)
        state.refreshProjectStatuses()
        try state.closeTab(project, container)
        XCTAssertEqual(try roundTrip(state), state)
        XCTAssertEqual(state.project(project)?.tabs.isEmpty, true)
        XCTAssertNil(state.activePane)
    }

    func testProjectsKeepHomeFirstAndQueueEditsForTheirServer() throws {
        var state = try AppState.bootstrap()
        let first = try state.addProject(server: .local, directory: currentDirectory)
        let second = try state.addProject(server: .local, directory: currentDirectory)
        XCTAssertThrowsError(try state.moveProject(first, to: 0))
        XCTAssertThrowsError(try state.moveProject(state.home.id, to: 2))
        try state.moveProject(second, to: 1)
        XCTAssertEqual(state.projects.map(\.id), [state.home.id, second, first])
        try state.renameProject(first, to: "  Renamed  ")
        XCTAssertEqual(state.project(first)?.name, "Renamed")
        XCTAssertThrowsError(try state.renameProject(first, to: "   "))
        XCTAssertThrowsError(try state.removeProject(state.home.id))
        XCTAssertThrowsError(try state.addProject(server: .local, directory: "relative"))
        XCTAssertThrowsError(try state.addProject(server: ServerId(), directory: "/srv/app"))
        let intents = state.projectIntents(.local)
        XCTAssertEqual(intents.count, 3)
        XCTAssertTrue(state.projectCreationPending(first))
        XCTAssertThrowsError(try state.completeProjectIntent(.local, intents[1].operation))
        try state.completeProjectIntent(.local, intents[0].operation)
        XCTAssertEqual(state.projectIntents(.local).count, 2)
    }

    // MARK: Servers and catalogs

    private func remoteCatalog(home: ProjectId, identity: ServerId, projects: [(ProjectId, String)]) -> CatalogPage {
        CatalogPage(
            server: identity,
            home: home,
            revision: 1,
            projects: [ProjectDescriptor(id: home, home: true, directory: "/home/dev", name: "Home")]
                + projects.map { ProjectDescriptor(id: $0.0, directory: ServerPath($0.1), name: ($0.1 as NSString).lastPathComponent) }
        )
    }

    func testCatalogsFromTwoServersKeepEachOthersProjectsAndHomes() throws {
        var state = try AppState.bootstrap()
        let local = try state.addProject(server: .local, directory: currentDirectory)
        let server = ServerId()
        let home = ProjectId()
        let api = ProjectId()
        try state.applyCatalog(server, remoteCatalog(home: home, identity: ServerId(), projects: [(api, "/srv/api")]))
        XCTAssertEqual(state.projects.map(\.id), [state.home.id, local, home, api])
        XCTAssertTrue(state.project(home)?.isRemoteHome ?? false)
        XCTAssertEqual(state.project(api)?.serverId, server)
        XCTAssertEqual(state.serverHome(server)?.id, home)
        let other = ServerId()
        let otherHome = ProjectId()
        try state.applyCatalog(other, remoteCatalog(home: otherHome, identity: ServerId(), projects: []))
        XCTAssertNotNil(state.project(api))
        try state.applyCatalog(server, remoteCatalog(home: home, identity: state.serverIdentity(server)!, projects: []))
        XCTAssertNil(state.project(api))
        XCTAssertNotNil(state.project(local))
        XCTAssertNotNil(state.project(otherHome))
    }

    func testAChangedOrDuplicateIdentityIsRefusedWithoutChangingState() throws {
        var state = try AppState.bootstrap()
        let server = ServerId()
        let identity = ServerId()
        try state.applyCatalog(server, remoteCatalog(home: ProjectId(), identity: identity, projects: []))
        let before = state
        XCTAssertThrowsError(try state.applyCatalog(server, remoteCatalog(home: ProjectId(), identity: ServerId(), projects: []))) { error in
            guard case AppError.serverChanged(server) = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try state.applyCatalog(ServerId(), remoteCatalog(home: ProjectId(), identity: identity, projects: []))) { error in
            guard case AppError.duplicateServer = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(state, before)
    }

    func testPendingEditsOverlayTheCatalogAndAHomeRemapKeepsItsTabs() throws {
        var state = try AppState.bootstrap()
        let server = ServerId()
        let identity = ServerId()
        let home = ProjectId()
        let api = ProjectId()
        try state.applyCatalog(server, remoteCatalog(home: home, identity: identity, projects: [(api, "/srv/api")]))
        try state.renameProject(api, to: "Backend")
        let tab = try state.openTerminalTab(home)
        let newHome = ProjectId()
        try state.applyCatalog(server, remoteCatalog(home: newHome, identity: identity, projects: [(api, "/srv/api")]))
        XCTAssertEqual(state.project(api)?.name, "Backend")
        XCTAssertNil(state.project(home))
        XCTAssertEqual(state.project(newHome)?.tabs.map(\.id), [tab])
        XCTAssertEqual(state.window.currentProject, newHome)
    }

    func testForgettingAServerRemovesOnlyWhatBelongsToIt() throws {
        var state = try AppState.bootstrap()
        let local = try state.addProject(server: .local, directory: currentDirectory)
        let workspace = try state.createWorkspace("Work")
        try state.setWorkspaceMember(workspace, project: local, member: true)
        let server = ServerId()
        let home = ProjectId()
        let api = ProjectId()
        try state.applyCatalog(server, remoteCatalog(home: home, identity: ServerId(), projects: [(api, "/srv/api")]))
        try state.setWorkspaceMember(workspace, project: api, member: true)
        try state.openTerminalTab(api)
        state.selectRemoteServers()
        XCTAssertTrue(state.remoteServersSelected)
        XCTAssertTrue(state.isListed(state.project(home)!))
        XCTAssertFalse(state.isListed(state.project(local)!))
        XCTAssertThrowsError(try state.forgetServer(.local))
        try state.forgetServer(server)
        XCTAssertNil(state.project(api))
        XCTAssertNil(state.project(home))
        XCTAssertEqual(state.workspace(workspace)?.projects, [local])
        XCTAssertEqual(state.window.currentProject, state.home.id)
        XCTAssertFalse(state.remoteServersSelected)
        XCTAssertNil(state.serverIdentity(server))
    }

    func testEqualSessionIdsOnTwoServersNeverMix() throws {
        var state = try AppState.bootstrap()
        let server = ServerId()
        let home = ProjectId()
        try state.applyCatalog(server, remoteCatalog(home: home, identity: ServerId(), projects: []))
        let session = SessionId()
        try state.openTerminalTab(state.home.id)
        try state.setPaneSession(try active(state), session)
        try state.openTerminalTab(home)
        let remote = try active(state)
        try state.setPaneSession(remote, session)
        XCTAssertEqual(state.sessionReferences(.local), [session])
        XCTAssertEqual(state.sessionReferences(server), [session])
        try state.closeSessionPane(remote)
        XCTAssertEqual(state.pendingDiscards(server), [session])
        XCTAssertTrue(state.pendingDiscards(.local).isEmpty)
        let plan = RestorePlan.plan(state, server: .local, sessions: [LiveSession(project: state.home.id, session: session)])
        XCTAssertEqual(plan.attach.map(\.session), [session])
    }

    func testRemoteProjectsNeverTouchThisComputersDisk() throws {
        var state = try AppState.bootstrap()
        let server = ServerId()
        let home = ProjectId()
        let api = ProjectId()
        try state.applyCatalog(server, remoteCatalog(home: home, identity: ServerId(), projects: [(api, "/definitely/not/here")]))
        XCTAssertEqual(state.project(api)?.status, .available)
        try state.setRemoteProjectStatus(api, .missing)
        XCTAssertEqual(state.project(api)?.status, .missing)
        state.refreshProjectStatuses()
        XCTAssertEqual(state.project(api)?.status, .missing)
        state.forgetRemoteStatuses(server)
        XCTAssertEqual(state.project(api)?.status, .available)
        XCTAssertThrowsError(try state.setRemoteProjectStatus(state.home.id, .missing))
    }

    func testPruningAWorktreeWaitsForItsPanesAndPendingEdits() throws {
        var state = try AppState.bootstrap()
        let server = ServerId()
        let home = ProjectId()
        let parent = ProjectId()
        let worktree = ProjectId()
        var catalog = remoteCatalog(home: home, identity: ServerId(), projects: [(parent, "/srv/app")])
        catalog.projects.append(ProjectDescriptor(id: worktree, directory: "/srv/app-feature", name: "feature", kind: .worktree, parentId: parent))
        try state.applyCatalog(server, catalog)
        try state.openTerminalTab(worktree)
        try state.pruneWorktree(worktree)
        XCTAssertNotNil(state.project(worktree))
        try state.closeTab(worktree, state.project(worktree)!.tabs[0].id)
        try state.pruneWorktree(worktree)
        XCTAssertNil(state.project(worktree))
        XCTAssertEqual(state.projectIntents(server).last?.mutation, .pruneWorktree(worktree))
    }

    // MARK: Restore, discards and store

    func testRestoreAccountsForEachLeafEvenWhenZoomed() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let first = state.home.tabs[0].panes[0].id
        let second = try state.splitPane(first, edge: .right)
        let third = try state.splitPane(second, edge: .down)
        let live = SessionId()
        let ended = SessionId()
        try state.setPaneSession(first, live)
        try state.setPaneSession(second, ended)
        try state.toggleZoom(third)
        let before = state
        let plan = RestorePlan.plan(state, server: .local, sessions: [LiveSession(project: state.home.id, session: live)])
        XCTAssertEqual(plan.attach, [PaneSession(first, live)])
        XCTAssertEqual(plan.close, [PaneSession(second, ended)])
        XCTAssertEqual(plan.create, [third])
        XCTAssertEqual(state, before)
        let allMissing = RestorePlan.plan(state, server: .local, sessions: [])
        XCTAssertEqual(allMissing.close, [PaneSession(first, live), PaneSession(second, ended)])
        XCTAssertTrue(allMissing.attach.isEmpty)
    }

    func testClosingOfflinePersistsCleanupWithoutRestoringTheTab() throws {
        let directory = try TemporaryDirectory()
        let path = directory.file("state.json")
        var state = try AppState.bootstrap()
        let tab = try state.openTerminalTab(state.home.id)
        let session = SessionId()
        try state.setPaneSession(state.home.tabs[0].panes[0].id, session)
        state.queueDiscard(.local, session)
        state.queueDiscard(.local, session)
        try state.closeTab(state.home.id, tab)
        try AppStateStore.save(state, to: path)
        var loaded = try AppStateStore.load(path)
        XCTAssertTrue(loaded.home.tabs.isEmpty)
        XCTAssertEqual(loaded.pendingDiscards(.local), [session])
        XCTAssertNotNil(loaded.closeOperation(.local, session))
        XCTAssertEqual(RestorePlan.plan(loaded, server: .local, sessions: []), RestorePlan())
        loaded.completeDiscard(.local, session)
        try AppStateStore.save(loaded, to: path)
        XCTAssertTrue(try AppStateStore.load(path).pendingDiscards(.local).isEmpty)
    }

    func testCancellingAPendingCreationIsRememberedForItsServer() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let pane = try active(state)
        let second = try state.splitPane(pane, edge: .right)
        XCTAssertEqual(state.prepareCreation(second, directory: "/tmp"), "/tmp")
        XCTAssertEqual(state.prepareCreation(second, directory: "/elsewhere"), "/tmp")
        try state.setStartupCommand(second, "  make test  ")
        XCTAssertEqual(state.startupCommand(second), "make test")
        try state.closePane(second)
        XCTAssertEqual(state.pendingCancellations(.local), [second.creationToken])
        XCTAssertNil(state.startupCommand(second))
        state.completeCancellation(.local, second.creationToken)
        XCTAssertTrue(state.pendingCancellations(.local).isEmpty)
    }

    func testMissingFileBootstrapsAndCorruptOrInvalidFilesAreErrorsLeftInPlace() throws {
        let directory = try TemporaryDirectory()
        let path = directory.file("state.json")
        XCTAssertEqual(try AppStateStore.load(path).projects.count, 1)
        try Data("{ broken json".utf8).write(to: path)
        XCTAssertThrowsError(try AppStateStore.load(path)) { error in
            guard case AppError.json(let errorPath, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(errorPath, path.path)
        }
        XCTAssertEqual(try directory.read("state.json"), "{ broken json")

        var state = try AppState.bootstrap()
        let first = try state.openTerminalTab(state.home.id)
        try state.openTerminalTab(state.home.id)
        try state.selectTab(state.home.id, first)
        try state.setPaneTitle(state.home.tabs[0].panes[0].id, "日本語 — editor")
        try state.setWindowBounds(WindowBounds(x: -1400, y: 40, width: 1200, height: 900))
        XCTAssertThrowsError(try state.setWindowBounds(WindowBounds(x: 0, y: 0, width: -1, height: 10)))
        let valid = try jsonObject(state)
        var invalid: [[String: Any]] = []
        for version in [0, 2] {
            var object = valid
            object["version"] = version
            invalid.append(object)
        }
        var foreignFocus = valid
        var window = valid["window"] as? [String: Any] ?? [:]
        window["activePane"] = PaneId().description
        foreignFocus["window"] = window
        invalid.append(foreignFocus)
        var duplicateTab = valid
        var projects = valid["projects"] as? [[String: Any]] ?? []
        var tabs = projects[0]["tabs"] as? [[String: Any]] ?? []
        tabs.append(tabs[0])
        projects[0]["tabs"] = tabs
        duplicateTab["projects"] = projects
        invalid.append(duplicateTab)
        var badId = valid
        projects = valid["projects"] as? [[String: Any]] ?? []
        projects[0]["id"] = "invalid"
        badId["projects"] = projects
        invalid.append(badId)
        for object in invalid {
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: path)
            XCTAssertThrowsError(try AppStateStore.load(path))
            XCTAssertEqual(try Data(contentsOf: path), data)
        }
        try AppStateStore.save(state, to: path)
        XCTAssertEqual(try AppStateStore.load(path), state)
    }

    func testUnknownKeysAreIgnoredAndOptionalKeysMayBeMissing() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        var object = try jsonObject(state)
        object["futureFeature"] = ["anything": true]
        object["workspaces"] = nil
        object["servers"] = nil
        object["startingDirectories"] = nil
        var window = try XCTUnwrap(object["window"] as? [String: Any])
        window["focusHistory"] = nil
        window["newWindowField"] = 3
        object["window"] = window
        let loaded = try decodeState(object)
        XCTAssertEqual(loaded.home.tabs, state.home.tabs)
        XCTAssertEqual(loaded.activePane, state.activePane)
    }

    // MARK: Workspaces and titles

    func testWorkspacesPersistAndStaleMembersAreDropped() throws {
        let directory = try TemporaryDirectory()
        let path = directory.file("state.json")
        var state = try AppState.bootstrap()
        let untouched = try jsonObject(state)
        XCTAssertNil(untouched["workspaces"])
        let project = try state.addProject(server: .local, directory: NSTemporaryDirectory())
        let work = try state.createWorkspace("Work")
        XCTAssertThrowsError(try state.createWorkspace("   "))
        XCTAssertThrowsError(try state.setWorkspaceMember(work, project: state.home.id, member: true))
        try state.setWorkspaceMember(work, project: project, member: true)
        try state.selectWorkspace(work)
        try AppStateStore.save(state, to: path)
        XCTAssertEqual(try AppStateStore.load(path), state)

        var dangling = try jsonObject(state)
        var workspaces = try XCTUnwrap(dangling["workspaces"] as? [[String: Any]])
        workspaces[0]["projects"] = [project.description, state.home.id.description, ProjectId().description]
        dangling["workspaces"] = workspaces
        var window = try XCTUnwrap(dangling["window"] as? [String: Any])
        window["workspace"] = WorkspaceId().description
        dangling["window"] = window
        let loaded = try decodeState(dangling)
        XCTAssertEqual(loaded.workspaces[0].projects, [project])
        XCTAssertNil(loaded.activeWorkspace)
    }

    func testTerminalTitlesDropDecorationsButKeepText() {
        for (input, expected) in [
            ("◐ Working", "Working"),
            ("◑◒◓⠋⠙✻✶✽ Build", "Build"),
            ("before🚀after", "beforeafter"),
            ("👩🏽‍💻 Develop 🏳️‍🌈", "Develop"),
            ("🇬🇧 Deploy", "Deploy"),
            ("1️⃣#️⃣*️⃣ Tests", "Tests"),
            ("☀︎☀️™️〰️〽️↔️‼️⁉️ Status", "Status"),
            ("\u{e0b0}\u{f120} Prompt", "Prompt"),
        ] {
            XCTAssertEqual(TerminalTitle.derive(input, directory: "/tmp/project"), expected, input)
        }
        for text in [
            "日本語 — café — cafe\u{301} — Ελληνικά — العربية — हिन्दी",
            "~/src/my-project: vim [main] (2) #3 $HOME + tests * 50% @host!",
            "価格 €20 £5 ±2 ×3 ↔ ‼ ⁉",
        ] {
            XCTAssertEqual(TerminalTitle.derive(text, directory: "/tmp/project"), text)
            XCTAssertEqual(TerminalTitle.derive("🚀 \(text) ◐", directory: "/tmp/project"), text)
        }
        XCTAssertEqual(TerminalTitle.derive("π ◐ Inspect files", processName: "oh-my-pi", processIsShell: false, directory: "/tmp"), "Inspect files")
        XCTAssertEqual(TerminalTitle.derive("π = 3.14", directory: "/tmp"), "π = 3.14")
        XCTAssertEqual(TerminalTitle.derive("◐ 🚀", processName: "◐ editor", processIsShell: false, directory: "/tmp/🚀 project"), "editor")
        XCTAssertEqual(TerminalTitle.derive("◐", processName: "zsh", processIsShell: true, directory: "/tmp/🚀 project"), "project")
        XCTAssertEqual(TerminalTitle.derive("◐", directory: "/tmp/🚀"), "Terminal")
    }
}
