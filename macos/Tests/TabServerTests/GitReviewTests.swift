import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class GitReviewTests: XCTestCase {
    private func preview(_ repo: GitTestRepo, staged: Bool = false) throws -> GitChangesPreview {
        let action: GitAction = staged ? .stagedPreview(lineLimit: 800) : .changesPreview(lineLimit: 800)
        guard case .changesPreview(let preview) = try repo.git(action) else { throw GitTestError.failed("preview") }
        return preview
    }

    private func commitAll(_ repo: GitTestRepo, _ preview: GitChangesPreview) throws -> GitReply {
        try repo.git(.commitAll(message: "Reviewed change", expectedHead: preview.head, expectedTree: preview.tree))
    }

    private func commitStaged(_ repo: GitTestRepo, _ preview: GitChangesPreview) throws -> GitReply {
        try repo.git(.commitStaged(message: "Staged change", expectedHead: preview.head, expectedTree: preview.tree))
    }

    private func mixedChanges(_ repo: GitTestRepo) throws {
        try repo.write("tracked", "one\n")
        try repo.commit("tracked")
        try repo.write("tracked", "one\ntwo\n")
        try repo.write("staged", "staged\n")
        try repo.run("add", "staged")
        try repo.write("untracked", "new\n")
    }

    func testPreviewDescribesEveryChangeWithoutTouchingTheIndex() throws {
        let repo = try GitTestRepo(commit: true)
        try mixedChanges(repo)
        let before = try repo.porcelain()
        let preview = try preview(repo)
        XCTAssertEqual(try repo.porcelain(), before)
        XCTAssertEqual(preview.branch, "main")
        XCTAssertEqual(preview.head, try repo.summary().head)
        XCTAssertEqual(preview.files, [
            GitPreviewFile(path: "staged", added: 1, removed: 0),
            GitPreviewFile(path: "tracked", added: 1, removed: 0),
            GitPreviewFile(path: "untracked", added: 1, removed: 0, untracked: true),
        ])
        XCTAssertTrue(preview.diff.diff.contains("+two"))
        XCTAssertNil(preview.destination)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: repo.path + "/.git")
            .filter { $0.hasPrefix("tab-preview-") }
        XCTAssertEqual(leftovers, [])
    }

    func testCommitAllCommitsThePreviewedTreeAndRefusesLaterEdits() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("a", "a\n")
        try repo.write("b", "b\n")
        let stale = try preview(repo)
        try repo.write("a", "edited after the review\n")
        let before = try repo.porcelain()
        XCTAssertTrue(repo.errorMessage { try self.commitAll(repo, stale) }.contains("review the changes again"))
        XCTAssertEqual(try repo.porcelain(), before)
        let reviewed = try preview(repo)
        guard case .commit(let hash) = try commitAll(repo, reviewed) else { return XCTFail("commit") }
        XCTAssertEqual(try repo.summary().head, hash)
        XCTAssertEqual(try repo.summary().changed, 0)
        XCTAssertEqual(try repo.run("rev-parse", "HEAD^{tree}"), reviewed.tree + "\n")
        try repo.write("c", "c\n")
        var moved = reviewed
        moved.tree = try preview(repo).tree
        XCTAssertTrue(repo.errorMessage { try self.commitAll(repo, moved) }.contains("branch moved"))
    }

    func testStagedCommitIncludesOnlyTheReviewedIndex() throws {
        let repo = try GitTestRepo(commit: true)
        try mixedChanges(repo)
        let before = try repo.porcelain()
        let stale = try preview(repo, staged: true)
        XCTAssertEqual(try repo.porcelain(), before)
        XCTAssertEqual(stale.files.map(\.path), ["staged"])
        XCTAssertTrue(stale.diff.diff.contains("+staged") && !stale.diff.diff.contains("+two"))
        try repo.run("add", "tracked")
        XCTAssertTrue(repo.errorMessage { try self.commitStaged(repo, stale) }.contains("review the changes again"))
        try repo.run("restore", "--staged", "tracked")
        let reviewed = try preview(repo, staged: true)
        guard case .commit(let hash) = try commitStaged(repo, reviewed) else { return XCTFail("commit") }
        XCTAssertEqual(try repo.summary().head, hash)
        XCTAssertEqual(try repo.run("rev-parse", "HEAD^{tree}"), reviewed.tree + "\n")
        let summary = try repo.summary()
        XCTAssertEqual([summary.staged, summary.unstaged, summary.untracked], [0, 1, 1])
    }

    func testFailedCommitKeepsWhatTheUserHadStaged() throws {
        let repo = try GitTestRepo(commit: true)
        try mixedChanges(repo)
        let hooks = repo.path + "/.git/test-hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try makeExecutable(hooks + "/pre-commit", "#!/bin/sh\necho blocked by hook >&2\nexit 1\n")
        try repo.run("config", "core.hooksPath", hooks)
        let before = try repo.porcelain()
        let message = repo.errorMessage { try self.commitAll(repo, try self.preview(repo)) }
        XCTAssertTrue(message.contains("blocked by hook"), message)
        XCTAssertEqual(try repo.porcelain(), before)
        XCTAssertFalse(repo.exists(".git/index.lock"))
    }

    func testPreviewAndCommitRefuseUnresolvedConflicts() throws {
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
        XCTAssertTrue(repo.errorMessage { try repo.git(.changesPreview(lineLimit: nil)) }
            .contains("Resolve merge conflicts"))
        let head = try repo.summary().head
        XCTAssertTrue(repo.errorMessage {
            try repo.git(.commitAll(message: "Merge", expectedHead: head, expectedTree: "abcd"))
        }.contains("Resolve merge conflicts"))
        XCTAssertTrue(repo.exists(".git/MERGE_HEAD"))
    }

    func testPublishPushesTheSameBranchNameEvenWhenTrackingAnotherBranch() throws {
        let repo = try GitTestRepo(commit: true)
        let remote = try repo.addRemote()
        try repo.run("push", "-u", "origin", "main")
        try repo.run("switch", "-c", "feature", "origin/main")
        XCTAssertEqual(try repo.summary().upstream, "origin/main")
        try repo.write("work", "work\n")
        let preview = try preview(repo)
        XCTAssertEqual(preview.destination, GitPushDestination(remote: "origin", branch: "feature"))
        _ = try commitAll(repo, preview)
        let mainBefore = try GitTestRepo.git(remote, "rev-parse", "main")
        _ = try repo.git(.publishBranch(branch: "feature", destination: GitPushDestination(remote: "origin",
                                                                                           branch: "feature")))
        XCTAssertEqual(try GitTestRepo.git(remote, "rev-parse", "main"), mainBefore)
        XCTAssertEqual(try GitTestRepo.git(remote, "rev-parse", "feature"), try repo.run("rev-parse", "HEAD"))
        XCTAssertEqual(try repo.summary().upstream, "origin/feature")
        XCTAssertTrue(repo.errorMessage {
            try repo.git(.publishBranch(branch: "feature", destination: GitPushDestination(remote: "origin",
                                                                                           branch: "main")))
        }.contains("push destination changed"))
    }

    func testPullRequestCheckoutsPublishToTheirPullRequestHead() throws {
        let repo = try GitTestRepo(commit: true)
        let remote = try repo.addRemote()
        try repo.run("push", "origin", "main:refs/heads/feature")
        try repo.run("fetch", "origin")
        try repo.run("branch", "--track", "pr/42/feature", "origin/feature")
        try repo.run("config", "branch.pr/42/feature.tab-pr-number", "42")
        _ = try repo.git(.switchBranch("pr/42/feature"))
        try repo.write("fix", "fix\n")
        let preview = try preview(repo)
        XCTAssertEqual(preview.destination, GitPushDestination(remote: "origin", branch: "feature"))
        _ = try commitAll(repo, preview)
        _ = try repo.git(.publishBranch(branch: "pr/42/feature",
                                        destination: GitPushDestination(remote: "origin", branch: "feature")))
        XCTAssertEqual(try GitTestRepo.git(remote, "rev-parse", "feature"), try repo.run("rev-parse", "HEAD"))
        XCTAssertThrowsError(try GitTestRepo.git(remote, "rev-parse", "--verify", "refs/heads/pr/42/feature"))
    }

    func testSwitchToBaseSkipsOtherWorktreesAndOnlyFastForwards() throws {
        let repo = try GitTestRepo(commit: true)
        let remote = try repo.addRemote()
        try repo.run("push", "-u", "origin", "main")
        let other = repo.path + "/.git/other-clone"
        try repo.run("clone", remote, other)
        func advance(_ message: String) throws {
            try GitTestRepo.git(other, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit",
                                "--allow-empty", "-m", message)
            try GitTestRepo.git(other, "push", "origin", "main")
        }
        try advance("merged pull request")
        _ = try repo.git(.createBranch("feature"))
        let linked = repo.path + "/.git/linked-main"
        try repo.run("worktree", "add", linked, "main")
        guard case .baseSwitch(.checkedOutElsewhere(let directory)) = try repo.git(.switchToBase("main")) else {
            return XCTFail("checked out elsewhere")
        }
        XCTAssertEqual(canonical(directory.rawValue), canonical(linked))
        XCTAssertEqual(try repo.summary().branch, "feature")
        try repo.run("worktree", "remove", linked)
        XCTAssertEqual(try repo.git(.switchToBase("main")), .baseSwitch(.updated))
        XCTAssertEqual(try repo.summary().branch, "main")
        XCTAssertEqual(try repo.run("rev-parse", "HEAD"), try repo.run("rev-parse", "origin/main"))
        try repo.write("local", "local only\n")
        try repo.commit("local only")
        _ = try repo.git(.switchBranch("feature"))
        try advance("another merge")
        let message = repo.errorMessage { try repo.git(.switchToBase("main")) }
        XCTAssertTrue(message.contains("couldn't fast-forward"), message)
        XCTAssertEqual(try repo.summary().branch, "main")
    }
}
