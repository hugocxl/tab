import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationAnchorTests: XCTestCase {
    func testRevealsRetainedMessageAndNestedCompletedTool() throws {
        let document = AgentTranscriptDocument()
        let date = Date()
        let turn = AgentChatTurn(userItemID: "prompt", startedAt: date, completedAt: date.addingTimeInterval(2), status: .idle, outcome: .completed)
        let items: [AgentChatItem] = [.init(id: "prompt", kind: .user, text: "Inspect"),
            .init(id: "tool", kind: .tool, text: "Read", tool: .init(name: "Read", input: "{}", output: "Retained")),
            .init(id: "answer", kind: .assistant, text: "Answer")]
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 680)
        XCTAssertNil(document.frameForEntry("activity:tool"))
        let resolved = try XCTUnwrap(document.anchor(revealing: .item("tool"), offset: 5))
        XCTAssertEqual(resolved.rowID, "activity:tool")
        XCTAssertEqual(resolved.localOffset, 5)
        XCTAssertTrue(document.rowStates["work:prompt"]?.expanded == true)
        XCTAssertNotNil(document.frameForEntry("activity:tool"))
        XCTAssertEqual(document.anchor(revealing: .item("answer"))?.rowID, "answer")
        XCTAssertEqual(document.anchor(revealing: .turn("prompt"))?.rowID, "work:prompt")
        XCTAssertNil(document.anchor(revealing: .item("no-longer-retained")))
        XCTAssertNil(document.anchor(revealing: .turn("no-longer-retained")))
    }
}
