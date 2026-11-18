import Foundation
import XCTest
@testable import TabProtocol

/// Old and new builds keep talking: every L1–L5 addition is optional, and new requests
/// reach an older server as something it answers `unsupported`.
final class AgentApprovalProtocolTests: XCTestCase {
    func testOlderRecordsWithoutTheNewFieldsStillDecode() throws {
        let item = try WireJSON.decode(AgentChatItem.self, from: Data(#"{"id":"r","kind":"approval","text":"Allow?","isComplete":false}"#.utf8))
        XCTAssertNil(item.approval)
        let turn = try WireJSON.decode(AgentChatTurn.self, from: Data(#"{"userItemID":"u","startedAt":0,"status":"failed"}"#.utf8))
        XCTAssertNil(turn.rateLimit)
        let queued = try WireJSON.decode(AgentQueuedPrompt.self, from: Data(#"{"id":"\#(UUID().uuidString)","text":"t","attachments":[],"state":"queued","revision":0}"#.utf8))
        XCTAssertNil(queued.scheduledAt)
        let history = try WireJSON.decode(AgentHistoryReply.self, from: Data(#"{"entries":[],"truncated":false}"#.utf8))
        XCTAssertNil(history.conversations)
    }

    func testNewFieldsRoundTripAndCountAgainstTheTranscript() throws {
        let request = AgentApprovalRequest(kind: "permissions", summary: "Needs network",
            requested: [.init(label: "Network", value: "Internet access")],
            decisions: [.init(id: "turn", kind: .allowOnce, title: "Allow for this turn"), .init(id: "decline", kind: .decline, title: "Decline")],
            origin: .init(providerRequestID: "7", numericID: true, threadID: "child", childAgentID: "child", childToolUseID: "spawn"),
            outcome: .init(decision: "turn", kind: .allowOnce, title: "Allow for this turn", source: .user))
        let item = AgentChatItem(id: "7", kind: .approval, text: "Approved", approval: request)
        XCTAssertEqual(try WireJSON.decode(AgentChatItem.self, from: WireJSON.encode(item)), item)
        XCTAssertGreaterThan(item.transcriptByteCount, AgentChatItem(id: "7", kind: .approval, text: "Approved").transcriptByteCount + 256)
        let future = try WireJSON.decode(AgentApprovalDecision.Kind.self, from: Data(#""allowForever""#.utf8))
        XCTAssertEqual(future.rawValue, "allowForever")
        var duplicate = request
        duplicate.decisions.append(request.decisions[0])
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testNewRequestsRoundTripAndValidate() throws {
        let session = SessionId()
        let prompt = AgentPrompt(text: "Retry", model: nil, effort: nil, provider: .codex, planMode: false)
        let requests: [AgentChatRequest] = [
            .decide(session: session, request: "7", decision: "session"),
            .decide(session: session, request: "elic", decision: "accept", answers: ["plan": ["Pro"]]),
            .schedule(session: session, prompt: prompt, at: Date(timeIntervalSince1970: 1_950_000_000)),
        ]
        for request in requests {
            try request.validate()
            XCTAssertEqual(try WireJSON.decode(AgentChatRequest.self, from: WireJSON.encode(request)), request)
        }
        XCTAssertThrowsError(try AgentChatRequest.decide(session: session, request: "7", decision: "").validate())
        let conversations: [AgentConversationRequest] = [.reopen(session: session), .delete(session: session),
                                                         .setRetention(session: session, retention: .init(deleteAfterDays: 30))]
        for request in conversations {
            try request.validate()
            XCTAssertEqual(try WireJSON.decode(AgentConversationRequest.self, from: WireJSON.encode(request)), request)
        }
        XCTAssertThrowsError(try AgentConversationRequest.setRetention(session: session, retention: .init(deleteAfterDays: 0)).validate())
    }

    func testAnOlderServerSeesANewRequestAsUnknown() throws {
        // A request case an older build lacks fails to decode inside the envelope and
        // becomes `.unknown`, which the server answers `unsupported`.
        let envelope = Data(#"{"type":"request","id":4,"body":{"type":"agentChat","request":{"futureDecision":{"session":"\#(SessionId())"}}}}"#.utf8)
        guard case .request(_, let body) = try WireJSON.decode(Message.self, from: envelope) else { return XCTFail("Not a request") }
        guard case .unknown = body else { return XCTFail("Expected unknown, got \(body)") }
    }
}
