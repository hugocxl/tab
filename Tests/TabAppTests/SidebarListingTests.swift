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
        XCTAssertEqual(ActivityCardData.idleDirectory("hugo@mac:~/repos/codesh"), "codesh")
        XCTAssertEqual(ActivityCardData.idleDirectory("(mini) ~/repos/vitruve"), "vitruve")
        XCTAssertNil(ActivityCardData.idleDirectory("cargo test"))
        XCTAssertEqual(ActivityCardData.withoutHost("(mini) cargo test"), "cargo test")
        XCTAssertEqual(ActivityCardData.taskTitle("✳ Fix the merge errors", provider: .claude), "Fix the merge errors")
        XCTAssertNil(ActivityCardData.taskTitle("⠂ Claude Code", provider: .claude))
    }
}
