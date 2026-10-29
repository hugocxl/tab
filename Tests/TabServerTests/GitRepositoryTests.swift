import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class GitRepositoryTests: XCTestCase {
    func testSummaryTracksCommitsAndDetachedHeads() throws {
        let repo = try GitTestRepo(commit: true)
        XCTAssertEqual(try repo.summary().commitSubject, "initial")
        try repo.run("checkout", "--detach")
        try repo.run("commit", "--allow-empty", "-m", "Detached activity\n\nBody")
        let summary = try repo.summary()
        XCTAssertNil(summary.branch)
        XCTAssertEqual(summary.commitSubject, "Detached activity")
        XCTAssertGreaterThan(summary.commitTimestamp ?? 0, 0)
    }

    func testFolderWithoutRepositoryHasNoSummaryAndInitCreatesOne() throws {
        let repo = try GitTestRepo(commit: false)
        try FileManager.default.removeItem(atPath: repo.path + "/.git")
        XCTAssertEqual(try repo.git(.summary), .summary(nil))
        XCTAssertThrowsError(try repo.git(.changes))
        XCTAssertEqual(try repo.git(.initRepository), .done)
        XCTAssertNotNil(try repo.summary())
    }

    func testChangesSeparateStagedUnstagedUntrackedRenamedAndConflictedFiles() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("modified", "one\n")
        try repo.write("staged", "one\n")
        try repo.write("old name", "first\nsecond\nthird\n")
        try repo.write("conflict", "base\n")
        try repo.commit("base")
        try repo.run("switch", "-c", "other")
        try repo.write("conflict", "other\n")
        try repo.commit("other")
        try repo.run("switch", "main")
        try repo.write("conflict", "main\n")
        try repo.commit("main")
        XCTAssertThrowsError(try repo.run("merge", "other"))
        try repo.write("modified", "one\ntwo\n")
        try repo.write("staged", "one\nstaged\n")
        try repo.run("add", "staged")
        try repo.run("mv", "old name", "new name")
        try repo.write("folder/untracked", "a\nb\nc")

        guard case .changes(let files) = try repo.git(.changes) else { return XCTFail("changes") }
        func file(_ path: String) throws -> GitFile {
            try XCTUnwrap(files.first { $0.path.rawValue == path }, path)
        }
        let modified = try file("modified")
        XCTAssertEqual(modified.index, .unmodified)
        XCTAssertEqual(modified.worktree, .modified)
        XCTAssertTrue(modified.isUnstaged && !modified.isStaged)
        XCTAssertEqual(modified.added, 1)
        let staged = try file("staged")
        XCTAssertEqual(staged.index, .modified)
        XCTAssertTrue(staged.isStaged && !staged.isUnstaged)
        XCTAssertEqual(staged.added, 1)
        XCTAssertEqual(staged.removed, 0)
        let renamed = try file("new name")
        XCTAssertEqual(renamed.index, .renamed)
        XCTAssertEqual(renamed.originalPath, "old name")
        let untracked = try file("folder/untracked")
        XCTAssertTrue(untracked.isUntracked)
        XCTAssertEqual(untracked.added, 3)
        let conflict = try file("conflict")
        XCTAssertTrue(conflict.isConflicted)
        XCTAssertEqual(conflict.index, .unmerged)

        let summary = try repo.summary()
        XCTAssertEqual(summary.conflicted, 1)
        XCTAssertEqual(summary.untracked, 1)
        XCTAssertEqual(summary.changed, 5)
    }

    func testUnbornStageUnstageAndDiscardWithLiteralPaths() throws {
        let repo = try GitTestRepo(commit: false)
        let relative = ServerPath("odd\n[*].txt")
        try repo.write(relative.rawValue, "one\ntwo\n")
        var summary = try repo.summary()
        XCTAssertNil(summary.head)
        XCTAssertNil(summary.commitSubject)
        XCTAssertNil(summary.commitTimestamp)
        XCTAssertEqual(summary.untracked, 1)
        _ = try repo.git(.stage([relative]))
        XCTAssertEqual(try repo.summary().staged, 1)
        _ = try repo.git(.unstage([relative]))
        summary = try repo.summary()
        XCTAssertEqual(summary.untracked, 1)
        _ = try repo.git(.discard([relative]))
        XCTAssertFalse(repo.exists(relative.rawValue))
    }

    func testDiscardValidatesTheWholeSelectionBeforeRemovingFiles() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("keep", "untracked\n")
        XCTAssertThrowsError(try repo.git(.discard(["keep", "../outside"])))
        XCTAssertEqual(try repo.read("keep"), "untracked\n")
    }

    func testDiscardPreservesTheIndexAndRejectsTraversal() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("file", "staged\n")
        _ = try repo.git(.stage(["file"]))
        try repo.write("file", "unstaged\n")
        let summary = try repo.summary()
        XCTAssertEqual([summary.changed, summary.staged, summary.unstaged], [1, 1, 1])
        _ = try repo.git(.discard(["file"]))
        XCTAssertEqual(try repo.read("file"), "staged\n")
        XCTAssertThrowsError(try repo.git(.discard(["../outside"])))
    }

    func testUntrackedFoldersAndSymlinkTraversalAreNeverDeleted() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("outside/keep", "keep")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/link", withDestinationPath: repo.path + "/outside")
        let repository = GitRepository(path: repo.path, git: GitCommand())
        XCTAssertThrowsError(try repository.safePath("link/keep"))
        XCTAssertThrowsError(try repository.safePath(".git/config"))
        XCTAssertThrowsError(try repo.git(.discard(["outside"])))
        XCTAssertTrue(repo.exists("outside/keep"))
    }

    func testStagingEditsToAnIndexRenameDoesNotAddItsDeletedSource() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("old", "first\nsecond\nthird\n")
        try repo.commit("original")
        try repo.run("mv", "old", "new")
        try repo.write("new", "first\nsecond\nthird\nedit\n")
        let files = try GitRepository(path: repo.path, git: GitCommand()).files()
        XCTAssertTrue(files.contains { $0.index == .renamed && $0.worktree == .modified })
        _ = try repo.git(.stage(["new"]))
        XCTAssertEqual(try repo.summary().unstaged, 0)
        XCTAssertFalse(repo.exists("old"))
        _ = try repo.git(.unstage(["new"]))
        XCTAssertEqual(try repo.summary().staged, 0)
    }

    func testCommitStageAllAndAmendKeepParentAndStagedTree() throws {
        let repo = try GitTestRepo(commit: true)
        let parent = try XCTUnwrap(try repo.summary().head)
        try repo.write("file", "original\n")
        let original = try repo.commit("original")
        try repo.write("file", "staged\n")
        _ = try repo.git(.stage([]))
        try repo.write("file", "unstaged\n")
        guard case .commit(let amended) = try repo.git(.commit(message: "amended π\n\nbody", stageAll: false,
                                                                amend: true)) else { return XCTFail("commit") }
        XCTAssertNotEqual(amended, original)
        XCTAssertEqual(try repo.summary().head, amended)
        XCTAssertEqual(try repo.run("rev-parse", "HEAD^"), parent + "\n")
        XCTAssertEqual(try repo.run("log", "-1", "--format=%B"), "amended π\n\nbody\n\n")
        XCTAssertEqual(try repo.run("show", "HEAD:file"), "staged\n")
        XCTAssertEqual(try repo.read("file"), "unstaged\n")
    }

    func testAmendWithAnEmptyMessageKeepsThePreviousMessage() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("file", "original\n")
        let original = try repo.commit("original π\n\nbody")
        let message = try repo.run("log", "-1", "--format=%B")
        try repo.write("file", "amended\n")
        _ = try repo.git(.stage([]))
        guard case .commit(let amended) = try repo.git(.commit(message: "", stageAll: false, amend: true)) else {
            return XCTFail("commit")
        }
        XCTAssertNotEqual(amended, original)
        XCTAssertEqual(try repo.run("log", "-1", "--format=%B"), message)
        XCTAssertEqual(try repo.run("show", "HEAD:file"), "amended\n")
    }

    func testInvalidCommitMessagesAndMissingRepositoriesLeaveHeadAlone() throws {
        let repo = try GitTestRepo(commit: true)
        let head = try repo.summary().head
        for message in [" ", "nul\0message", String(repeating: "x", count: 64 * 1024 + 1)] {
            XCTAssertThrowsError(try repo.git(.commit(message: message, stageAll: false, amend: true)))
            XCTAssertEqual(try repo.summary().head, head)
        }
        try FileManager.default.removeItem(atPath: repo.path + "/.git")
        XCTAssertThrowsError(try repo.git(.commit(message: "", stageAll: false, amend: true)))
    }

    func testCommitWithoutAnIdentityExplainsWhatToSet() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.run("config", "user.name", "")
        try repo.write("file", "content\n")
        let message = repo.errorMessage { try repo.git(.commit(message: "change", stageAll: true, amend: false)) }
        XCTAssertTrue(message.contains("Set your Git name and email"), message)
    }

    func testAmendRefusesUnresolvedConflicts() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("file", "base\n")
        try repo.commit("base")
        _ = try repo.git(.createBranch("other"))
        try repo.write("file", "other\n")
        try repo.commit("other")
        _ = try repo.git(.switchBranch("main"))
        try repo.write("file", "main\n")
        try repo.commit("main")
        XCTAssertThrowsError(try repo.run("merge", "other"))
        let head = try repo.summary().head
        for message in ["Amended", ""] {
            let error = repo.errorMessage { try repo.git(.commit(message: message, stageAll: false, amend: true)) }
            XCTAssertTrue(error.contains("Resolve merge conflicts"), error)
            XCTAssertEqual(try repo.summary().head, head)
        }
    }

    func testBranchesSwitchCreateAndDelete() throws {
        let repo = try GitTestRepo(commit: true)
        _ = try repo.git(.createBranch("feature"))
        try repo.write("work", "work\n")
        try repo.commit("feature work")
        guard case .branches(let branches) = try repo.git(.branches) else { return XCTFail("branches") }
        XCTAssertEqual(branches.map(\.name), ["feature", "main"])
        XCTAssertEqual(branches.first { $0.current }?.name, "feature")
        XCTAssertTrue(branches.first { $0.name == "main" }?.isDefault == true)
        XCTAssertTrue(branches.allSatisfy { $0.name != "feature" || $0.checkedOut })
        _ = try repo.git(.switchBranch("main"))
        XCTAssertEqual(try repo.summary().branch, "main")
        XCTAssertFalse(repo.errorMessage { try repo.git(.deleteBranch("feature")) }.isEmpty, "unmerged branch")
        XCTAssertThrowsError(try repo.git(.deleteLocalBranch(name: "feature", force: false)))
        _ = try repo.git(.deleteLocalBranch(name: "feature", force: true))
        guard case .branches(let remaining) = try repo.git(.branches) else { return XCTFail("branches") }
        XCTAssertEqual(remaining.map(\.name), ["main"])
        XCTAssertThrowsError(try repo.git(.switchBranch("-x")))
        XCTAssertThrowsError(try repo.git(.createBranch("bad..name")))
    }

    func testInitStageAllUnstageAllCommitHistoryAndTagsOnUnbornRepositories() throws {
        let repo = try GitTestRepo(commit: false)
        XCTAssertEqual(try repo.git(.log(maxCount: 100, skip: 0)), .log([]))
        _ = try repo.git(.unstage([]))
        try repo.write("nested/file", "first\n")
        _ = try repo.git(.stage([]))
        XCTAssertEqual(try repo.summary().staged, 1)
        _ = try repo.git(.unstage([]))
        XCTAssertEqual(try repo.summary().staged, 0)
        XCTAssertTrue(repo.exists("nested/file"))
        let first = try repo.commit("first π\n\nbody")
        try repo.write("nested/file", "second\n")
        let second = try repo.commit("second")
        _ = try repo.git(.createTag(name: "v1.0", hash: second))
        guard case .log(let latest) = try repo.git(.log(maxCount: 1, skip: 0)) else { return XCTFail("log") }
        XCTAssertEqual(latest[0].hash, second)
        XCTAssertEqual(latest[0].parentHashes, [first])
        XCTAssertTrue(latest[0].refs.contains(GitRef(name: "v1.0", kind: .tag)))
        XCTAssertTrue(latest[0].refs.contains(GitRef(name: "HEAD", kind: .head)))
        XCTAssertEqual(latest[0].authorName, "Test")
        guard case .log(let older) = try repo.git(.log(maxCount: 1, skip: 1)) else { return XCTFail("log") }
        XCTAssertEqual(older[0].hash, first)
        XCTAssertEqual(older[0].subject, "first π")
        guard case .repoInfo(let info) = try repo.git(.repoInfo) else { return XCTFail("info") }
        XCTAssertEqual(canonical(info.root.rawValue), repo.path)
        XCTAssertFalse(info.isWorktree)
        XCTAssertEqual(info.currentBranch, "main")
    }

    func testCheckoutCherryPickAndRevert() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("file", "one\n")
        let first = try repo.commit("one")
        _ = try repo.git(.createBranch("pick"))
        try repo.write("picked", "picked\n")
        let picked = try repo.commit("picked")
        _ = try repo.git(.switchBranch("main"))
        _ = try repo.git(.cherryPick(picked))
        XCTAssertTrue(repo.exists("picked"))
        _ = try repo.git(.revert(first))
        XCTAssertFalse(repo.exists("file"))
        XCTAssertEqual(try repo.summary().staged, 1)
        try repo.run("reset", "--hard")
        _ = try repo.git(.checkout(first))
        XCTAssertNil(try repo.summary().branch)
        XCTAssertEqual(try repo.summary().head, first)
    }

    func testStatusIncludesNestedUntrackedFilesAndLineStatistics() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("tracked", "initial\n")
        try repo.commit("initial")
        try repo.write("tracked", "changed\n")
        try repo.write("src/model/native.swift", "new\nlast")
        guard case .status(let status) = try repo.git(.status(local: true)) else { return XCTFail("status") }
        let untracked = try XCTUnwrap(status.files.first { $0.file.path == "src/model/native.swift" })
        XCTAssertTrue(untracked.file.isUntracked)
        XCTAssertEqual(untracked.unstaged.additions, 2)
        XCTAssertEqual(status.summary.untracked, 1)
        XCTAssertNil(status.pullRequest)
    }
}
