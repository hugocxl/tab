import Darwin
import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class FileWriteParentsTests: XCTestCase {
    func testExplicitPlanWriteCreatesNestedParentsAndDefaultWriteRemainsUnchanged() async throws {
        let workspace = try FilesWorkspace()
        await assertFilesThrows(try await workspace.files(.write(path: "existing-behavior/missing.md", content: "no")))
        let plan = "# Proposed plan\n\n- Preserve 🐈 exactly.\n"
        let result = try await workspace.files(.write(path: "plans/nested/plan.md", content: plan, createParents: true))
        XCTAssertEqual(result, .path("plans/nested/plan.md"))
        XCTAssertEqual(try String(contentsOf: workspace.url("plans/nested/plan.md"), encoding: .utf8), plan)
        let legacy = Data(#"{"type":"write","path":"plan.md","content":"legacy"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(FilesAction.self, from: legacy), .write(path: "plan.md", content: "legacy"))
        let encoded = try JSONEncoder().encode(FilesAction.write(path: "plan.md", content: "legacy"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["createParents"])
    }

    func testEscapesAndExternalSymlinksFailWithoutWritingOutsideProject() async throws {
        let workspace = try FilesWorkspace(), outside = try FilesWorkspace()
        try FileManager.default.createSymbolicLink(atPath: workspace.url("external").path, withDestinationPath: outside.path)
        for path in ["../outside.md", "new/../../outside.md", "external/nested/outside.md", "/tmp/outside.md"] {
            await assertFilesThrows(try await workspace.files(.write(path: ServerPath(path), content: "must not escape", createParents: true)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("new").path), "Lexical escapes must be rejected before creating any parent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.url("nested").path))
        try Data("ordinary file".utf8).write(to: workspace.url("file"))
        await assertFilesThrows(try await workspace.files(.write(path: "file/nested/plan.md", content: "no", createParents: true)))
    }

    func testConcurrentIntermediateSymlinkSwapsNeverCreateExternalParents() async throws {
        let workspace = try FilesWorkspace(), outside = try FilesWorkspace()
        try FileManager.default.createDirectory(at: workspace.url("folder"), withIntermediateDirectories: false)
        let stop = ManagedFlag(), directory = workspace.path, external = outside.path
        let swapper = Thread {
            while !stop.isSet {
                rename(directory + "/folder", directory + "/saved")
                symlink(external, directory + "/folder")
                unlink(directory + "/folder")
                rename(directory + "/saved", directory + "/folder")
            }
            stop.finish()
        }
        swapper.start()
        defer { stop.set(); stop.waitFinished() }
        for _ in 0..<100 {
            _ = try? await workspace.files(.write(path: "folder/nested/plan.md", content: "inside only", createParents: true))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.url("nested").path))
    }
}
