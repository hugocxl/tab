import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationAnchorTests: XCTestCase {
    func testResolvesSourceMessageAndRevealsNestedCompletedTool() throws {
        let document = AgentTranscriptDocument()
        let date = Date()
        let turn = AgentChatTurn(userItemID: "prompt", startedAt: date, completedAt: date.addingTimeInterval(2), status: .idle, outcome: .completed)
        let items: [AgentChatItem] = [.init(id: "prompt", kind: .user, text: "Inspect"),
            .init(id: "tool", kind: .tool, text: "Read", tool: .init(name: "Read", input: "{}", output: "Retained")),
            .init(id: "answer", kind: .assistant, text: "Answer")]
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 680)
        XCTAssertNil(document.frameForEntry("activity:tool"))
        let source = try XCTUnwrap(AgentConversationAnchor(["itemId": "tool", "offset": 5]))
        let resolved = try XCTUnwrap(document.resolveConversationAnchor(source))
        XCTAssertEqual(resolved.rowID, "activity:tool")
        XCTAssertEqual(resolved.localOffset, 5)
        XCTAssertTrue(document.rowStates["work:prompt"]?.expanded == true)
        XCTAssertNotNil(document.frameForEntry("activity:tool"))
        let message = try XCTUnwrap(AgentConversationAnchor(["messageId": "answer", "offset": 8]))
        XCTAssertEqual(document.resolveConversationAnchor(message)?.rowID, "answer")
        let folded = try XCTUnwrap(AgentConversationAnchor(["runId": "native-turn:prompt"]))
        XCTAssertEqual(document.resolveConversationAnchor(folded)?.rowID, "work:prompt")
        let removed = try XCTUnwrap(AgentConversationAnchor(["messageId": "no-longer-retained"]))
        XCTAssertNil(document.resolveConversationAnchor(removed))
    }

    func testAnchorValidationKeepsUnknownAndUnboundedCoordinatesOut() throws {
        XCTAssertNil(AgentConversationAnchor([:]))
        XCTAssertNil(AgentConversationAnchor(["messageId": "bad\0identity"]))
        XCTAssertEqual(try XCTUnwrap(AgentConversationAnchor(["messageId": "answer", "offset": Double.infinity])).offset, 0)
        XCTAssertEqual(try XCTUnwrap(AgentConversationAnchor(["messageId": "answer", "offset": -10])).offset, 0)
    }
}
