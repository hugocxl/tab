import Foundation
import XCTest
@testable import TabServer

final class AgentCheckpointTests: XCTestCase {
    func testCapturesNetTurnChangesWithoutTouchingIndexOrBranch() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "original\n")
        try repo.commit("initial")
        try repo.write("file.txt", "staged\n")
        try repo.run("add", "file.txt")
        try repo.write("file.txt", "before turn\n")
        let indexPath = try repo.run("rev-parse", "--path-format=absolute", "--git-path", "index").trimmingCharacters(in: .whitespacesAndNewlines)
        let index = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let head = try repo.run("rev-parse", "HEAD")
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        defer { try? store.remove(before) }
        try repo.write("file.txt", "intermediate edit\n")
        try repo.write("file.txt", "after turn\n")
        let after = try store.capture(directory: repo.path)
        defer { try? store.remove(after) }
        let change = try XCTUnwrap(store.files(from: before, to: after).first)
        XCTAssertEqual(change.path, "file.txt")
        XCTAssertEqual(change.additions, 1)
        XCTAssertEqual(change.deletions, 1)
        let diff = try store.diff(from: before, to: after, path: change.path)
        XCTAssertTrue(diff.rows.contains { $0.text == "-before turn" })
        XCTAssertTrue(diff.rows.contains { $0.text == "+after turn" })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: indexPath)), index)
        XCTAssertEqual(try repo.run("rev-parse", "HEAD"), head)
        XCTAssertEqual(try repo.run("show", ":file.txt"), "staged\n")
    }

    func testRevertedEditsDisappearAndUntrackedNamesRemainExact() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("file", "same\n")
        try repo.commit("initial")
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        defer { try? store.remove(before) }
        try repo.write("file", "temporary\n")
        try repo.write("file", "same\n")
        let name = "new [*]\nfile.txt"
        try repo.write(name, "new\n")
        let after = try store.capture(directory: repo.path)
        defer { try? store.remove(after) }
        let changes = try store.files(from: before, to: after)
        XCTAssertEqual(changes.map(\.path), [name])
        XCTAssertEqual(changes.first?.additions, 1)
    }

    func testCleanupCannotDeleteAnUnrelatedReference() throws {
        let repo = try GitTestRepo(commit: true)
        let tree = try repo.run("rev-parse", "HEAD^{tree}").trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.run("update-ref", "refs/keep/my-reference", tree)
        let forged = AgentCheckpointStore.Snapshot(tree: tree, reference: "refs/keep/my-reference", directory: repo.path)
        XCTAssertThrowsError(try AgentCheckpointStore().remove(forged))
        XCTAssertEqual(try repo.run("rev-parse", "refs/keep/my-reference").trimmingCharacters(in: .whitespacesAndNewlines), tree)
    }

    func testSummaryRetainsManyFilesAndDefersDetailedPatchUntilRequested() throws {
        let repo = try GitTestRepo(commit: false)
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        defer { try? store.remove(before) }
        for index in 0..<80 { try repo.write("file-\(index).txt", "first\nsecond\n") }
        let after = try store.capture(directory: repo.path)
        defer { try? store.remove(after) }
        let files = try store.files(from: before, to: after)
        XCTAssertEqual(files.count, 80)
        XCTAssertTrue(files.allSatisfy { $0.additions == 2 && $0.deletions == 0 })
        let record = AgentCheckpointRecord(before: before, after: after, files: files)
        let summary = record.summary(id: UUID().uuidString)
        XCTAssertEqual(summary.files.count, 64)
        XCTAssertEqual(summary.totalFiles, 80)
        XCTAssertEqual(summary.additions, 160)
        XCTAssertTrue(summary.truncated)
        let diff = try store.diff(from: before, to: after, path: "file-79.txt")
        XCTAssertTrue(diff.rows.contains { $0.text == "+second" })
    }

    func testUnbornRepositoryAndBinaryChanges() throws {
        let repo = try GitTestRepo(commit: false)
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        defer { try? store.remove(before) }
        try Data([0, 1, 2, 0]).write(to: URL(fileURLWithPath: repo.path + "/binary"))
        let after = try store.capture(directory: repo.path)
        defer { try? store.remove(after) }
        let changes = try store.files(from: before, to: after)
        XCTAssertEqual(changes.map(\.path), ["binary"])
        XCTAssertNil(changes.first?.additions)
        XCTAssertNil(changes.first?.deletions)
        XCTAssertThrowsError(try repo.run("rev-parse", "--verify", "HEAD"))
    }
}
