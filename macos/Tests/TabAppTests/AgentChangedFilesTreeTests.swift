import XCTest
import TabProtocol
@testable import TabApp

final class AgentChangedFilesTreeTests: XCTestCase {
    func testCompactsSingleDirectoryChainsAndAggregatesCounts() throws {
        let tree = AgentChangedFilesTree.build([
            .init(path: "Sources/TabApp/Sidebar/Rows.swift", additions: 2, deletions: 2),
            .init(path: "README.md", additions: 1, deletions: 0)
        ])
        XCTAssertEqual(tree.map(\.name), ["Sources/TabApp/Sidebar", "README.md"])
        XCTAssertEqual(tree[0].path, "Sources/TabApp/Sidebar")
        XCTAssertEqual(tree[0].children.first?.path, "Sources/TabApp/Sidebar/Rows.swift")
        XCTAssertEqual(tree[0].additions, 2)
        XCTAssertEqual(tree[0].deletions, 2)
    }

    func testBranchesRemainExpandableAndFilesUseNaturalOrder() {
        let tree = AgentChangedFilesTree.build([
            .init(path: "src/tests/test10.swift", additions: 10, deletions: 0),
            .init(path: "src/tests/test2.swift", additions: 2, deletions: 0),
            .init(path: "src/media/image.png", additions: nil, deletions: nil)
        ])
        XCTAssertEqual(tree.first?.name, "src")
        XCTAssertEqual(tree.first?.children.map(\.name), ["media", "tests"])
        XCTAssertEqual(tree.first?.children.last?.children.map(\.name), ["test2.swift", "test10.swift"])
        XCTAssertNil(tree.first?.children.first?.children.first?.file?.additions)
        XCTAssertNil(tree.first?.additions, "A binary/unknown child must not turn into a complete zero-count contribution")
        XCTAssertEqual(tree.first?.children.last?.additions, 12)
    }
    func testUnknownAndOverflowingCountsStayUnknownIndependently() {
        let tree = AgentChangedFilesTree.build([
            .init(path: "src/a", additions: UInt64.max, deletions: 2),
            .init(path: "src/b", additions: 1, deletions: nil),
        ])
        XCTAssertNil(tree.first?.additions)
        XCTAssertNil(tree.first?.deletions)
        XCTAssertEqual(tree.first?.children.first?.additions, UInt64.max)
        XCTAssertEqual(tree.first?.children.first?.deletions, 2)
    }

}
