import AppKit
import WebKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentHtmlDocumentCardTests: XCTestCase {
    private let html = Data("<!doctype html><html><head><title> Quarterly  Report </title></head><body>Hello</body></html>".utf8)
    private let renderOutput = #"{"htmlRender":{"attachmentId":"html"}}"#
    private let mcpOutput = #"{"tabMcpApp":{"attachmentId":"html","server":"weather","tool":"show","resourceUri":"ui://weather/show"}}"#

    private func attachment(_ bytes: Data? = nil, mime: String = "text/html") -> AgentChatAttachmentDescriptor {
        .init(id: "html", name: "doc.html", mimeType: mime, byteCount: (bytes ?? html).count)
    }

    private func renderItem(complete: Bool = true, status: AgentToolActivity.Status = .completed, id: String = "tool") -> AgentChatItem {
        var activity = AgentToolActivity(name: "html_render", output: renderOutput, status: status, presentation: .dynamicTool)
        activity.outputIsJSON = true
        return .init(id: id, kind: .tool, text: "html_render", isComplete: complete, tool: activity, attachments: [attachment()])
    }

    private func mcpItem() -> AgentChatItem {
        var activity = AgentToolActivity(name: "weather.show", output: mcpOutput, status: .completed, presentation: .dynamicTool)
        activity.outputIsJSON = true
        return .init(id: "mcp", kind: .tool, text: "weather.show", tool: activity, attachments: [attachment()])
    }

    private func surface(_ items: [AgentChatItem]) -> AgentPaneView {
        let surface = AgentPaneView()
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 1, items: items))
        surface.fetchAttachment = { _, _ in self.html }
        // The web view loads without its window on screen, and macOS would pull a titled window into view.
        surface.actions.presentWindow = { _ in }
        return surface
    }

    private func row(_ item: AgentChatItem, expanded: Bool = true, fetch: AgentAttachmentCache.Fetch? = nil) -> AgentToolDisclosure {
        let row = AgentToolDisclosure(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        row.fetchAttachment = fetch ?? { _, _ in self.html }
        row.update(item, expanded: expanded, theme: AppTheme.shared)
        return row
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Reference

    func testReferenceFoundForHtmlRenderAndMcpItems() throws {
        let render = try XCTUnwrap(AgentHtmlDocumentReference.find(in: renderItem()))
        XCTAssertEqual(render.attachmentID, "html")
        XCTAssertEqual(render.toolName, "html_render")
        XCTAssertFalse(render.isMcpApp)
        let mcp = try XCTUnwrap(AgentHtmlDocumentReference.find(in: mcpItem()))
        XCTAssertTrue(mcp.isMcpApp)
        XCTAssertEqual([mcp.server, mcp.tool], ["weather", "show"])
        XCTAssertEqual(mcp.fallbackTitle, "weather.show")
    }

    func testReferenceIsNilForUnrelatedItems() {
        var other = renderItem(); other.tool?.output = #"{"result":"ok"}"#
        var wrongTool = mcpItem(); wrongTool.tool?.name = "other.show"
        var notHTML = renderItem(); notHTML.attachments = [attachment(mime: "text/plain")]
        var missing = renderItem(); missing.attachments = []
        var user = renderItem(); user.kind = .user
        for item in [other, wrongTool, notHTML, missing, user, .init(kind: .tool, text: "Read")] {
            XCTAssertNil(AgentHtmlDocumentReference.find(in: item))
        }
    }

    // MARK: Title

    func testTitleParsingCollapsesWhitespaceAndEntities() {
        XCTAssertEqual(AgentHtmlDocumentReference.title(in: html), "Quarterly Report")
        XCTAssertEqual(AgentHtmlDocumentReference.title(in: Data("<TITLE lang=en>A &amp; B\n&lt;c&gt;</TITLE>".utf8)), "A & B <c>")
    }

    func testTitleIsNilWithoutTitleOrWhenEmpty() {
        XCTAssertNil(AgentHtmlDocumentReference.title(in: Data("<html><body>No title</body></html>".utf8)))
        XCTAssertNil(AgentHtmlDocumentReference.title(in: Data("<title>  </title>".utf8)))
        XCTAssertNil(AgentHtmlDocumentReference.title(in: Data("<title>unterminated".utf8)))
    }

    func testTitleReadIsBoundedToTheFirst64KiB() {
        let padding = String(repeating: " ", count: 64 * 1024)
        XCTAssertNil(AgentHtmlDocumentReference.title(in: Data((padding + "<title>Late</title>").utf8)))
        XCTAssertEqual(AgentHtmlDocumentReference.title(in: Data(("<title>Early</title>" + padding).utf8)), "Early")
    }

    // MARK: Card in tool rows

    func testCardAppearsForHtmlRenderAndMcpButNotUnrelatedRows() {
        XCTAssertTrue(row(renderItem()).showsHTMLDocument)
        XCTAssertTrue(row(mcpItem()).showsHTMLDocument)
        var plain = renderItem(); plain.tool?.output = #"{"result":"ok"}"#
        XCTAssertFalse(row(plain).showsHTMLDocument)
        XCTAssertFalse(row(.init(kind: .tool, text: "Read", tool: .init(category: .read, output: "text", status: .completed))).showsHTMLDocument)
        XCTAssertTrue(row(renderItem(), expanded: false).showsHTMLDocument, "The document is visible without expanding the tool call")
        XCTAssertFalse(row(plain, expanded: false).showsHTMLDocument)
    }

    func testCardShowsToolNameThenParsedTitleAndMcpNames() async throws {
        let view = row(renderItem())
        XCTAssertEqual(view.htmlDocumentCard.titleText, "html_render")
        try await waitFor { view.htmlDocumentCard.titleText == "Quarterly Report" }
        XCTAssertEqual(view.htmlDocumentCard.titleText, "Quarterly Report")
        XCTAssertTrue(view.htmlDocumentCard.detailText.contains("HTML document"))
        XCTAssertTrue(view.htmlDocumentCard.detailText.contains(AgentFileAttachmentCard.formatBytes(html.count)))
        let mcp = row(mcpItem(), fetch: { _, _ in Data("<p>no title</p>".utf8) })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(mcp.htmlDocumentCard.titleText, "weather.show")
        XCTAssertTrue(mcp.htmlDocumentCard.detailText.contains("weather · show"))
    }

    func testCardIsDisabledWhileRunningOrWhenNotRetained() {
        let running = row(renderItem(complete: false, status: .running))
        XCTAssertFalse(running.htmlDocumentCard.isAvailable)
        XCTAssertFalse(running.htmlDocumentCard.preview.isEnabled)
        XCTAssertTrue(running.htmlDocumentCard.detailText.contains("Unavailable"))
        let unretained = AgentToolDisclosure(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        unretained.update(renderItem(), expanded: true, theme: AppTheme.shared)
        XCTAssertFalse(unretained.htmlDocumentCard.isAvailable)
        XCTAssertFalse(unretained.htmlDocumentCard.download.isEnabled)
        XCTAssertFalse(unretained.htmlDocumentCard.copy.isEnabled)
        let ready = row(renderItem())
        XCTAssertTrue(ready.htmlDocumentCard.isAvailable)
    }

    func testButtonsReportTheirActionAndDisabledButtonsDoNot() {
        let view = row(renderItem())
        var received: [AgentHtmlDocumentCard.Action] = []
        var references: [AgentHtmlDocumentReference] = []
        view.onHTMLDocument = { action, reference in received.append(action); references.append(reference) }
        view.htmlDocumentCard.preview.performClick(nil)
        view.htmlDocumentCard.download.performClick(nil)
        view.htmlDocumentCard.copy.performClick(nil)
        XCTAssertEqual(received, [.preview, .download, .copySource])
        XCTAssertEqual(Set(references.map(\.attachmentID)), ["html"])
        let disabled = row(renderItem(complete: false, status: .running))
        var count = 0
        disabled.onHTMLDocument = { _, _ in count += 1 }
        disabled.htmlDocumentCard.preview.performClick(nil)
        XCTAssertEqual(count, 0)
    }

    func testCardMeasurementIsStableAndRowsReuseCleanly() {
        let view = row(renderItem())
        let withCard = view.height(for: 600)
        XCTAssertEqual(view.height(for: 600), withCard)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: withCard)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.htmlDocumentCard.frame.height, AgentHtmlDocumentCard.height)
        var plain = renderItem(id: "reused"); plain.tool?.output = #"{"result":"ok"}"#
        view.update(plain, expanded: true, theme: AppTheme.shared)
        XCTAssertFalse(view.showsHTMLDocument)
        XCTAssertEqual(view.height(for: 600), withCard - AgentHtmlDocumentCard.height, accuracy: 60)
        XCTAssertLessThan(view.height(for: 600), withCard)
        view.update(renderItem(id: "again"), expanded: true, theme: AppTheme.shared)
        XCTAssertTrue(view.showsHTMLDocument)
        XCTAssertEqual(view.htmlDocumentCard.reference?.itemID, "again")
    }

    func testCollapsedRowMeasuresAndPlacesTheCardBelowItsHeader() {
        let collapsed = row(renderItem(), expanded: false)
        let height = collapsed.height(for: 600)
        XCTAssertEqual(height, 30 + AgentHtmlDocumentCard.height + 8)
        collapsed.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        collapsed.layoutSubtreeIfNeeded()
        XCTAssertEqual(collapsed.htmlDocumentCard.frame, NSRect(x: 2, y: 30, width: 596, height: AgentHtmlDocumentCard.height))
        var plain = renderItem(id: "plain"); plain.tool?.output = #"{"result":"ok"}"#
        collapsed.update(plain, expanded: false, theme: AppTheme.shared)
        XCTAssertEqual(collapsed.height(for: 600), 30, "A reused collapsed row without a document is only its header")
        collapsed.update(renderItem(id: "back"), expanded: false, theme: AppTheme.shared)
        XCTAssertEqual(collapsed.height(for: 600), height)
        XCTAssertEqual(collapsed.htmlDocumentCard.reference?.itemID, "back")
    }

    func testExpandingKeepsOneCardAboveTheDetail() {
        let view = row(renderItem(), expanded: false)
        let card = view.htmlDocumentCard
        view.update(renderItem(), expanded: true, theme: AppTheme.shared)
        XCTAssertTrue(view.htmlDocumentCard === card)
        XCTAssertEqual(view.subviews.filter { $0 is AgentHtmlDocumentCard }.count, 1)
        let height = view.height(for: 600)
        XCTAssertGreaterThan(height, 30 + AgentHtmlDocumentCard.height + 8)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.frame.minY, 48, "The open card leads the padded result box")
    }

    func testTranscriptActivityRowMeasuresTheCollapsedCard() {
        let row = AgentActivityRow(frame: NSRect(x: 0, y: 0, width: 600, height: 10))
        row.fetchAttachment = { _, _ in self.html }
        row.update([renderItem()])
        XCTAssertEqual(row.preferredHeight(for: 600), 30 + AgentHtmlDocumentCard.height + 8)
        var plain = renderItem(id: "plain"); plain.tool?.output = #"{"result":"ok"}"#
        row.update([plain])
        XCTAssertEqual(row.preferredHeight(for: 600), 30)
    }

    func testCollapsedCardButtonsReachTheirAction() {
        let collapsed = row(renderItem(), expanded: false)
        var actions: [AgentHtmlDocumentCard.Action] = []
        collapsed.onHTMLDocument = { action, reference in
            actions.append(action)
            XCTAssertEqual(reference.attachmentID, "html")
        }
        collapsed.htmlDocumentCard.preview.performClick(nil)
        XCTAssertEqual(actions, [.preview])
    }

    // MARK: Actions and preview window

    func testOpenPreviewServesTheRetainedBytesAsSandboxedHTML() async throws {
        _ = NSApplication.shared
        let surface = surface([renderItem()])
        try await surface.actions.previewHTMLDocument(attachmentID: "html")
        let preview = try XCTUnwrap(surface.actions.htmlPreview)
        defer { preview.close() }
        XCTAssertEqual(preview.mimeType, "text/html")
        XCTAssertEqual(preview.byteCount, UInt64(html.count))
        XCTAssertEqual(preview.window?.title, "Quarterly Report")
        let policy = AgentConversationRangedResource.htmlDocumentPolicy
        XCTAssertTrue(policy.contains("sandbox allow-scripts"))
        XCTAssertFalse(policy.contains("allow-same-origin"))
        XCTAssertTrue(policy.contains("default-src 'none'") && policy.contains("connect-src 'none'"))
        var title: String?
        let deadline = Date().addingTimeInterval(8)
        while title != "Quarterly Report", Date() < deadline {
            title = try? await preview.webView.evaluateJavaScript("document.title") as? String
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(title, "Quarterly Report")
    }

    func testPreviewBlocksNavigationAwayFromTheDocument() async throws {
        _ = NSApplication.shared
        let surface = surface([renderItem()])
        try await surface.actions.previewHTMLDocument(attachmentID: "html")
        let preview = try XCTUnwrap(surface.actions.htmlPreview)
        defer { preview.close() }
        try await waitFor { preview.webView.url != nil && !preview.webView.isLoading }
        preview.webView.load(URLRequest(url: URL(string: "https://example.invalid/")!))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(preview.webView.url?.scheme, "tab-media-preview")
    }

    func testPreviewRefusesAnItemThatIsNoLongerRetained() async throws {
        let surface = surface([renderItem()])
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 2, items: []))
        do {
            try await surface.actions.previewHTMLDocument(attachmentID: "html")
            XCTFail("A document of a removed tool call cannot be previewed")
        } catch {}
        XCTAssertNil(surface.actions.htmlPreview)
    }

    func testCopySourceWritesTheRetainedHTMLText() async throws {
        let surface = surface([mcpItem()])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tab-html-card-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        surface.actions.pasteboard = pasteboard
        try await surface.actions.copyHTMLDocument(attachmentID: "html")
        XCTAssertEqual(pasteboard.string(forType: .string), String(decoding: html, as: UTF8.self))
    }

    func testCardButtonsReachTypedDownloadAndCopyActions() async throws {
        let surface = surface([renderItem()])
        var downloads: [(String, String, Bool)] = []
        surface.onOpenAttachment = { item, attachment, download in downloads.append((item, attachment.id, download)) }
        let reference = try XCTUnwrap(AgentHtmlDocumentReference.find(in: renderItem()))
        surface.performHTMLDocument(.download, reference)
        try await waitFor { !downloads.isEmpty }
        XCTAssertEqual(downloads.map(\.0), ["tool"])
        XCTAssertEqual(downloads.map(\.1), ["html"])
        XCTAssertEqual(downloads.map(\.2), [true])
        var errors: [String] = []
        surface.onActionError = { errors.append($0) }
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex, status: .idle, revision: 2, items: []))
        surface.performHTMLDocument(.copySource, reference)
        try await waitFor { !errors.isEmpty }
        XCTAssertEqual(errors.count, 1, "An unavailable document reports an error instead of copying")
    }
}
