import Foundation
import XCTest
@testable import TabProtocol

/// Checkpoint states, review context and rewinds only grow the protocol: older peers'
/// messages still decode, and new fields read as absent.
final class AgentCheckpointProtocolTests: XCTestCase {
    func testOlderCheckpointMessagesDecodeWithoutTheNewFields() throws {
        let checkpoint = UUID().uuidString
        let request = try WireJSON.decode(AgentCheckpointRequest.self, from: Data(
            #"{"session":"\#(SessionId())","checkpoint":"\#(checkpoint)","path":"a.swift","offset":0}"#.utf8))
        XCTAssertNil(request.context, "An older app asks for the usual context")
        let reply = try WireJSON.decode(AgentCheckpointReply.self, from: Data(
            #"{"checkpoint":"\#(checkpoint)","files":[],"totalFiles":0}"#.utf8))
        XCTAssertNil(reply.context, "An older server's reply says it didn't honor context")
        let revert = try WireJSON.decode(AgentRevertReply.self, from: Data(#"{"reverted":["a"],"conflicts":[]}"#.utf8))
        XCTAssertNil(revert.unchanged)
        let turn = try WireJSON.decode(AgentChatTurn.self, from: Data(
            #"{"userItemID":"u","startedAt":0,"status":"idle","checkpointStatus":{"state":"capturing"},"rewindable":true,"later":1}"#.utf8))
        XCTAssertEqual(turn.checkpointPhase, .capturing)
        XCTAssertEqual(turn.rewindable, true)
    }

    func testNewRequestsRoundTripAndAreBounded() throws {
        let session = SessionId(), archive = SessionId()
        for request in [AgentConversationRequest.rewind(session: session, at: "u", archive: archive, revision: 4, restoreFiles: true, force: false),
                        .retryCheckpoint(session: session, turn: UUID().uuidString)] {
            XCTAssertEqual(try WireJSON.decode(AgentConversationRequest.self, from: WireJSON.encode(request)), request)
            XCTAssertNoThrow(try request.validate())
            XCTAssertEqual(request.session, session)
        }
        XCTAssertThrowsError(try AgentConversationRequest.rewind(session: session, at: "u", archive: session, revision: 0,
                                                                 restoreFiles: false, force: false).validate())
        XCTAssertThrowsError(try AgentConversationRequest.retryCheckpoint(session: session, turn: "not a turn").validate())
        XCTAssertThrowsError(try AgentCheckpointRequest(session: session, checkpoint: UUID().uuidString, context: -1).validate())
        XCTAssertThrowsError(try AgentCheckpointRequest(session: session, checkpoint: UUID().uuidString,
                                                        context: AgentCheckpointRequest.wholeFile + 1).validate())
        let reply = AgentConversationReply.rewound(AgentRewindReply(snapshot: nil, files: AgentRevertReply(conflicts: ["a"])))
        XCTAssertEqual(try WireJSON.decode(AgentConversationReply.self, from: WireJSON.encode(reply)), reply)
        XCTAssertNoThrow(try reply.validate())
    }

    func testASnapshotRejectsAnUnboundedRecordingReason() {
        var turn = AgentChatTurn(userItemID: "u", startedAt: Date(timeIntervalSince1970: 0))
        turn.checkpointStatus = AgentTurnCheckpointStatus(state: .unavailable)
        turn.checkpointStatus?.reason = String(repeating: "x", count: AgentTurnCheckpointStatus.maxReasonBytes + 1)
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, turns: [turn],
                                         items: [.init(id: "u", kind: .user, text: "Hi")])
        XCTAssertThrowsError(try snapshot.validate())
    }
}
