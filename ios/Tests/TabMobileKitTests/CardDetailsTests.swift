import TabProtocol
import TabShared
import XCTest
@testable import TabMobileKit

/// Cards draw what they showed last time at once, place panes as the desktop
/// does, and never take a worktree's files without asking.
@MainActor
final class CardDetailsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Remembered branches

    /// A file from a newer version, with keys and an entry this one can't
    /// read, still gives the branches it can.
    func testRememberedBranchesTolerateNewerFiles() throws {
        let known = ProjectId()
        let plain = ProjectId()
        let json = """
        {"git": {
            "\(known)": {"summary": {"branch": "feature", "ahead": 0, "behind": 0, "changed": 0, "staged": 0,
                                     "unstaged": 0, "untracked": 0, "conflicted": 0, "base": "main", "future": 1}},
            "\(plain)": {},
            "\(ProjectId())": {"summary": {"branch": 7}},
            "not-an-id": {}
        }, "favicons": {}}
        """
        let contents = try XCTUnwrap(CardMemory.decode(Data(json.utf8)))
        XCTAssertEqual(contents.git.count, 3)
        let file = directory.appendingPathComponent("cards.json")
        try Data(json.utf8).write(to: file)
        let summaries = CardMemory(file: file).gitSummaries
        XCTAssertEqual(summaries[known]??.branch, "feature")
        XCTAssertEqual(summaries[known]??.base, "main")
        // Remembered as not a repository, unlike a project never seen.
        XCTAssertEqual(summaries[plain].map { $0 == nil }, true)
        XCTAssertEqual(summaries.count, 2)
    }

    func testRememberedBranchesTolerateMissingOrBrokenFiles() throws {
        XCTAssertEqual(CardMemory.decode(Data("{}".utf8))?.git.isEmpty, true)
        let broken = directory.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: broken)
        XCTAssertTrue(CardMemory(file: broken).gitSummaries.isEmpty)
        XCTAssertTrue(CardMemory(file: directory.appendingPathComponent("missing.json")).gitSummaries.isEmpty)
    }

    /// A Mac's model shows the branches its cards showed last launch before it connects.
    func testServerShowsRememberedBranchesBeforeConnecting() throws {
        let server = PairedServer(id: ServerId(), name: "Mac", hosts: ["mac.local"], port: 7419,
                                  fingerprint: Data(count: 32), device: DeviceId())
        let project = ProjectId()
        let saved = CardMemory.Contents(git: [project.description: .init(summary: GitSummary(branch: "wt-login"))])
        let cards = directory.appendingPathComponent("Cards", isDirectory: true)
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: cards.appendingPathComponent("\(server.id).json"))
        let model = ServerModel(server: server, store: PairedServerStore(directory: directory, tokens: MemoryVault()),
                                clientId: ClientId(), cacheDirectory: directory)
        XCTAssertEqual(model.gitSummaries[project]??.branch, "wt-login")
        XCTAssertFalse(model.isConnected)
    }

    // MARK: Pane positions

    func testPanePositionsNeedTheFeatureAndAnotherPane() {
        XCTAssertTrue(ServerModel.panePositions(supported: false, panes: 3).isEmpty)
        XCTAssertTrue(ServerModel.panePositions(supported: true, panes: 1).isEmpty)
        let positions = ServerModel.panePositions(supported: true, panes: 2)
        XCTAssertEqual(positions.count, 12)
        XCTAssertEqual(positions.first?.title, "Left Third")
        XCTAssertEqual(positions.last?.title, "Bottom Two Thirds")
        // Every share is one the server accepts.
        XCTAssertTrue(positions.allSatisfy { (Layout<PaneId>.minimumRatio...Layout<PaneId>.maximumRatio).contains($0.size.share) })
    }

    /// The phone's reducer places the pane as the server will, keeping the others together.
    func testPositioningAPaneKeepsTheOthersTogether() throws {
        let home = ProjectId()
        let first = Pane(content: .terminal(session: nil))
        let second = Pane(content: .terminal(session: nil))
        let third = Pane(content: .terminal(session: nil))
        let tab = Tab(pane: first)
        var board = TabBoard(home: home)
        let known: (ProjectId) -> Bool = { $0 == home }
        try TabReducer.apply(.createTab(project: home, tab: tab, after: nil), to: &board, isProject: known)
        try TabReducer.apply(.insertPane(second, anchor: first.id, edge: .right), to: &board, isProject: known)
        try TabReducer.apply(.insertPane(third, anchor: second.id, edge: .down), to: &board, isProject: known)
        let position = PanePosition(edge: .down, size: .third)
        try TabReducer.apply(.positionPane(third.id, edge: position.edge, share: position.size.share), to: &board, isProject: known)
        let rects = Dictionary(uniqueKeysWithValues: try XCTUnwrap(board.allTabs.first).layout.rects.map { ($0.0, $0.1) })
        let bottom = try XCTUnwrap(rects[third.id])
        XCTAssertEqual(bottom.width, 1, accuracy: 0.001)
        XCTAssertEqual(bottom.height, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(rects[first.id]?.y ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(rects[second.id]?.y ?? -1, 0, accuracy: 0.001)
    }

    // MARK: Closing worktrees

    func testClosingAWorktreesLastPanesIsCaught() {
        let worktree = ProjectDescriptor(directory: ServerPath("/w"), name: "wt", kind: .worktree, parentId: ProjectId())
        let folder = ProjectDescriptor(directory: ServerPath("/p"), name: "p")
        let a = Pane(content: .terminal(session: nil))
        let b = Pane(content: .terminal(session: nil))
        let one = Tab(pane: a)
        let two = Tab(pane: b)
        XCTAssertTrue(ServerModel.closesWorktree(worktree, tabs: [one], closing: [a.id]))
        // Another tab of the worktree stays open.
        XCTAssertFalse(ServerModel.closesWorktree(worktree, tabs: [one, two], closing: [a.id]))
        XCTAssertTrue(ServerModel.closesWorktree(worktree, tabs: [one, two], closing: [a.id, b.id]))
        XCTAssertFalse(ServerModel.closesWorktree(folder, tabs: [one], closing: [a.id]))
        XCTAssertFalse(ServerModel.closesWorktree(worktree, tabs: [], closing: []))
    }

    /// The question names everything that would be lost.
    func testWorktreeQuestionSaysWhatIsLost() {
        let project = ProjectDescriptor(directory: ServerPath("/w"), name: "login", kind: .worktree)
        var removal = WorktreeRemoval(directory: ServerPath("/w"), device: 1, inode: 2, dirty: true, branch: "login",
                                      ignoredPaths: ["node_modules/", ".env"])
        var closing = WorktreeClosing(project: project, removal: removal)
        XCTAssertTrue(closing.message.contains("uncommitted changes"))
        XCTAssertTrue(closing.message.contains("branch “login” is kept"))
        XCTAssertTrue(closing.message.contains(".env"))
        XCTAssertFalse(closing.message.contains("node_modules"))
        removal.dirty = false
        removal.branch = nil
        removal.ignoredPaths = nil
        closing = WorktreeClosing(project: project, removal: removal, teardown: [WorktreeHook(command: "make clean", project: true)])
        XCTAssertFalse(closing.message.contains("uncommitted"))
        XCTAssertTrue(closing.message.contains("isn't on a branch"))
        XCTAssertTrue(closing.message.contains("Files Git ignores"))
        XCTAssertTrue(closing.message.contains("make clean"))
    }
}
