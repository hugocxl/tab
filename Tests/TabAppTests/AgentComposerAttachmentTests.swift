import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TabApp

final class AgentAttachmentImporterTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testBinaryFilePreservesNameAndBytesWithoutRetainingClientPath() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("notes with spaces.bin")
        let bytes = Data([0, 255, 2, 0, 128])
        try bytes.write(to: file)
        let attachments = try await AgentAttachmentImporter.load(urls: [file])
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachment.name, file.lastPathComponent)
        XCTAssertEqual(attachment.data, bytes)
        XCTAssertFalse(attachment.name.contains(directory.path))
        XCTAssertFalse(attachment.mimeType.isEmpty)
        XCTAssertNil(attachment.thumbnail)
    }

    func testDirectoriesAndSymlinksAreRejected() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("original.txt")
        try Data("text".utf8).write(to: file)
        let link = directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for url in [directory, link] {
            do {
                _ = try await AgentAttachmentImporter.load(urls: [url])
                XCTFail("Expected rejection of \(url.lastPathComponent)")
            } catch AgentAttachmentImportError.notRegularFile { } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExactByteLimitIsAcceptedAndOneExtraByteRejected() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("bounded.bin")
        try Data(repeating: 42, count: 16).write(to: file)
        let attachments = try await AgentAttachmentImporter.load(urls: [file], maximumFileSize: 16)
        XCTAssertEqual(attachments.first?.data.count, 16)
        try Data(repeating: 42, count: 17).write(to: file)
        do {
            _ = try await AgentAttachmentImporter.load(urls: [file], maximumFileSize: 16)
            XCTFail("Expected a size-limit error")
        } catch AgentAttachmentImportError.tooLarge { }
    }

    func testBatchCountLimitIsCheckedBeforeOpeningFiles() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/attachment.bin")
        do {
            _ = try await AgentAttachmentImporter.load(urls: Array(repeating: missing, count: AgentAttachmentImporter.maximumFileCount + 1))
            XCTFail("Expected a count-limit error")
        } catch AgentAttachmentImportError.tooManyFiles { }
    }

    func testBatchBytesLimitIsEnforced() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("batch.bin")
        try Data(repeating: 0, count: AgentAttachmentImporter.maximumFileSize).write(to: file)
        do {
            _ = try await AgentAttachmentImporter.load(urls: Array(repeating: file, count: 2))
            XCTFail("Expected a batch-size error")
        } catch AgentAttachmentImportError.batchTooLarge { }
    }

    func testTIFFClipboardImageBecomesPNGWithThumbnail() throws {
        let data = try imageData(type: .tiff)
        let attachment = try AgentAttachmentImporter.fromImage(data: data, mimeType: "image/tiff")
        XCTAssertEqual(attachment.name, "Pasted image.png")
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.data.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        XCTAssertNotNil(attachment.thumbnail)
    }

    func testPNGStaysByteForByteIntactAndInvalidImageFails() throws {
        let data = try imageData(type: .png)
        let attachment = try AgentAttachmentImporter.fromImage(data: data, mimeType: "image/png")
        XCTAssertEqual(attachment.data, data)
        XCTAssertNotNil(attachment.thumbnail)
        XCTAssertThrowsError(try AgentAttachmentImporter.fromImage(data: Data("not an image".utf8), mimeType: "image/png"))
        XCTAssertThrowsError(try AgentAttachmentImporter.fromImage(data: data, mimeType: "application/octet-stream"))
    }

    func testPastedImageIsBoundedBeforeDecoding() {
        XCTAssertThrowsError(try AgentAttachmentImporter.fromImage(
            data: Data(repeating: 0, count: AgentAttachmentImporter.maximumFileSize + 1), mimeType: "image/png"
        )) { error in
            guard case AgentAttachmentImportError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLazyPreviewDownsamplesWithoutChangingDraftThumbnail() async throws {
        let data = try imageData(type: .png, width: 2400, height: 1200)
        let draft = try AgentAttachmentImporter.fromImage(data: data, mimeType: "image/png")
        let preview = await AgentAttachmentImporter.previewImage(data: data)
        let image = try XCTUnwrap(preview)
        XCTAssertEqual(image.size.width, 1200)
        XCTAssertEqual(image.size.height, 600)
        XCTAssertEqual(draft.thumbnail?.size.width, 128)
        XCTAssertEqual(draft.data, data)
    }

    func testLazyPreviewRejectsInvalidAndOversizedBytes() async {
        let invalid = await AgentAttachmentImporter.previewImage(data: Data("not an image".utf8))
        let empty = await AgentAttachmentImporter.previewImage(data: Data())
        let oversized = await AgentAttachmentImporter.previewImage(data: Data(repeating: 0, count: AgentAttachmentImporter.maximumFileSize + 1))
        XCTAssertNil(invalid)
        XCTAssertNil(empty)
        XCTAssertNil(oversized)
    }

    private func imageData(type: UTType, width: Int = 4, height: Int = 3) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
final class AgentAttachmentPasteboardTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { Task { @MainActor in board.releaseGlobally() } }
        return board
    }

    func testFinderFilesTakePriorityOverImageAndTextRepresentations() {
        let board = pasteboard()
        let url = URL(fileURLWithPath: "/Users/example/private file.png")
        board.writeObjects([url as NSURL])
        board.setData(Data([1, 2, 3]), forType: .png)
        board.setString(url.path, forType: .string)
        guard case .files(let urls) = AgentAttachmentPasteboard.payload(board) else { return XCTFail("Expected file payload") }
        XCTAssertEqual(urls, [url])
        XCTAssertTrue(AgentAttachmentPasteboard.canRead(board))
    }

    func testClipboardImagesExposeTheirMIMEAndDoNotDecodeOnMainThread() {
        for (type, mime) in [(NSPasteboard.PasteboardType.png, "image/png"), (.tiff, "image/tiff")] {
            let board = pasteboard()
            let bytes = Data([1, 2, 3])
            board.setData(bytes, forType: type)
            guard case .image(let data, let actualMIME) = AgentAttachmentPasteboard.payload(board) else { return XCTFail("Expected image") }
            XCTAssertEqual(data, bytes)
            XCTAssertEqual(actualMIME, mime)
        }
    }

    func testPlainTextAndWebURLsAreNotAttachments() {
        let board = pasteboard()
        board.setString("A plain draft", forType: .string)
        XCTAssertNil(AgentAttachmentPasteboard.payload(board))
        XCTAssertFalse(AgentAttachmentPasteboard.canRead(board))
        board.clearContents()
        board.writeObjects([NSURL(string: "https://example.com/image.png")!])
        XCTAssertNil(AgentAttachmentPasteboard.payload(board))
    }

    func testTextViewAttachmentRoutingDoesNotModifyDraftOrCallOnEdit() {
        let textView = AgentComposerTextView(frame: .zero)
        textView.string = "Keep my draft"
        var files: [URL] = []
        var edits = 0
        textView.onAttachFiles = { files = $0 }
        textView.onEdit = { edits += 1 }
        let board = pasteboard()
        let url = URL(fileURLWithPath: "/Users/example/report.pdf")
        board.writeObjects([url as NSURL])
        XCTAssertTrue(textView.receiveAttachment(from: board))
        XCTAssertEqual(files, [url])
        XCTAssertEqual(textView.string, "Keep my draft")
        XCTAssertEqual(edits, 0)
        XCTAssertTrue(textView.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(textView.registeredDraggedTypes.contains(.png))
        XCTAssertTrue(textView.registeredDraggedTypes.contains(.tiff))
    }

    func testRecognizedFilesNeverFallBackToInsertingAPathWithoutHandler() {
        let textView = AgentComposerTextView(frame: .zero)
        let board = pasteboard()
        board.writeObjects([URL(fileURLWithPath: "/Users/example/secret.txt") as NSURL])
        XCTAssertTrue(textView.receiveAttachment(from: board))
        XCTAssertEqual(textView.string, "")
    }

    func testStripHasFixedHeightAndAccessibleRemoval() throws {
        let strip = AgentAttachmentStrip(frame: NSRect(x: 0, y: 0, width: 280, height: 76))
        let attachments = (0..<3).map { AgentDraftAttachment(id: "\($0)", name: "Document \($0).txt", mimeType: "text/plain", data: Data("hello".utf8)) }
        var removed: String?
        strip.onRemove = { removed = $0 }
        strip.update(attachments, theme: .shared)
        strip.layoutSubtreeIfNeeded()
        XCTAssertTrue(strip.hasAttachments)
        XCTAssertEqual(strip.intrinsicContentSize.height, 76)
        let scroll = try XCTUnwrap(strip.subviews.first as? NSScrollView)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.width, strip.bounds.width)
        let remove = try XCTUnwrap(descendants(strip).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Remove Document 0.txt" })
        remove.performClick(nil)
        XCTAssertEqual(removed, "0")
        strip.update([], theme: .shared)
        XCTAssertFalse(strip.hasAttachments)
        XCTAssertEqual(strip.intrinsicContentSize.height, 0)
    }

    func testStripZeroAndTinyLayoutsNeverProduceNegativeFrameSizes() {
        let strip = AgentAttachmentStrip(frame: .zero)
        strip.update([AgentDraftAttachment(name: "Small.txt", mimeType: "text/plain", data: Data())], theme: .shared)
        for size in [NSSize.zero, NSSize(width: 1, height: 1), NSSize(width: 280, height: 76), .zero] {
            strip.frame.size = size
            strip.needsLayout = true
            strip.layoutSubtreeIfNeeded()
            for view in descendants(strip) {
                XCTAssertGreaterThanOrEqual(view.frame.size.width, 0)
                XCTAssertGreaterThanOrEqual(view.frame.size.height, 0)
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
