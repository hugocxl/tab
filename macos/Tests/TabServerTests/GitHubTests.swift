import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class GitHubTests: XCTestCase {
    static let fakeGh = #"""
    #!/bin/sh
    printf '%s\n' "$@" >> .git/gh-calls
    case "$1 $2" in
      'repo view') printf '%s\n' '{"url":"https://github.com/example/repository"}'; exit 0;;
    esac
    if test -f .git/gh-error; then cat .git/gh-error >&2; exit 1; fi
    if test "$1 $2 $3" = 'pr view --repo'; then
      printf '%s\n' 'argument required when using the --repo flag' >&2; exit 1
    fi
    if test "$1 $2" = 'pr view' && test -f .git/gh-view-error; then
      cat .git/gh-view-error >&2; exit 1
    fi
    if test "$1 $2 $3" = 'pr view --json' && test -f .git/gh-implicit-error; then
      cat .git/gh-implicit-error >&2; exit 1
    fi
    case "$1 $2" in
      'pr view')
        for arg do
          case "$arg" in
            number) printf '%s\n' '{"number":42}'; exit 0;;
            headRefName,headRepository,headRepositoryOwner) printf '%s\n' '{"headRefName":"feature","headRepository":{"name":"fork"},"headRepositoryOwner":{"login":"contributor"}}'; exit 0;;
          esac
        done
        cat .git/gh-pr;;
      'pr list') if test -f .git/gh-list; then cat .git/gh-list; else printf '['; cat .git/gh-pr; printf ']'; fi;;
      'pr create') printf '%s\n' 'https://github.com/example/repository/pull/42';;
      'pr diff') printf 'diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n';;
      'pr merge'|'pr close') exit 0;;
      *) exit 2;;
    esac
    """#

    private func fakeGh(_ repo: GitTestRepo) throws {
        let executable = repo.path + "/.git/fake-gh"
        try makeExecutable(executable, Self.fakeGh)
        let head = try XCTUnwrap(try repo.summary().head)
        try writeResponse(repo, [
            "number": 42, "url": "https://github.com/example/repository/pull/42", "title": "A PR",
            "author": ["login": "contributor"], "headRefName": "main", "headRefOid": head, "baseRefName": "main",
            "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-18T00:00:00Z", "mergeable": "UNKNOWN",
            "mergeStateStatus": "BLOCKED", "isCrossRepository": true,
            "statusCheckRollup": [
                ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"],
                ["__typename": "CheckRun", "status": "IN_PROGRESS"],
                ["__typename": "StatusContext", "state": "FAILURE"],
            ],
        ])
        repo.service.github.executable = executable
    }

    private func response(_ repo: GitTestRepo) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: repo.path + "/.git/gh-pr"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func writeResponse(_ repo: GitTestRepo, _ value: Any, file: String = "gh-pr") throws {
        try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: repo.path + "/.git/" + file))
    }

    private func pr(_ repo: GitTestRepo, _ action: GitPullRequestAction) throws -> GitReply {
        try repo.git(.pullRequest(action))
    }

    private func calls(_ repo: GitTestRepo) throws -> String {
        try repo.read(".git/gh-calls")
    }

    func testReadsAndMutationsHaveStructuredResultsAndExplicitTargets() throws {
        let repo = try GitTestRepo(commit: true)
        try fakeGh(repo)
        guard case .pullRequest(let info?) = try pr(repo, .info) else { return XCTFail("info") }
        XCTAssertEqual(info.number, 42)
        XCTAssertNil(info.mergeable)
        XCTAssertEqual(info.author, "contributor")
        XCTAssertEqual([info.checks.passing, info.checks.failing, info.checks.pending], [1, 1, 1])
        XCTAssertTrue(repo.errorMessage { try self.pr(repo, .updateBranch(number: 42, expectedHead: "deadbeef")) }
            .contains("changed"))
        XCTAssertEqual(try pr(repo, .number), .pullRequestNumber(42))
        for filter in GitPullRequestFilter.allCases {
            _ = try pr(repo, .list(filter: filter, limit: 50, checks: false))
        }
        XCTAssertFalse(try calls(repo).split(separator: "\n").last?.contains("statusCheckRollup") ?? true)
        guard case .rawDiff(let diff) = try pr(repo, .diff(number: 42, lineLimit: 2)) else { return XCTFail("diff") }
        XCTAssertTrue(diff.truncated)
        for method in GitMergeMethod.allCases {
            _ = try pr(repo, .merge(number: 42, method: method, deleteBranch: true,
                                    expectedHead: method == .squash ? "abc123" : nil))
        }
        _ = try pr(repo, .close(number: 42))
        try repo.addRemote()
        _ = try pr(repo, .create(title: "PR title", body: "body\nsecond line", baseBranch: "main", draft: true))
        let calls = try calls(repo)
        XCTAssertTrue(calls.contains("--repo\nhttps://github.com/example/repository\n"))
        XCTAssertTrue(calls.contains("--title\nPR title\n--body\nbody\nsecond line\n--draft"))
        XCTAssertTrue(calls.contains("--squash\n--delete-branch\n--match-head-commit\nabc123\n"))
        XCTAssertTrue(calls.contains("--rebase\n--delete-branch\n"))
        XCTAssertFalse(calls.contains("--rebase\n--delete-branch\n--match-head-commit"))
    }

    func testDetectsOnlyOpenPullRequestsFromEveryLookup() throws {
        for source in ["implicit", "branch", "configured", "list"] {
            let repo = try GitTestRepo(commit: true)
            try fakeGh(repo)
            switch source {
            case "branch": try repo.write(".git/gh-implicit-error", "no pull requests found")
            case "configured":
                _ = try repo.git(.createBranch("pr/42/main"))
                try repo.run("config", "branch.pr/42/main.tab-pr-number", "42")
            case "list": try repo.write(".git/gh-view-error", "no pull requests found")
            default: break
            }
            var value = try response(repo)
            value["isDraft"] = true
            for state in ["CLOSED", "MERGED", "OPEN"] {
                value["state"] = state
                try writeResponse(repo, value)
                let expected: UInt64? = state == "OPEN" ? 42 : nil
                guard case .pullRequest(let info) = try pr(repo, .info) else { return XCTFail("info") }
                XCTAssertEqual(info?.number, expected, "\(source): \(state)")
                XCTAssertEqual(try pr(repo, .number), .pullRequestNumber(expected), "\(source): \(state)")
                guard case .status(let status) = try repo.git(.status(local: false)) else { return XCTFail("status") }
                XCTAssertEqual(status.pullRequest?.number, expected, "\(source): \(state)")
            }
            let calls = try calls(repo)
            XCTAssertTrue(calls.contains("--state\nopen\n"))
            XCTAssertFalse(calls.contains("--state\nall\n"))
        }
    }

    func testIgnoresOldPullRequestsForAReusedBranchAndMatchesTheCurrentCommit() throws {
        let repo = try GitTestRepo(commit: true)
        try fakeGh(repo)
        var old = try response(repo)
        old["state"] = "CLOSED"
        old["headRefOid"] = "old-commit"
        try writeResponse(repo, old)
        XCTAssertEqual(try pr(repo, .info), .pullRequest(nil))
        XCTAssertEqual(try pr(repo, .number), .pullRequestNumber(nil))
        var unrelatedFork = old
        unrelatedFork["state"] = "OPEN"
        try writeResponse(repo, unrelatedFork)
        XCTAssertEqual(try pr(repo, .info), .pullRequest(nil))
        old["headRefOid"] = try XCTUnwrap(try repo.summary().head)
        try writeResponse(repo, old)
        var current = old
        current["number"] = 73
        current["state"] = "OPEN"
        try writeResponse(repo, [old, current], file: "gh-list")
        guard case .pullRequest(let info?) = try pr(repo, .info) else { return XCTFail("info") }
        XCTAssertEqual(info.number, 73)
        XCTAssertEqual(try pr(repo, .number), .pullRequestNumber(73))
    }

    func testFindsAnOpenBranchPullRequestWhenLocalHeadHasAdvanced() throws {
        let repo = try GitTestRepo(commit: true)
        _ = try repo.git(.createBranch("feature"))
        try fakeGh(repo)
        var value = try response(repo)
        value["headRefName"] = "feature"
        value["isCrossRepository"] = false
        try writeResponse(repo, value)
        try repo.write(".git/gh-implicit-error", "no pull requests found for current branch")
        try repo.write("new-work", "ahead of PR\n")
        try repo.commit("new local work")
        guard case .pullRequest(let info?) = try pr(repo, .info) else { return XCTFail("info") }
        XCTAssertEqual(info.number, 42)
        XCTAssertTrue(try calls(repo).contains("pr\nview\nfeature\n"))
    }

    func testDistinguishesAbsentPullRequestsAuthenticationMissingToolsAndInvalidData() throws {
        let repo = try GitTestRepo(commit: true)
        try fakeGh(repo)
        try repo.write(".git/gh-error", "no pull requests found for branch")
        XCTAssertEqual(try pr(repo, .info), .pullRequest(nil))
        XCTAssertEqual(try pr(repo, .number), .pullRequestNumber(nil))
        try repo.write(".git/gh-error", "authentication failed")
        XCTAssertTrue(repo.errorMessage { try self.pr(repo, .info) }.contains("authentication failed"))
        XCTAssertNoThrow(try repo.git(.status(local: false)))
        try FileManager.default.removeItem(atPath: repo.path + "/.git/gh-error")
        try repo.write(".git/gh-pr", "bad JSON")
        XCTAssertThrowsError(try pr(repo, .info))
        repo.service.github.executable = repo.path + "/missing-gh"
        XCTAssertTrue(repo.errorMessage { try self.pr(repo, .info) }.contains("GitHub CLI"))
        XCTAssertNoThrow(try repo.git(.status(local: true)))
    }

    func testWithoutGhPullRequestsExplainHowToGetItAndStatusStillWorks() throws {
        let repo = try GitTestRepo(commit: true, lookup: ExecutableLookup { name in
            name == "gh" ? nil : ExecutableLookup.system(name)
        })
        let message = repo.errorMessage { try repo.git(.pullRequest(.info)) }
        XCTAssertTrue(message.contains("gh isn't installed"), message)
        guard case .status(let status) = try repo.git(.status(local: false)) else { return XCTFail("status") }
        XCTAssertNil(status.pullRequest)
    }

    func testCheckoutAndWorktreeUseForkTrackingAndReplay() throws {
        let repo = try GitTestRepo(commit: true)
        try fakeGh(repo)
        let remote = try repo.addRemote()
        _ = try repo.git(.createBranch("feature"))
        try repo.write("feature-file", "feature\n")
        try repo.commit("feature")
        _ = try repo.git(.push(setUpstream: true))
        _ = try repo.git(.switchBranch("main"))
        try repo.run("config", "url.\(remote).insteadOf", "https://github.com/contributor/fork.git")
        _ = try pr(repo, .checkout(number: 42))
        XCTAssertEqual(try repo.summary().branch, "pr/42/feature")
        try repo.write("feature-file", "updated\n")
        let hash = try repo.commit("PR update")
        _ = try repo.git(.push(setUpstream: false))
        XCTAssertEqual(try GitTestRepo.git(remote, "rev-parse", "refs/heads/feature"), hash + "\n")
        _ = try repo.git(.switchBranch("main"))
        let action = GitAction.worktree(WorktreeIntent(action: .checkoutPullRequest(
            project: ProjectId(), directory: ServerPath(repo.path + "/pr-worktree"), number: 42)))
        let reply = try repo.git(action)
        XCTAssertEqual(try repo.git(action), reply)
        guard case .project(let project) = reply else { return XCTFail("project") }
        XCTAssertEqual(project.parentId, repo.project)
        guard case .repoInfo(let info) = try repo.git(.repoInfo, project: project.id) else { return XCTFail("info") }
        XCTAssertTrue(info.isWorktree)
        XCTAssertEqual(info.currentBranch, "pr/42/feature")
    }

    private func pullRequestBehindBase(_ repo: GitTestRepo, local: String, featureFile: String) throws -> (String, String) {
        let remote = try repo.addRemote()
        try repo.run("push", "-u", "origin", "main")
        try repo.run("switch", "-c", local)
        try repo.write(featureFile, "feature work\n")
        try repo.commit("feature")
        try repo.run("push", "--set-upstream", "origin", "HEAD:refs/heads/feature")
        let head = try XCTUnwrap(try repo.summary().head)
        try repo.run("switch", "main")
        try repo.write("base", "new base work\n")
        try repo.commit("base")
        try repo.run("push", "origin", "main")
        try repo.run("switch", local)
        try fakeGh(repo)
        try writeResponse(repo, [
            "number": 42, "url": "https://github.com/example/repository/pull/42", "title": "A PR",
            "author": ["login": "contributor"], "headRefName": "feature", "headRefOid": head, "baseRefName": "main",
            "state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND",
            "isCrossRepository": false, "statusCheckRollup": [Any](),
        ])
        return (remote, head)
    }

    func testUpdateBranchWorksForPullRequestCheckoutsWithUntrackedFiles() throws {
        let repo = try GitTestRepo(commit: true)
        let (remote, head) = try pullRequestBehindBase(repo, local: "pr/42/feature", featureFile: "feature")
        try repo.run("config", "branch.pr/42/feature.tab-pr-number", "42")
        try repo.write("notes", "untracked\n")
        XCTAssertEqual(try pr(repo, .updateBranch(number: 42, expectedHead: head)), .done)
        XCTAssertTrue(repo.exists("base"))
        XCTAssertEqual(try GitTestRepo.git(remote, "rev-parse", "feature"), try repo.run("rev-parse", "HEAD"))
    }

    func testUpdateBranchExplainsEachRefusalAndPartialFailure() throws {
        var repo = try GitTestRepo(commit: true)
        var (remote, head) = try pullRequestBehindBase(repo, local: "feature", featureFile: "base")
        var message = repo.errorMessage { try self.pr(repo, .updateBranch(number: 42, expectedHead: head)) }
        XCTAssertTrue(message.contains("merge was aborted"), message)
        XCTAssertFalse(repo.exists(".git/MERGE_HEAD"))
        XCTAssertEqual(try repo.summary().head, head)

        repo = try GitTestRepo(commit: true)
        (remote, head) = try pullRequestBehindBase(repo, local: "feature", featureFile: "feature")
        try makeExecutable(remote + "/hooks/pre-receive", "#!/bin/sh\necho rejected >&2\nexit 1\n")
        message = repo.errorMessage { try self.pr(repo, .updateBranch(number: 42, expectedHead: head)) }
        XCTAssertTrue(message.contains("locally, but couldn't push"), message)
        XCTAssertNotEqual(try repo.summary().head, head)

        repo = try GitTestRepo(commit: true)
        (_, head) = try pullRequestBehindBase(repo, local: "feature", featureFile: "feature")
        try repo.write("local", "unpushed\n")
        try repo.commit("unpushed")
        message = repo.errorMessage { try self.pr(repo, .updateBranch(number: 42, expectedHead: head)) }
        XCTAssertTrue(message.contains("isn't at the pull request's head commit"), message)
        try repo.run("switch", "main")
        message = repo.errorMessage { try self.pr(repo, .updateBranch(number: 42, expectedHead: head)) }
        XCTAssertTrue(message.contains("no longer has that pull request"), message)

        repo = try GitTestRepo(commit: true)
        (_, head) = try pullRequestBehindBase(repo, local: "feature", featureFile: "feature")
        var fork = try response(repo)
        fork["isCrossRepository"] = true
        try writeResponse(repo, fork)
        message = repo.errorMessage { try self.pr(repo, .updateBranch(number: 42, expectedHead: head)) }
        XCTAssertTrue(message.contains("forks"), message)
    }

    func testPullRequestFromTheDefaultBranchMovesUncommittedWorkToANewBranch() throws {
        let repo = try GitTestRepo(commit: true)
        let remote = try repo.addRemote()
        try repo.run("push", "-u", "origin", "main")
        let mainBefore = try repo.run("rev-parse", "main")
        try fakeGh(repo)
        try repo.write(".git/gh-error", "no pull requests found")
        XCTAssertEqual(try pr(repo, .info), .pullRequest(nil))
        try FileManager.default.removeItem(atPath: repo.path + "/.git/gh-error")
        try repo.write("work", "uncommitted work\n")
        guard case .changesPreview(let preview) = try repo.git(.changesPreview(lineLimit: 800)) else {
            return XCTFail("preview")
        }
        XCTAssertEqual(preview.destination, GitPushDestination(remote: "origin", branch: "main"))
        _ = try repo.git(.createBranch("fix/status"))
        guard case .commit(let hash) = try repo.git(.commitAll(message: "Fix", expectedHead: preview.head,
                                                                expectedTree: preview.tree)) else {
            return XCTFail("commit")
        }
        _ = try repo.git(.publishBranch(branch: "fix/status",
                                        destination: GitPushDestination(remote: "origin", branch: "fix/status")))
        guard case .pullRequest(let created?) = try pr(repo, .create(title: "Fix status", body: "Summary",
                                                                      baseBranch: "main", draft: false)) else {
            return XCTFail("create")
        }
        XCTAssertEqual(created.number, 42)
        XCTAssertEqual(try repo.summary().branch, "fix/status")
        XCTAssertEqual(try repo.summary().changed, 0)
        XCTAssertEqual(try GitTestRepo.git(remote, "rev-parse", "fix/status"), hash + "\n")
        XCTAssertEqual(try repo.run("rev-parse", "main"), mainBefore)
        XCTAssertEqual(try GitTestRepo.git(remote, "rev-parse", "main"), mainBefore)
        XCTAssertTrue(try calls(repo).contains(
            "create\n--repo\nhttps://github.com/example/repository\n--head\nfix/status\n--base\nmain\n"))
    }

    func testRemoteDefaultBranchIsUsedForPullRequestCreationWithoutALocalBranch() throws {
        let repo = try GitTestRepo(commit: true)
        try fakeGh(repo)
        let remote = try repo.addRemote()
        _ = try repo.git(.createBranch("feature"))
        try repo.run("push", "origin", "HEAD:refs/heads/develop")
        try GitTestRepo.git(remote, "symbolic-ref", "HEAD", "refs/heads/develop")
        guard case .status(let status) = try repo.git(.status(local: true)) else { return XCTFail("status") }
        XCTAssertEqual(status.defaultBranch, "develop")
        _ = try pr(repo, .create(title: "Feature", body: "", baseBranch: nil, draft: false))
        XCTAssertTrue(try calls(repo).contains("--base\ndevelop\n"))
        try repo.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop")
        try FileManager.default.removeItem(atPath: remote)
        XCTAssertEqual(GitRepository(path: repo.path, git: GitCommand()).remoteDefaultBranch(), "develop")
    }

    func testSafeBranchComponentsAndRepositorySegments() {
        XCTAssertEqual(GitHub.safeComponent("feature/x y--z"), "feature/x-y-z")
        XCTAssertEqual(GitHub.safeComponent("///"), "head")
        XCTAssertTrue(GitHub.validSegment("my-repo.name_1"))
        XCTAssertFalse(GitHub.validSegment(".."))
        XCTAssertFalse(GitHub.validSegment("a/b"))
    }
}
