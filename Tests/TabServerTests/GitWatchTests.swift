import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class GitWatchTests: XCTestCase {
    func testWatchSendsGitChangedToTheWatchingClientUntilUnwatched() throws {
        let repo = try GitTestRepo(commit: true)
        let changed = expectation(description: "gitChanged")
        changed.assertForOverFulfill = false
        repo.events.onSend = { event, client in
            if event == .gitChanged(project: repo.project), client == repo.client { changed.fulfill() }
        }
        XCTAssertEqual(try repo.git(.watch), .done)
        try repo.write("file", "changed\n")
        wait(for: [changed], timeout: 10)
        XCTAssertEqual(try repo.git(.unwatch), .done)
        repo.events.onSend = { _, _ in XCTFail("event after unwatch") }
        try repo.write("other", "changed\n")
        Thread.sleep(forTimeInterval: 1.5)
        repo.events.onSend = nil
    }

    func testOnlyStatusRelevantMetadataCounts() {
        let roots = RepositoryWatch.Roots(worktree: "/repo", git: "/repo/.git", common: "/repo/.git")
        for path in ["/repo/src/code.swift", "/repo/.git/HEAD", "/repo/.git/index", "/repo/.git/refs/heads/main",
                     "/repo/.git/worktrees", "/repo/.git/worktrees/topic"] {
            XCTAssertTrue(roots.relevant(path), path)
        }
        for path in ["/other/file", "/repo/.git/index.lock", "/repo/.git/objects/aa/bb", "/repo/.git/logs/HEAD",
                     "/repo/.git/worktrees/topic/index", "/repo/.git/worktrees/topic/logs/HEAD"] {
            XCTAssertFalse(roots.relevant(path), path)
        }
        let linked = RepositoryWatch.Roots(worktree: "/checkout", git: "/repo/.git/worktrees/topic", common: "/repo/.git")
        for path in ["/checkout/file", "/repo/.git/worktrees/topic/index", "/repo/.git/refs/heads/main",
                     "/repo/.git/packed-refs", "/repo/.git/worktrees/other"] {
            XCTAssertTrue(linked.relevant(path), path)
        }
        for path in ["/repo/.git/worktrees/topic/logs/HEAD", "/repo/.git/worktrees/other/index"] {
            XCTAssertFalse(linked.relevant(path), path)
        }
    }

    func testProcessesStopAtTheirDeadlineAndFailuresKeepTheirStatus() throws {
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sh", ["-c", "sleep 10"], timeout: 0.05)) {
            XCTAssertEqual($0 as? ProcessFailure, .timedOut("sh"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let output = try ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 7"])
        XCTAssertEqual(output.status, 7)
        XCTAssertEqual(output.stdoutText, "out\n")
        XCTAssertTrue(GitCommand.failure(output).message.contains("err"))
        let truncated = try ProcessRunner.run("/bin/sh", ["-c", "yes | head -c 100000"], truncateStdout: 10)
        XCTAssertTrue(truncated.truncated)
        XCTAssertEqual(truncated.stdout.count, 10)
        let echoed = try ProcessRunner.run("/bin/cat", [], input: Data("piped".utf8))
        XCTAssertEqual(echoed.stdoutText, "piped")
    }
}
