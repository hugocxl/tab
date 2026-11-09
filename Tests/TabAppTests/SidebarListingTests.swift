import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class SidebarListingTests: XCTestCase {
    private var dirs: TabDirs!
    private var model: AppModel!
    private var server: ModelFakeServer!

    override func setUp() async throws {
        dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        model = ModelFixtures.model(dirs, server: server)
        model.start()
        _ = await ModelFixtures.wait { self.model.state.serverIdentity(.local) != nil }
    }

    override func tearDown() async throws {
        model.connection(.local)?.disconnect()
    }

    /// Adds `parent` with a worktree child `child` the server knows about.
    private func repository(_ parent: String, worktree child: String) async throws -> (ProjectId, ProjectId) {
        let parentId = try XCTUnwrap(model.addProject(try ModelFixtures.folder(parent)))
        _ = await ModelFixtures.wait { self.model.state.projectIntents(.local).isEmpty }
        let folder = try ModelFixtures.folder(child)
        try Data("gitdir: /tmp/x".utf8).write(to: URL(fileURLWithPath: folder + "/.git"))
        let worktree = ProjectDescriptor(directory: ServerPath(folder), name: child, kind: .worktree, parentId: parentId)
        var page = server.catalogPage
        page.projects.append(worktree)
        page.revision += 1
        server.catalogPage = page
        model.applyCatalog(.local, page)
        return (parentId, worktree.id)
    }

    func testNewWorktreeAsksForAFreshProjectNotItsParent() async throws {
        let parent = try XCTUnwrap(model.addProject(try ModelFixtures.folder("app")))
        _ = await ModelFixtures.wait { self.model.state.projectIntents(.local).isEmpty }
        _ = await model.createWorktree(parent: parent, name: "feature", branch: "feature", base: "main",
                                       directory: "/tmp/worktrees/feature", hooks: nil)
        let request = try XCTUnwrap(server.gitRequests.last)
        guard case .worktree(let intent) = request.action,
              case .create(let project, _, _, _) = intent.action else { return XCTFail("Expected a worktree creation") }
        XCTAssertEqual(request.project, parent)
        XCTAssertNotEqual(project, parent)
    }

    /// The Open Tabs layout drops projects with nothing open and orders the
    /// rest by when their tab opened; Cmd-1–9 must select what it shows.
    func testOpenTabsListsOpenTabsOldestFirstAndTheNumberKeysFollow() async throws {
        let (app, feature) = try await repository("app", worktree: "feature")
        _ = try XCTUnwrap(model.addProject(try ModelFixtures.folder("lib")))
        model.newTerminal(in: feature)
        model.newHomeTerminal()
        model.newTerminal(in: app)
        model.updateAppearance { $0.sidebarLayout = .tabs }
        let home = try XCTUnwrap(model.state.home.tabs.first?.id)

        XCTAssertEqual(model.sidebarListing.targets, [.project(feature), .tab(home), .project(app)])
        model.selectCard(0)
        XCTAssertEqual(model.currentProject.id, feature)
        model.selectCard(2)
        XCTAssertEqual(model.currentProject.id, app)

        model.updateAppearance { $0.sidebarLayout = .projects }
        XCTAssertEqual(model.sidebarListing.targets.first, .tab(home))
    }

    /// Grouping by project shows the same open tabs as Open Tabs, under
    /// their projects: no empty checkout or worktree, and no project
    /// without a tab. Cmd-1–9 must select what it shows.
    func testProjectsLayoutShowsOnlyOpenTabsUnderTheirProjects() async throws {
        let (app, feature) = try await repository("app", worktree: "feature")
        let lib = try XCTUnwrap(model.addProject(try ModelFixtures.folder("lib")))
        model.newTerminal(in: feature)
        model.newHomeTerminal()
        model.newTerminal(in: app)
        let home = try XCTUnwrap(model.state.home.tabs.first?.id)

        let listing = model.sidebarListing
        XCTAssertEqual(listing.projects, [app, lib], "project shortcuts still know every project")
        XCTAssertEqual(listing.targets, [.tab(home), .project(feature), .project(app)])
        model.selectCard(1)
        XCTAssertEqual(model.currentProject.id, feature)

        let snapshot = SidebarSnapshot(model: model)
        XCTAssertEqual(snapshot.hosts.first?.groups.map(\.project), [app])
        XCTAssertEqual(snapshot.hosts.first?.groups.first?.cards.map(\.target), [.project(feature), .project(app)])

        model.newTerminal(in: lib)
        XCTAssertEqual(SidebarSnapshot(model: model).hosts.first?.groups.map(\.project), [app, lib])
    }

    func testProjectsListInOrderWithTheirWorktreesAndHomeTerminalsFirst() async throws {
        let (app, feature) = try await repository("app", worktree: "feature")
        let lib = try XCTUnwrap(model.addProject(try ModelFixtures.folder("lib")))
        model.newHomeTerminal()
        let listing = model.sidebarListing
        XCTAssertEqual(listing.terminals.count, 1)
        XCTAssertEqual(listing.projects, [app, lib])
        XCTAssertEqual(listing.groups[0].cards.map(\.project), [app, feature], "worktrees are always expanded")
        XCTAssertEqual(listing.targets.first, .tab(listing.terminals[0].tab), "Home terminals come first")
        model.moveProject(lib, before: app)
        XCTAssertEqual(model.sidebarListing.projects, [lib, app], "manual order follows dragging")
    }

    /// The name filter keeps a worktree's parent header and only matching
    /// rows; Escape (an empty filter) shows everything again.
    func testNameFilterKeepsParentsOfMatchingWorktrees() async throws {
        let (app, feature) = try await repository("app", worktree: "login-fix")
        _ = model.addProject(try ModelFixtures.folder("docs"))
        model.nameFilter = "login"
        var listing = model.sidebarListing
        XCTAssertEqual(listing.projects, [app])
        XCTAssertEqual(listing.groups[0].cards.map(\.project), [feature])
        model.nameFilter = "APP"
        listing = model.sidebarListing
        XCTAssertEqual(listing.groups[0].cards.map(\.project), [app, feature], "a matching parent shows all its rows")
        model.nameFilter = ""
        XCTAssertEqual(model.sidebarListing.projects.count, 2)
    }

    func testWorkspaceFilterListsWorktrees() async throws {
        let (app, _) = try await repository("app", worktree: "feature")
        let lib = try XCTUnwrap(model.addProject(try ModelFixtures.folder("lib")))
        let workspace = try XCTUnwrap(model.createWorkspace("Work", adding: lib))
        model.selectWorkspace(workspace)
        XCTAssertEqual(model.sidebarListing.projects, [lib])
        model.selectWorkspace(nil)
        XCTAssertEqual(model.sidebarListing.groups.first { $0.project == app }?.cards.count, 2)
    }

    func testCyclingFromHomeStartsAtTheFirstProjectInEitherDirection() async throws {
        let first = try XCTUnwrap(model.addProject(try ModelFixtures.folder("first")))
        _ = model.addProject(try ModelFixtures.folder("second"))
        let last = try XCTUnwrap(model.addProject(try ModelFixtures.folder("last")))
        model.newTerminal(in: first)
        model.newTerminal(in: last)
        model.selectProject(model.state.home.id)
        model.cycleProject(forward: false)
        XCTAssertEqual(model.currentProject.id, first)
        model.cycleProject(forward: false)
        XCTAssertEqual(model.currentProject.id, last, "previous wraps after reaching a listed project")
        model.selectProject(model.state.home.id)
        model.cycleProject(forward: true)
        XCTAssertEqual(model.currentProject.id, first)
        model.selectProject(model.state.home.id)
        model.cycleCard(forward: false)
        XCTAssertEqual(model.currentProject.id, last, "previous card starts at the end when Home has no terminal")
    }

    func testCardHeadlinesReadTerminalTitles() {
        XCTAssertEqual(ActivityCardData.idleDirectory("hugo@mac:~/repos/workspace"), "workspace")
        XCTAssertEqual(ActivityCardData.idleDirectory("(mini) ~/repos/vitruve"), "vitruve")
        XCTAssertNil(ActivityCardData.idleDirectory("cargo test"))
        XCTAssertEqual(ActivityCardData.withoutHost("(mini) cargo test"), "cargo test")
        XCTAssertEqual(ActivityCardData.taskTitle("✳ Fix the merge errors", provider: .claude), "Fix the merge errors")
        XCTAssertNil(ActivityCardData.taskTitle("⠂ Claude Code", provider: .claude))
        XCTAssertEqual(ActivityCardData.command("htop — ~/repos"), "htop")
        XCTAssertEqual(ActivityCardData.command("npm run dev — build"), "npm run dev — build", "only a folder suffix goes")
    }

    func testTerminalRowAndLeadIconFollowProcessWithAnUnchangedTitle() async throws {
        model.newHomeTerminal()
        let pane = try XCTUnwrap(model.activePane)
        let bound = await ModelFixtures.wait { self.model.state.pane(pane)?.content.session != nil }
        XCTAssertTrue(bound)
        let controller = try XCTUnwrap(model.controller(for: pane) as? TerminalPane)
        let session = try XCTUnwrap(controller.session)
        var settings = model.terminalSettings
        settings.preferGeneratedTitles = false
        controller.apply(settings: settings)
        session.handle(.metadata(.title("Pinned title")))

        // Drain the title notification before testing process-only changes.
        let initial = expectation(description: "initial title notification")
        var subscription = model.changes.sink { _ in initial.fulfill() }
        model.notify(.state)
        await fulfillment(of: [initial], timeout: 2)
        subscription.cancel()

        func card() throws -> ActivityCardData {
            try XCTUnwrap(SidebarSnapshot(model: model).hosts.first?.terminals.first?.data)
        }
        var previous = try card()
        XCTAssertEqual(previous.panes.first?.icon, .command(.bash))
        for (name, isShell, expected) in [("node", false, AppIcon.node), ("python3.12", false, .python),
                                          ("custom-program", false, .terminal), ("zsh", true, .bash)] {
            let refreshed = expectation(description: "sidebar notification for \(name)")
            subscription = model.changes.sink { changes in
                if changes.contains(.state) { refreshed.fulfill() }
            }
            session.handle(.metadata(.foregroundProcess(ForegroundProcess(name: name, isShell: isShell))))
            await fulfillment(of: [refreshed], timeout: 2)
            subscription.cancel()
            let current = try card()
            XCTAssertEqual(model.state.pane(pane)?.title, "Pinned title")
            XCTAssertEqual(current.panes.first?.icon, .command(expected))
            XCTAssertEqual(current.lead?.icon, .command(expected))
            XCTAssertNotEqual(current, previous, "the sidebar's equality check must see process-only changes")
            previous = current
        }

        let connection = try XCTUnwrap(model.connection(.local))
        connection.activity.agents = [AgentActivity(session: session.session, project: model.state.home.id,
                                                   provider: .claude, state: .idle)]
        session.handle(.metadata(.foregroundProcess(ForegroundProcess(name: "node", isShell: false))))
        let agent = try card()
        XCTAssertEqual(agent.panes.first?.icon, .agent(.claude))
        XCTAssertEqual(agent.lead?.icon, .agent(.claude))
    }

    func testChatOpenersBecomeTitles() {
        XCTAssertEqual(ActivityCardData.chatTopic("can you write a lorem ipsum? thanks"), "Write a lorem ipsum")
        XCTAssertEqual(ActivityCardData.chatTopic("Hey, please fix README.md formatting"), "Fix README.md formatting")
        XCTAssertNil(ActivityCardData.chatTopic("hi"))
    }

    func testCardTitleFollowsTheLeadAgentWhicheverPaneIsFocused() {
        func row(_ topic: ActivityCardData.PaneRow.Topic?, _ status: ActivityCardData.PaneRow.Status = .idle,
                 active: Bool = false) -> ActivityCardData.PaneRow {
            ActivityCardData.PaneRow(id: PaneId(), icon: .kind(.terminal), title: topic?.text ?? "", detail: nil,
                                     status: status, workingSince: nil, active: active, topic: topic)
        }
        let rows = [row(.folder("repos"), active: true), row(.task("Fix the login bug")), row(.task("Ship it"), .blocked)]
        XCTAssertEqual(ActivityCardData.title(rows: rows, customTitle: nil, branch: nil), "Ship it", "the agent waiting for you leads")
        XCTAssertEqual(ActivityCardData.title(rows: rows, customTitle: "Release", branch: nil), "Release")
        XCTAssertEqual(ActivityCardData.title(rows: [row(.folder("repos")), row(.command("htop"))], customTitle: nil, branch: "feature/x"),
                       "feature/x")
        XCTAssertEqual(ActivityCardData.title(rows: [row(.folder("repos")), row(.command("htop"))], customTitle: nil, branch: nil), "htop")
    }

    func testHostGroupsKeepTerminalsProjectsAndShortcutsTogether() async throws {
        let local = try XCTUnwrap(model.addProject(try ModelFixtures.folder("local")))
        model.newTerminal(in: local)
        model.newHomeTerminal()
        XCTAssertFalse(SidebarSnapshot(model: model).showsHostHeaders)

        let first = ServerEntry(name: "Build Mac", ssh: "build")
        let second = ServerEntry(name: "Dev Mac", ssh: "dev")
        var settings = model.settings
        settings.servers = [first, second]
        model.apply(settings: settings)
        var remoteProjects: [ProjectId] = []
        var remoteTabs: [TabId] = []
        // Catalogs arrive out of order; headings still follow the server list.
        for entry in [second, first] {
            let identity = ServerId()
            let home = ProjectDescriptor.home(directory: "/remote/home")
            let project = ProjectDescriptor(directory: "/remote/repo", name: "repo")
            model.applyCatalog(entry.id, CatalogPage(server: identity, home: home.id, revision: 1, projects: [home, project]))
            model.edit { state in remoteTabs.append(try state.openTerminalTab(home.id)) }
            remoteProjects.append(project.id)
        }

        let listing = model.sidebarListing
        XCTAssertEqual(listing.hosts.map(\.server), [.local, first.id, second.id])
        XCTAssertEqual(listing.hosts[0].groups.map(\.project), [local])
        XCTAssertEqual(listing.hosts[1].groups.last?.project, remoteProjects[1])
        XCTAssertEqual(listing.hosts[2].groups.last?.project, remoteProjects[0])
        XCTAssertEqual(listing.targets, listing.hosts.flatMap(\.targets))
        XCTAssertLessThan(try XCTUnwrap(listing.targets.firstIndex(of: .project(local))),
                          try XCTUnwrap(listing.targets.firstIndex(of: .tab(remoteTabs[1]))))

        let snapshot = SidebarSnapshot(model: model)
        XCTAssertTrue(snapshot.showsHostHeaders)
        XCTAssertEqual(snapshot.hosts.map(\.title), ["This Mac", "Build Mac", "Dev Mac"])
        model.nameFilter = "local"
        XCTAssertEqual(model.sidebarListing.hosts.map(\.server), [.local], "empty host groups are omitted")
        model.nameFilter = "dev"
        let named = model.sidebarListing.hosts
        XCTAssertEqual(named.map(\.server), [second.id], "a filter naming a host keeps all of its rows")
        XCTAssertEqual(named.first?.groups.last?.project, remoteProjects[0])
        XCTAssertEqual(named.first?.terminals.map(\.tab), [remoteTabs[0]])
    }

    /// Open Tabs hides a computer whose projects have no tab open, and its
    /// heading with it, so one computer's tabs show without headings.
    func testOpenTabsHeadingsCountOnlyComputersWithOpenTabs() async throws {
        let local = try XCTUnwrap(model.addProject(try ModelFixtures.folder("local")))
        let remote = ServerEntry(name: "Mac Mini", ssh: "mini")
        var settings = model.settings
        settings.servers = [remote]
        model.apply(settings: settings)
        let home = ProjectDescriptor.home(directory: "/remote/home")
        let project = ProjectDescriptor(directory: "/remote/repo", name: "repo")
        model.applyCatalog(remote.id, CatalogPage(server: ServerId(), home: home.id, revision: 1, projects: [home, project]))
        model.newTerminal(in: project.id)
        model.updateAppearance { $0.sidebarLayout = .tabs }

        let single = SidebarSnapshot(model: model)
        XCTAssertEqual(single.hosts.map(\.server), [remote.id])
        XCTAssertFalse(single.showsHostHeaders)

        model.newTerminal(in: local)
        let both = SidebarSnapshot(model: model)
        XCTAssertEqual(both.hosts.map(\.server), [.local, remote.id])
        XCTAssertTrue(both.showsHostHeaders)
    }
}
