import AppKit
import PDFKit
import XCTest
@testable import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class AgentFileAttachmentTests: XCTestCase {
    private let files = [
        AgentChatAttachmentDescriptor(id: "pdf", name: "Design review.pdf", mimeType: "application/pdf", byteCount: 48_000),
        AgentChatAttachmentDescriptor(id: "notes", name: "Implementation notes.md", mimeType: "text/markdown", byteCount: 1_200),
    ]

    func testStandaloneCardsAndInlineRowsKeepActionsAndCorrectOrdering() throws {
        _ = NSApplication.shared
        let row = AgentMessageRow(frame: .zero)
        var actions: [(String, String, Bool)] = []
        row.onOpenAttachment = { actions.append(($0, $1.id, $2)) }
        row.update([AgentChatItem(id: "message", kind: .user, text: "", attachments: files)])
        place(row)
        let cards = row.subviews.compactMap { $0 as? AgentFileAttachmentCard }
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(cards.allSatisfy(\.standalone))
        XCTAssertEqual(cards[0].frame.size, NSSize(width: 256, height: 52))
        XCTAssertEqual(cards[1].frame.minY - cards[0].frame.maxY, 4)
        XCTAssertTrue(try XCTUnwrap(row.subviews.first { $0 is ThemedBackground }).isHidden)
        XCTAssertEqual(row.frame.height, 136)
        cards[0].preview.perform(); cards[1].download.perform()
        XCTAssertEqual(actions.map { $0.0 }, ["message", "message"])
        XCTAssertEqual(actions.map { $0.1 }, ["pdf", "notes"])
        XCTAssertEqual(actions.map { $0.2 }, [false, true])
        row.update([AgentChatItem(id: "message", kind: .user, text: "Review these documents.", attachments: files)])
        place(row)
        XCTAssertTrue(cards.allSatisfy { !$0.standalone })
        XCTAssertEqual(cards[0].frame.height, 32)
        let body = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentResponseView }.first)
        XCTAssertGreaterThanOrEqual(body.frame.minY - cards[1].frame.maxY, 8)
    }

    func testFileSizeFormattingMatchesSourceIncludingRoundedUnitBoundary() {
        XCTAssertEqual(AgentFileAttachmentCard.formatBytes(0), "0 B")
        XCTAssertEqual(AgentFileAttachmentCard.formatBytes(1023), "1023 B")
        XCTAssertEqual(AgentFileAttachmentCard.formatBytes(1024), "1.00 KB")
        XCTAssertEqual(AgentFileAttachmentCard.formatBytes(48_000), "46.9 KB")
        XCTAssertEqual(AgentFileAttachmentCard.formatBytes(1_048_166), "1.00 MB")
    }

    func testTextPreviewLimitAndBinaryDetectionMatchBoundedSourceBehavior() {
        let descriptor = AgentChatAttachmentDescriptor(id: "text", name: "large.txt", mimeType: "text/plain", byteCount: AgentFilePreviewPayload.textLimit + 1)
        let data = Data(repeating: 97, count: descriptor.byteCount)
        let payload = AgentFilePreviewPayload.decode(data, attachment: descriptor)
        XCTAssertTrue(payload.truncated)
        XCTAssertEqual(payload.text?.utf8.count, 1024 * 1024)
        XCTAssertNil(AgentFilePreviewPayload.decode(Data([0, 1, 2]), attachment: descriptor).text)
    }

    func testMarkdownPreviewRetrySourceToggleAndExactCopy() async throws {
        let restoreClipboard = preserveAgentTestClipboard()
        defer { restoreClipboard() }
        let source = "# Review\n\nPreserve **formatting** and [links](https://example.com)."
        let data = Data(source.utf8)
        let attachment = AgentChatAttachmentDescriptor(id: "md", name: "review.md", mimeType: "text/markdown", byteCount: data.count)
        var fail = true
        let window = AgentFilePreviewWindow(item: "message", attachment: attachment, fetch: { _, _ in
            if fail { throw ModelError("Offline") }; return data
        }, theme: AppTheme(systemIsDark: false))
        defer { window.close() }
        try await wait { !window.content.retry.isHidden }
        XCTAssertTrue(window.content.notice.stringValue.contains("Offline"))
        fail = false; window.content.retry.perform()
        try await wait { window.content.copy.isEnabled }
        XCTAssertTrue(window.content.scroll.documentView === window.content.markdown)
        window.content.rendered.perform()
        XCTAssertTrue(window.content.scroll.documentView === window.content.text)
        XCTAssertEqual(window.content.text.string, source)
        window.content.copy.perform()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), source)
        window.content.wrap.perform()
        XCTAssertEqual(window.content.wrap.title, "Wrap lines")
    }

    func testOpenPreviewThemeChangeRefreshesSourceAndRenderedTextWithoutLosingSelection() throws {
        let source = "# Preview\n\nPreserve selected text."
        let descriptor = AgentChatAttachmentDescriptor(id: "notes", name: "notes.md", mimeType: "text/markdown", byteCount: source.utf8.count)
        let view = AgentFilePreviewView(frame: .zero)
        view.show(.init(text: source), attachment: descriptor)
        view.rendered.perform()
        view.wrap.perform()
        let selection = NSRange(location: 2, length: 7)
        view.text.setSelectedRange(selection)
        let scheme = ColorScheme(background: RGBColor(0x102030), foreground: RGBColor(0xD0E0F0))
        let theme = AppTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Preview", scheme: scheme)]), darkTheme: "Preview", systemIsDark: true)
        view.theme = theme
        view.themeDidChange()
        XCTAssertTrue(view.scroll.documentView === view.text)
        XCTAssertEqual(view.text.selectedRange(), selection)
        XCTAssertEqual(view.wrap.title, "Wrap lines")
        XCTAssertEqual(view.text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, theme.fg)
        let response = try XCTUnwrap(view.markdown.subviews.flatMap(\.subviews).compactMap { $0 as? AgentRichTextView }.first)
        XCTAssertEqual(response.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, theme.fg)
    }

    func testPDFUsesNativeDocumentPreview() async throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 240, height: 320))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 240, height: 320).fill(); image.unlockFocus()
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let attachment = AgentChatAttachmentDescriptor(id: "pdf", name: "review.pdf", mimeType: "application/pdf", byteCount: data.count)
        let window = AgentFilePreviewWindow(item: "message", attachment: attachment, fetch: { _, _ in data }, theme: AppTheme(systemIsDark: false))
        defer { window.close() }
        try await wait { window.content.pdf.document != nil }
        XCTAssertEqual(window.content.pdf.document?.pageCount, 1)
        XCTAssertFalse(window.content.pdf.isHidden)
        XCTAssertFalse(window.content.copy.isEnabled)
        XCTAssertTrue(window.content.save.isEnabled)
    }

    func testFileCardSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let background = ThemedBackground(color: { $0.card })
            background.theme = theme
            background.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var y: CGFloat = 12
            for text in ["", "Review these documents and compare the proposed changes."] {
                let row = AgentMessageRow(frame: .zero)
                row.theme = theme
                row.update([AgentChatItem(id: UUID().uuidString, kind: .user, text: text, attachments: files)])
                place(row); row.setFrameOrigin(NSPoint(x: 12, y: y))
                background.addSubview(row)
                y += row.frame.height + 12
            }
            background.frame = NSRect(x: 0, y: 0, width: 624, height: y)
            background.themeDidChange(); background.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
            background.cacheDisplay(in: background.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "/file-cards-\(dark ? "dark" : "light").png"))
        }
    }
    private func place(_ row: AgentMessageRow) { row.frame = NSRect(x: 0, y: 0, width: 600, height: row.preferredHeight(for: 600)); row.layoutRow(width: 600) }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out waiting for file preview")
    }
}
