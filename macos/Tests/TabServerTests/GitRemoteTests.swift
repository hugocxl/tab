import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class GitRemoteTests: XCTestCase {
    func testPushSetsUpstreamListsAndDeletesRemoteBranchesAndPullUpdates() throws {
        let repo = try GitTestRepo(commit: true)
        let remote = try repo.addRemote()
        _ = try repo.git(.push(setUpstream: false))
        XCTAssertEqual(try repo.summary().upstream, "origin/main")
        XCTAssertEqual(try repo.git(.remoteBranches), .remoteBranches(["main"]))

        let other = try GitTestRepo(commit: true)
        try other.run("remote", "add", "origin", remote)
        try other.run("fetch", "origin")
        try other.run("reset", "--hard", "origin/main")
        try other.write("from-other", "pulled\n")
        let hash = try other.commit("from other")
        _ = try other.git(.push(setUpstream: true))
        _ = try repo.git(.fetch)
        XCTAssertEqual(try repo.summary().behind, 1)
        _ = try repo.git(.pull)
        XCTAssertEqual(try repo.summary().head, hash)

        _ = try repo.git(.createBranch("temporary"))
        _ = try repo.git(.push(setUpstream: true))
        XCTAssertEqual(try repo.git(.remoteBranches), .remoteBranches(["main", "temporary"]))
        _ = try repo.git(.deleteRemoteBranch("temporary"))
        XCTAssertEqual(try repo.git(.remoteBranches), .remoteBranches(["main"]))
    }

    func testStatusPrefersTheRemoteDefaultBranchAndCachesIt() throws {
        let repo = try GitTestRepo(commit: true)
        let remote = try repo.addRemote()
        try repo.run("push", "origin", "HEAD:refs/heads/main")
        try GitTestRepo.git(remote, "update-ref", "refs/heads/develop", "refs/heads/main")
        try GitTestRepo.git(remote, "symbolic-ref", "HEAD", "refs/heads/develop")
        try repo.run("update-ref", "refs/remotes/origin/main", "HEAD")
        try repo.run("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        try Data("printf x >> .git/remote-calls\nexec git upload-pack .git/test-remote.git\n".utf8)
            .write(to: URL(fileURLWithPath: repo.path + "/.git/remote-probe"))
        try repo.run("config", "protocol.ext.allow", "always")
        try repo.run("remote", "set-url", "origin", "ext::/bin/sh .git/remote-probe")
        for _ in 0 ..< 3 {
            guard case .status(let status) = try repo.git(.status(local: true)) else { return XCTFail("status") }
            XCTAssertEqual(status.defaultBranch, "develop")
            XCTAssertFalse(status.branches.contains { $0.name == "develop" })
        }
        XCTAssertEqual(try repo.read(".git/remote-calls"), "x")
    }

    func testDefaultBranchCacheAnswersStaleAtOnceAndRefreshesInTheBackground() {
        final class Calls: @unchecked Sendable {
            var count = 0
            var answer: String? = "main"
        }
        let calls = Calls()
        var queued: [@Sendable () -> Void] = []
        let cache = DefaultBranchCache { queued.append($0) }
        let lookup: @Sendable () -> String? = { calls.count += 1; return calls.answer }
        let start = Date()
        XCTAssertEqual(cache.resolve("repo", remotes: "origin", now: start, resolve: lookup), "main")
        XCTAssertEqual(calls.count, 1)

        // Expired: the known branch at once, one refresh however many reads.
        let later = start.addingTimeInterval(DefaultBranchCache.lifetime + 1)
        calls.answer = "develop"
        XCTAssertEqual(cache.resolve("repo", remotes: "origin", now: later, resolve: lookup), "main")
        XCTAssertEqual(cache.resolve("repo", remotes: "origin", now: later, resolve: lookup), "main")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(queued.count, 1)
        queued.removeFirst()()
        XCTAssertEqual(cache.resolve("repo", remotes: "origin", resolve: lookup), "develop")

        // Offline, a refresh keeps the branch known before.
        calls.answer = nil
        _ = cache.resolve("repo", remotes: "origin", now: Date().addingTimeInterval(DefaultBranchCache.lifetime + 1),
                          resolve: lookup)
        queued.removeFirst()()
        XCTAssertEqual(cache.resolve("repo", remotes: "origin", resolve: lookup), "develop")

        // A lookup that found nothing is remembered; other remotes ask again.
        let before = calls.count
        XCTAssertNil(cache.resolve("bare", remotes: "", resolve: lookup))
        XCTAssertNil(cache.resolve("bare", remotes: "", resolve: lookup))
        XCTAssertEqual(calls.count, before + 1)
        calls.answer = "trunk"
        XCTAssertEqual(cache.resolve("bare", remotes: "origin", resolve: lookup), "trunk")
    }
}
