import Foundation
import TabProtocol
import XCTest

final class AgentToolActivityTests: XCTestCase {
    func testInputOutputAndDiffSurvivePersistence() throws {
        let tool = AgentToolActivity(name: "Edit", category: .edit,
                                     input: #"{"file_path":"Sources/main.swift","old_string":"old","new_string":"new"}"#,
                                     output: "Updated", status: .completed,
                                     filePaths: ["Sources/main.swift"],
                                     fileChanges: [.init(path: "Sources/main.swift", diff: "-old\n+new", kind: "update")])
        let restored = try JSONDecoder().decode(AgentToolActivity.self, from: JSONEncoder().encode(tool))
        XCTAssertEqual(restored, tool)
        XCTAssertEqual(restored.summary, "Sources/main.swift")
    }

    func testSparseMetadataCanDecodeWithoutFabricatedActivity() throws {
        let tool = try JSONDecoder().decode(AgentToolActivity.self, from: Data(#"{"name":"Read","future_field":true}"#.utf8))
        XCTAssertNil(tool.startedAt)
        XCTAssertNil(tool.status)
        XCTAssertNil(tool.output)
    }
}
