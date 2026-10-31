import Foundation
import TabProtocol
import XCTest

final class AgentChatObservationTests: XCTestCase {
    func testLegacyHistoryDoesNotAcquireInventedDatesOrOutcome() throws {
        let item = try JSONDecoder().decode(AgentChatItem.self, from: Data(#"{"id":"old","kind":"assistant","text":"Retained","isComplete":true}"#.utf8))
        XCTAssertNil(item.createdAt); XCTAssertNil(item.updatedAt); XCTAssertNil(item.workContext)
        let turn = try JSONDecoder().decode(AgentChatTurn.self, from: Data(#"{"userItemID":"old","startedAt":0,"completedAt":1,"status":"idle"}"#.utf8))
        XCTAssertNil(turn.outcome, "Legacy idle cannot distinguish completion from interruption")
    }
    func testObservedDatesAndUnknownFutureOutcomeRoundTrip() throws {
        let context = AgentChatWorkContext(runID: "native-turn:user", providerTurnID: "provider-turn", itemType: "future_item_type", planStatus: "active")
        let item = AgentChatItem(id: "tool", kind: .tool, text: "Work", createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200), workContext: context)
        XCTAssertEqual(try WireJSON.decode(AgentChatItem.self, from: WireJSON.encode(item)), item)
        let turn = AgentChatTurn(userItemID: "user", startedAt: Date(), status: .idle, outcome: .init(rawValue: "future_terminal_outcome"))
        XCTAssertEqual(try WireJSON.decode(AgentChatTurn.self, from: WireJSON.encode(turn)), turn)
    }
    func testCompactionCountsRoundTripAndMalformedCountsAreRejected() throws {
        let context = AgentChatWorkContext(itemType: "compaction", sourceStatus: "completed", beforeTokenCount: 12000, afterTokenCount: 5801)
        let item = AgentChatItem(id: "compact", kind: .tool, text: "Context compacted", workContext: context)
        XCTAssertEqual(try WireJSON.decode(AgentChatItem.self, from: WireJSON.encode(item)), item)
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, items: [item])
        try snapshot.validate()
        snapshot.items[0].workContext?.afterTokenCount = -1
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.items[0].workContext?.afterTokenCount = 9_007_199_254_740_992
        XCTAssertThrowsError(try snapshot.validate())
    }
}
