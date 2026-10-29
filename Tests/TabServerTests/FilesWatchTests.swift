import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class FilesWatchTests: XCTestCase {
    func testWatchSendsRelativeChangesToTheWatchingClientUntilUnwatched() async throws {
        let workspace = try FilesWorkspace()
        try workspace.git("init", "-q")
        let received = expectation(description: "files changed")
        received.assertForOverFulfill = false
        let project = workspace.project
        workspace.events.onSend = { event, _ in
            if case .filesChanged(project, let changes) = event, changes.paths.contains("created.txt") {
                received.fulfill()
            }
        }
        let reply = try await workspace.files(.watch)
        XCTAssertEqual(reply, .done)
        try await Task.sleep(nanoseconds: 300_000_000)
        try "hello".write(to: workspace.url("created.txt"), atomically: false, encoding: .utf8)
        await fulfillment(of: [received], timeout: 10)

        for (event, client) in workspace.events.sent {
            XCTAssertEqual(client, workspace.client)
            guard case .filesChanged(_, let changes) = event else { continue }
            XCTAssertFalse(changes.paths.contains { $0.rawValue.hasPrefix(".git") || $0.isAbsolute })
        }

        _ = try await workspace.files(.unwatch)
        try await Task.sleep(nanoseconds: 200_000_000)
        let count = workspace.events.sent.count
        try "again".write(to: workspace.url("later.txt"), atomically: false, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(workspace.events.sent.count, count)
    }

    func testChangesSkipGitMetadataAndCollapseIntoARescanPastTheLimit() {
        let root = "/repo"
        var batch = FileSystemWatcher.Batch(paths: ["/repo/a.txt", "/repo/.git/index", "/repo/sub/.git/HEAD",
                                                    "/other/file", "/repo"])
        XCTAssertEqual(FilesService.changes(batch, root: root, prefix: "/repo/").paths, ["a.txt", ""])
        batch.paths = (0 ... Limits.maxFileChanges).map { "/repo/file\($0)" }
        let many = FilesService.changes(batch, root: root, prefix: "/repo/")
        XCTAssertTrue(many.rescan)
        XCTAssertTrue(many.paths.isEmpty)
    }

    func testClientDisconnectStopsItsWatches() async throws {
        let workspace = try FilesWorkspace()
        _ = try await workspace.files(.watch)
        workspace.service.clientDisconnected(workspace.client)
        try await Task.sleep(nanoseconds: 200_000_000)
        try "x".write(to: workspace.url("after.txt"), atomically: false, encoding: .utf8)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(workspace.events.sent.isEmpty)
    }
}
