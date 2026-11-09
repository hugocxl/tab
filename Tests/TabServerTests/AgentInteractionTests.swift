import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentInteractionTests: XCTestCase {
    func testInboxDeduplicatesOriginalAcceptanceEvenAfterEditAndCompletion() throws {
        let prompt = AgentPrompt(text: "Original", model: nil, effort: nil, provider: .codex, planMode: false)
        var inbox = AgentPromptInbox()
        try inbox.submit(prompt)
        inbox.records[0].prompt?.text = "Edited"
        inbox.records[0].display?.text = "Edited"
        try inbox.submit(prompt)
        XCTAssertEqual(inbox.visible.count, 1)
        XCTAssertEqual(inbox.records[0].prompt?.text, "Edited")
        inbox.records[0].prompt = nil; inbox.records[0].display = nil
        try inbox.submit(prompt)
        XCTAssertTrue(inbox.visible.isEmpty)
        var collision = prompt; collision.text = "Different"
        XCTAssertThrowsError(try inbox.submit(collision))
    }

    func testRecoveryRetainsAttachmentsAndRequiresReviewOfInterruptedDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let attachment = AgentChatAttachment(name: "note.txt", mimeType: "text/plain", data: Data("Keep me".utf8))
        let prompt = AgentPrompt(text: "Review", model: nil, effort: nil, provider: .claude, planMode: false, attachments: [attachment])
        var inbox = AgentPromptInbox(); try inbox.submit(prompt)
        inbox.records[0].display?.state = .delivering
        try inbox.save(file)
        let recovered = try AgentPromptInbox.load(file)
        XCTAssertTrue(recovered.paused)
        XCTAssertEqual(recovered.visible.first?.state, .uncertain)
        XCTAssertEqual(recovered.records.first?.prompt?.attachments, [attachment])
        XCTAssertThrowsError(try recovered.index(prompt.id, revision: 0))
        XCTAssertEqual(try recovered.index(prompt.id, revision: 1), 0)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testQuestionValidationRejectsMissingRequiredUnknownAndDuplicateQuestions() throws {
        let form = AgentQuestionnaire(questions: [.init(id: "choice", title: "Choose", options: [.init(label: "A")]), .init(id: "note", title: "Anything else?", required: false)])
        XCTAssertNoThrow(try form.validate(answers: ["choice": ["Custom answer"]], cancelled: false))
        XCTAssertThrowsError(try form.validate(answers: [:], cancelled: false))
        XCTAssertThrowsError(try form.validate(answers: ["choice": ["A", "B"]], cancelled: false))
        XCTAssertThrowsError(try form.validate(answers: ["foreign": ["A"]], cancelled: false))
        XCTAssertNoThrow(try form.validate(answers: [:], cancelled: true))
        XCTAssertThrowsError(try AgentQuestionnaire(questions: [form.questions[0], form.questions[0]]).validate())
    }

    func testCodexQuestionsPreserveRPCIDAndKeepSecretAnswersOutOfTranscript() async throws {
        let recorder = AgentRuntimeRecorder()
        let waiting = expectation(description: "form presented")
        let idle = expectation(description: "turn completed")
        recorder.observe = { event in
            if case .status(.waiting) = event { waiting.fulfill() }
            if case .status(.idle) = event { idle.fulfill() }
        }
        let fixture = try AgentRuntimeFixture(#"""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"turn"}}}'
        emit '{"id":42,"method":"item/tool/requestUserInput","params":{"questions":[{"id":"choice","question":"Pick one","options":[{"label":"A"},{"label":"B"}]},{"id":"secret","question":"Secret","isSecret":true}]}}'
        take
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn","status":"completed"}}}'
        hold
        """#)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.setAccess(.fullAccess)
        try await runtime.send(text: "Ask me", model: nil)
        await fulfillment(of: [waiting], timeout: 5)
        let form = try XCTUnwrap(recorder.transcript["42"]?.questionnaire)
        XCTAssertEqual(form.questions.count, 2)
        XCTAssertTrue(form.questions[1].secret)
        XCTAssertFalse(try fixture.messages().contains { ($0["id"] as? Int) == 42 })
        try await runtime.answer(request: "42", answers: ["choice": ["B"], "secret": ["never-persist-this"]], cancelled: false)
        try await runtime.answer(request: "42", answers: ["choice": ["B"], "secret": ["never-persist-this"]], cancelled: false)
        await fulfillment(of: [idle], timeout: 5)
        let responses = try fixture.messages().filter { ($0["id"] as? Int) == 42 }
        XCTAssertEqual(responses.count, 1)
        let answers = (responses.first?["result"] as? [String: Any])?["answers"] as? [String: [String: [String]]]
        XCTAssertEqual(answers?["choice"]?["answers"], ["B"])
        XCTAssertEqual(answers?["secret"]?["answers"], ["never-persist-this"])
        XCTAssertFalse(recorder.transcript.values.contains { $0.text.contains("never-persist-this") || $0.detail?.contains("never-persist-this") == true })
    }
}
