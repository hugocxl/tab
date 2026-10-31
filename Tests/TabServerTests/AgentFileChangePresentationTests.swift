import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentFileChangePresentationTests: XCTestCase {
    func testClaudePatchMetadataAndNewFileSurvivePersistence() throws {
        var activity = agentToolActivity(name: "Edit", input: #"{"file_path":"/project/file.swift","old_string":"before","new_string":"after"}"#)
        agentUpdateClaudeFileChange(&activity, result: ["filePath": "/project/file.swift", "structuredPatch": [
            ["oldStart": 3, "oldLines": 1, "newStart": 3, "newLines": 1, "lines": ["-before", "+after"]]
        ]])
        XCTAssertEqual(activity.presentation, .fileChange)
        XCTAssertEqual(activity.fileChangeDetails?.diff, "--- /project/file.swift\n+++ /project/file.swift\n@@ -3,1 +3,1 @@\n-before\n+after\n")
        XCTAssertEqual(activity.fileChanges?.first?.diff, activity.fileChangeDetails?.diff)
        XCTAssertEqual(try JSONDecoder().decode(AgentToolActivity.self, from: JSONEncoder().encode(activity)), activity)
        var created = agentToolActivity(name: "Write", input: #"{"file_path":"file.txt","content":"hello"}"#)
        agentUpdateClaudeFileChange(&created, result: ["type": "create", "filePath": "file.txt", "structuredPatch": [], "content": "hello"])
        XCTAssertEqual(created.fileChangeDetails?.diff, "--- /dev/null\n+++ file.txt\n@@ -0,0 +1,1 @@\n+hello\n\\ No newline at end of file\n")
        let notebook = agentToolActivity(name: "NotebookEdit", input: #"{"notebook_path":"analysis.ipynb"}"#)
        XCTAssertEqual(notebook.presentation, .fileChange)
        XCTAssertEqual(notebook.fileChangeDetails?.fileName, "analysis.ipynb")
    }

    func testMissingMetadataRetainsProviderOutputAndEmptyPatchStaysEmpty() {
        var activity = agentToolActivity(name: "Edit", input: #"{"file_path":"file.txt"}"#)
        activity.output = "The edit failed."
        agentUpdateClaudeFileChange(&activity, result: nil)
        XCTAssertEqual(activity.fileChangeDetails?.diff, "The edit failed.")
        agentUpdateClaudeFileChange(&activity, result: ["filePath": "file.txt", "structuredPatch": []])
        XCTAssertEqual(activity.fileChangeDetails?.diff, "")
    }
}
