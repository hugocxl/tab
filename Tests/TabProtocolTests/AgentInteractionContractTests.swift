import Foundation
import XCTest
@testable import TabProtocol

final class AgentInteractionContractTests: XCTestCase {
    func testLegacySnapshotAcceptsMissingInteractionFields() throws {
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex)
        let bytes = try WireJSON.encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["queuedPrompts"])
        XCTAssertNil(object["planMode"])
        XCTAssertEqual(try WireJSON.decode(AgentChatSnapshot.self, from: bytes), snapshot)
    }

    func testSubmissionAndRevisionFencedEditsRoundTrip() throws {
        let session = SessionId()
        let prompt = AgentPrompt(text: "Plan it", model: "model", effort: .high, provider: .codex, planMode: true)
        let requests: [AgentChatRequest] = [
            .submit(session: session, prompt: prompt),
            .editQueued(session: session, id: prompt.id, text: "Change", expectedRevision: 7),
            .editQueued(session: session, id: prompt.id, text: "Change", expectedRevision: 7, settings: .init(model: nil, effort: nil, planMode: false)),
            .deliverQueued(session: session, id: prompt.id, expectedRevision: 7),
            .answer(session: session, request: "q", answers: ["a": ["custom text"]], cancelled: false)
        ]
        for request in requests {
            try request.validate()
            XCTAssertEqual(try WireJSON.decode(AgentChatRequest.self, from: WireJSON.encode(request)), request)
        }
    }

    func testQuestionMetadataCountsAgainstTranscriptAndQueueIsBounded() throws {
        let form = AgentQuestionnaire(questions: [.init(id: "q", title: "Choose", options: [.init(label: "A", description: String(repeating: "x", count: 8000))])])
        let item = AgentChatItem(kind: .approval, text: "Questions", isComplete: false, questionnaire: form)
        XCTAssertGreaterThan(item.transcriptByteCount, 8000)
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, items: [item])
        XCTAssertNoThrow(try snapshot.validate())
        snapshot.queuedPrompts = (0..<17).map { _ in
            AgentQueuedPrompt(prompt: .init(text: "Hello", model: nil, effort: nil, provider: .codex, planMode: false))
        }
        XCTAssertThrowsError(try snapshot.validate())
    }
}
