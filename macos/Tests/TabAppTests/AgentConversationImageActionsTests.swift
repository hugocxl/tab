import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationImageActionsTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    private func surface() -> AgentPaneView {
        let surface = AgentPaneView()
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 1, items: [
            .init(id: "user", kind: .user, text: "See attached", attachments: [
                .init(id: "notes", name: "notes.txt", mimeType: "text/plain", byteCount: 5),
                .init(id: "image", name: "attached.png", mimeType: "image/png", byteCount: png.count)]),
            .init(id: "other", kind: .user, text: "Another message", attachments: [
                .init(id: "foreign", name: "foreign.png", mimeType: "image/png", byteCount: png.count)]),
        ]))
        return surface
    }

    func testAttachmentsOpenOnlyFromTheirOwningRetainedMessage() async throws {
        let surface = surface()
        var opened: [(String, String, Bool)] = []
        surface.onOpenAttachment = { item, attachment, download in opened.append((item, attachment.id, download)) }
        var fetched: [String] = []
        surface.fetchAttachment = { item, attachment in fetched.append(item + "/" + attachment.id); return self.png }
        try surface.actions.openAttachment(itemID: "user", attachmentID: "image")
        try surface.actions.downloadAttachment(itemID: "user", attachmentID: "notes")
        XCTAssertEqual(opened.map(\.0), ["user", "user"])
        XCTAssertEqual(opened.map(\.1), ["image", "notes"])
        XCTAssertEqual(opened.map(\.2), [false, true])
        let data = try await surface.actions.loadAttachment(itemID: "user", attachmentID: "image")
        XCTAssertEqual(data, png)
        XCTAssertEqual(fetched, ["user/image"])

        XCTAssertThrowsError(try surface.actions.openAttachment(itemID: "user", attachmentID: "foreign"))
        XCTAssertThrowsError(try surface.actions.downloadAttachment(itemID: "gone", attachmentID: "image"))
        do {
            _ = try await surface.actions.loadAttachment(itemID: "other", attachmentID: "image")
            XCTFail("An attachment cannot be loaded through another message")
        } catch {}
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(fetched.count, 1)
    }

    func testImagePreviewIndexesOnlyTheMessagesImages() throws {
        let surface = surface()
        var previews: [(String, [String], Int)] = []
        surface.onPreviewAttachments = { item, images, index in previews.append((item, images.map(\.id), index)) }
        try surface.actions.previewImages(itemID: "user", index: 0)
        try surface.actions.expandImage(itemID: "user", attachmentID: "image")
        XCTAssertEqual(previews.map(\.1), [["image"], ["image"]])
        XCTAssertEqual(previews.map(\.2), [0, 0])
        XCTAssertThrowsError(try surface.actions.previewImages(itemID: "user", index: 1))
        XCTAssertThrowsError(try surface.actions.expandImage(itemID: "user", attachmentID: "notes"))
        XCTAssertThrowsError(try surface.actions.expandImage(itemID: "user", attachmentID: "foreign"))
        XCTAssertEqual(previews.count, 2)
    }

    func testRetainedAttachmentImageCopiesAsPNG() async throws {
        let surface = surface()
        surface.fetchAttachment = { _, _ in self.png }
        let actions = AgentImageActions(name: "attached.png")
        actions.fetch = { [weak surface] in
            guard let surface else { throw CancellationError() }
            return try await surface.actions.loadAttachment(itemID: "user", attachmentID: "image")
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try await actions.copy(to: board)
        XCTAssertEqual(board.data(forType: .png), png)
    }
}
