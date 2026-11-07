import TabProtocol
import XCTest
@testable import TabMobileKit

final class AgentDraftAttachmentsTests: XCTestCase {
    private func file(_ bytes: Int, name: String = "a.txt") -> AgentChatAttachment {
        AgentChatAttachment(name: name, mimeType: "text/plain", data: Data(count: bytes))
    }

    /// The server rejects images other than PNG, JPEG, GIF and WebP, so
    /// photos from the library (HEIC) must be converted first.
    func testOnlyImagesTheServerRejectsAreConverted() {
        XCTAssertEqual(AgentDraftAttachments.mimeType(forFilename: "IMG_0001.HEIC"), "image/heic")
        XCTAssertTrue(AgentDraftAttachments.needsConversion(mimeType: "image/heic"))
        XCTAssertFalse(AgentDraftAttachments.needsConversion(mimeType: "image/PNG"))
        XCTAssertFalse(AgentDraftAttachments.needsConversion(mimeType: "application/pdf"))
        XCTAssertEqual(AgentDraftAttachments.mimeType(forFilename: "notes"), "application/octet-stream")
    }

    /// A draft the server would refuse is stopped before it's sent.
    func testDraftStaysWithinTheServerLimits() {
        let max = AgentChatAttachment.maxTotalBytes
        XCTAssertNil(AgentDraftAttachments.problem(adding: file(max / 2), to: [file(max / 2)]))
        XCTAssertNotNil(AgentDraftAttachments.problem(adding: file(max / 2 + 1), to: [file(max / 2)]))
        XCTAssertNotNil(AgentDraftAttachments.problem(adding: file(AgentChatAttachment.maxFileBytes + 1), to: []))
        let full = (0..<AgentChatAttachment.maxCount).map { _ in file(1) }
        XCTAssertNotNil(AgentDraftAttachments.problem(adding: file(1), to: full))
    }
}
