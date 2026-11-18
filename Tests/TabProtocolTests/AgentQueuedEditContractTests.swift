import Foundation
import XCTest
@testable import TabProtocol

final class AgentQueuedEditContractTests: XCTestCase {
    func testWholePromptEditRoundTripsAndValidates() throws {
        let session = SessionId(), id = UUID().uuidString
        let added = AgentChatAttachment(name: "Shot.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let request = AgentChatRequest.editQueuedPrompt(session: session, id: id, expectedRevision: 3, edit: .init(
            text: "", settings: .init(model: "m", effort: .high, planMode: true), keptAttachments: ["a"], addedAttachments: [added]))
        try request.validate()
        XCTAssertEqual(try WireJSON.decode(AgentChatRequest.self, from: WireJSON.encode(request)), request)
        // Nothing left to send, a repeated attachment, or a kept ID that collides with an added one.
        for edit in [AgentQueuedEdit(text: "  "), .init(text: "x", keptAttachments: ["a", "a"]),
                     .init(text: "x", keptAttachments: [added.id], addedAttachments: [added]),
                     .init(text: String(repeating: "x", count: 64 * 1024 + 1))] {
            XCTAssertThrowsError(try AgentChatRequest.editQueuedPrompt(session: session, id: id, expectedRevision: 0, edit: edit).validate())
        }
        XCTAssertThrowsError(try AgentChatRequest.editQueuedPrompt(session: session, id: "not-a-uuid", expectedRevision: 0,
                                                                  edit: .init(text: "x")).validate())
    }

    /// A server that predates the request can't decode it, answers `unsupported`, and so
    /// leaves the queued prompt untouched rather than applying only its text.
    func testOlderServersSeeTheEditAsAnUnknownRequest() throws {
        let request = Message.request(RequestId(7), .agentChat(.editQueuedPrompt(session: SessionId(), id: UUID().uuidString,
                                                                                  expectedRevision: 0, edit: .init(text: "x"))))
        let json = try XCTUnwrap(String(data: WireJSON.encode(request), encoding: .utf8))
        XCTAssertTrue(json.contains("editQueuedPrompt"))
        let older = json.replacingOccurrences(of: "editQueuedPrompt", with: "someFutureRequest")
        guard case .request(let id, let body) = try WireJSON.decode(Message.self, from: Data(older.utf8)) else {
            return XCTFail("Expected a request")
        }
        XCTAssertEqual(id, RequestId(7))
        guard case .unknown = body else { return XCTFail("An undecodable agent request must be unknown, not partially applied") }
    }
}
