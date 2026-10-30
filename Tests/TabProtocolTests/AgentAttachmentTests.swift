import Foundation
import TabProtocol
import XCTest

final class AgentAttachmentTests: XCTestCase {
    func testAttachmentOnlySendAndLegacySendRoundTrip() throws {
        let attachment = AgentChatAttachment(name: "remote.png", mimeType: "image/png", data: Data([0, 1, 255]))
        let request = AgentChatRequest.send(session: SessionId(), text: "", model: nil, attachments: [attachment])
        try request.validate()
        XCTAssertEqual(try WireJSON.decode(AgentChatRequest.self, from: WireJSON.encode(request)), request)
        let legacy = Data("{\"send\":{\"session\":\"\(SessionId())\",\"text\":\"hello\"}}".utf8)
        let decoded = try WireJSON.decode(AgentChatRequest.self, from: legacy)
        if case .send(_, _, _, _, _, let attachments) = decoded { XCTAssertNil(attachments) }
        else { XCTFail("Expected legacy send") }
    }

    func testBoundedPayloadsAndMetadata() throws {
        let max = AgentChatAttachment(name: "image.png", mimeType: "image/png",
                                      data: Data(repeating: 255, count: AgentChatAttachment.maxFileBytes))
        let second = AgentChatAttachment(name: "two.png", mimeType: "image/png", data: max.data)
        let request = AgentChatRequest.send(session: SessionId(), text: "", model: nil, attachments: [max])
        try request.validate()
        let frame = try WireJSON.encode(Message.request(RequestId(1), .agentChat(request)))
        XCTAssertLessThan(frame.count, Limits.maxFrame)
        var oversized = max
        oversized.data.append(0)
        XCTAssertThrowsError(try AgentChatAttachment.validate([oversized]))
        XCTAssertThrowsError(try AgentChatAttachment.validate([max, second,
            .init(name: "extra", mimeType: "text/plain", data: Data([1]))]))
        XCTAssertThrowsError(try AgentChatAttachment.validate([max, max]))
        XCTAssertThrowsError(try AgentChatAttachment.validate(Array(repeating:
            .init(name: "x", mimeType: "text/plain", data: Data()), count: AgentChatAttachment.maxCount + 1)))
        XCTAssertThrowsError(try AgentChatAttachment.validate([
            .init(name: "bad\nname", mimeType: "text/plain", data: Data())]))
    }

    func testTranscriptRetainsMetadataWithoutPayload() throws {
        let file = AgentChatAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("secret payload".utf8))
        let item = AgentChatItem(kind: .user, text: "Read this", attachments: [file.descriptor])
        let encoded = try WireJSON.encode(item)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(file.data.base64EncodedString()))
        XCTAssertFalse(json.contains("secret payload"))
        XCTAssertEqual(try WireJSON.decode(AgentChatItem.self, from: encoded).attachments, [file.descriptor])
        XCTAssertGreaterThan(item.transcriptByteCount, item.text.utf8.count)
        let legacy = Data("{\"id\":\"old\",\"kind\":\"user\",\"text\":\"hello\",\"isComplete\":true}".utf8)
        XCTAssertNil(try WireJSON.decode(AgentChatItem.self, from: legacy).attachments)
    }
}
