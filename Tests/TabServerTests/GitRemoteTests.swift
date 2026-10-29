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
}
