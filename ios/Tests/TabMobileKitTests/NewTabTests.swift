import Foundation
import TabProtocol
import XCTest
@testable import TabMobileKit

/// New worktrees are named, placed and set up as the desktop's New in
/// Project page makes them.
@MainActor
final class NewTabTests: XCTestCase {
    func testTypedNamesBecomeBranchesAndPullRequests() {
        XCTAssertEqual(ServerModel.quickBranchName("  fix login  bug "), "fix-login-bug")
        XCTAssertEqual(ServerModel.quickBranchName("feat/login"), "feat/login")
        XCTAssertEqual(ServerModel.pullRequestNumber(" #482 "), 482)
        XCTAssertNil(ServerModel.pullRequestNumber("#0"))
        XCTAssertNil(ServerModel.pullRequestNumber("482"))
        XCTAssertNil(ServerModel.pullRequestNumber("#4a"))
    }

    func testAnEmptyNameGetsARandomOneNoBranchHas() {
        XCTAssertEqual(ServerModel.worktreeName("login", taken: ["login"]), "login")
        let random = ServerModel.worktreeName("", taken: ["main"])
        XCTAssertTrue(random.hasPrefix("wt-"))
        XCTAssertEqual(random.count, 7)
    }

    func testTheDefaultBaseIsTheDefaultBranchElseTheCurrentOne() {
        XCTAssertEqual(ServerModel.defaultBase([GitBranch(name: "dev", current: true), GitBranch(name: "main", isDefault: true)]), "main")
        XCTAssertEqual(ServerModel.defaultBase([GitBranch(name: "dev", current: true)]), "dev")
        XCTAssertNil(ServerModel.defaultBase([]))
    }

    func testFolderNamesAreSafeAsOneFolder() {
        XCTAssertEqual(ServerModel.folderName("feat/login page", fallback: "name"), "feat-login-page")
        XCTAssertEqual(ServerModel.folderName("..", fallback: "name"), "name")
        XCTAssertEqual(ServerModel.folderName("v1.2_rc", fallback: "name"), "v1.2_rc")
    }

    func testSetupRunsEachCommandFromAScriptTheShellCannotReinterpret() throws {
        let worktree = ProjectDescriptor(directory: ServerPath("/Users/me/.tab/worktrees/app/x"), name: "x", kind: .worktree)
        let hooks = [WorktreeHook(command: "npm install", project: true), WorktreeHook(command: "echo 'done'", project: false)]
        let line = ServerModel.setupCommand(hooks, worktree: worktree, repository: ServerPath("/Users/me/app"), branch: "x")
        XCTAssertTrue(line.hasPrefix("env TAB_PROJECT_PATH=/Users/me/app "))
        XCTAssertTrue(line.contains("TAB_WORKTREE_BRANCH=x /bin/sh -c "))
        let encoded = try XCTUnwrap(line.split(separator: " ").last)
        let script = try XCTUnwrap(Data(base64Encoded: String(encoded)).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(script, #""${SHELL:-/bin/sh}" -c 'npm install' && "${SHELL:-/bin/sh}" -c 'echo '\''done'\'''"#)
    }

    func testShellWordsAreQuotedOnlyWhenNeeded() {
        XCTAssertEqual(ServerModel.shellQuoted("/bin/sh"), "/bin/sh")
        XCTAssertEqual(ServerModel.shellQuoted("TAB_WORKTREE_NAME=my tree"), "'TAB_WORKTREE_NAME=my tree'")
        XCTAssertEqual(ServerModel.shellQuoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ServerModel.shellQuoted(""), "''")
    }
}
