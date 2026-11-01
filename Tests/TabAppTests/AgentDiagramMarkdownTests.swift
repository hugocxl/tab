import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentDiagramMarkdownTests: XCTestCase {
    private static let catalog = ThemeCatalog.load(customDirectory: nil)
    private let theme = AppTheme(catalog: catalog, systemIsDark: false)
    private let darkTheme = AppTheme(catalog: catalog, systemIsDark: true)
    private let sequence = "sequenceDiagram\n    Alice->>Bob: Hello Bob, how are you?\n    Bob-->>Alice: Great!\n    Alice->>Carol: And you?\n"
    private let gantt = "gantt\n    dateFormat YYYY-MM-DD\n    section Build\n    Parser :a1, 2024-01-01, 10d\n    Renderer :after a1, 20d\n"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        await finishAgentNativeFixtureCleanup()
        try await super.tearDown()
    }

    private func fence(_ source: String) -> String { "```mermaid\n" + source + "```" }

    private func diagram(in response: AgentResponseView) throws -> AgentResponseDiagram {
        try XCTUnwrap(descendants(response).compactMap { $0 as? AgentResponseDiagram }.first)
    }

    // MARK: Parsing

    func testMermaidFenceBecomesDiagramBlock() {
        XCTAssertEqual(AgentResponseParser.parse(fence(sequence)), [.diagram(sequence)])
        XCTAssertEqual(AgentResponseParser.parse("~~~Mermaid\ngraph TD\nA-->B\n~~~"), [.diagram("graph TD\nA-->B\n")])
    }

    func testOtherFencesStayCode() {
        XCTAssertEqual(AgentResponseParser.parse("```swift\nlet a = 1\n```"), [.code("swift", "let a = 1\n", closed: true)])
        XCTAssertEqual(AgentResponseParser.parse("```\ngraph TD\n```"), [.code("", "graph TD\n", closed: true)])
    }

    func testUnclosedMermaidFenceStreamsAsCode() {
        XCTAssertEqual(AgentResponseParser.parse("```mermaid\ngraph TD\nA-->"), [.code("mermaid", "graph TD\nA-->\n", closed: false)])
        let response = AgentResponseView(frame: .zero)
        response.setContent("```mermaid\ngraph TD\nA-->", theme: theme)
        XCTAssertNotNil(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        response.setContent("```mermaid\ngraph TD\nA-->B\n```", theme: theme)
        XCTAssertNotNil(try? diagram(in: response))
        XCTAssertNil(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
    }

    func testHeaderSkipsFrontMatterAndComments() {
        let header = AgentDiagramCache.header(of: "---\ntitle: Flow\n---\n%% note\n\nflowchart LR\nA-->B")
        XCTAssertEqual(header?.keyword, "flowchart")
        XCTAssertEqual(header?.line, 6)
        guard case .document(_, let label, _) = AgentDiagramCache.parseUncached("---\ntitle: Flow\n---\nflowchart LR\nA-->B") else {
            return XCTFail("Front matter must not hide the diagram kind")
        }
        XCTAssertEqual(label, "Flowchart")
    }

    func testUnsupportedKindIsAnError() {
        guard case .failure(let error) = AgentDiagramCache.parseUncached("erDiagram\nA ||--o{ B : has") else {
            return XCTFail("Unsupported kinds can't be drawn")
        }
        XCTAssertEqual(error.line, 1)
        XCTAssertTrue(error.message.contains("erDiagram"))
    }

    // MARK: Cache

    func testParsingIsCachedPerSource() {
        let cache = AgentDiagramCache(capacity: 64)
        _ = cache.parse(sequence)
        _ = cache.parse(sequence)
        XCTAssertEqual(cache.parseCount, 1)
        _ = cache.parse(gantt)
        XCTAssertEqual(cache.parseCount, 2)
    }

    func testCacheEvictsLeastRecentlyUsed() {
        let cache = AgentDiagramCache(capacity: 2)
        _ = cache.parse("graph TD\nA-->B")
        _ = cache.parse("graph TD\nB-->C")
        _ = cache.parse("graph TD\nA-->B")
        _ = cache.parse("graph TD\nC-->D")
        XCTAssertEqual(cache.count, 2)
        _ = cache.parse("graph TD\nA-->B")
        XCTAssertEqual(cache.parseCount, 3, "The recently used source stays cached")
    }

    func testRemeasureDuringStreamingDoesNotReparseOrRelayout() throws {
        let cache = AgentDiagramCache(capacity: 64)
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(sequence) + "\n\nTail", theme: theme)
        let section = try diagram(in: response)
        section.cache = cache
        response.setContent(fence(sequence) + "\n\nTail streaming", theme: theme)
        _ = response.height(for: 600)
        let parses = cache.parseCount, layouts = cache.layoutCount
        for token in 1...20 {
            response.setContent(fence(sequence) + "\n\nTail streaming" + String(repeating: " more", count: token), theme: theme)
            _ = response.height(for: 600)
        }
        XCTAssertEqual(cache.parseCount, parses)
        XCTAssertEqual(cache.layoutCount, layouts)
        XCTAssertTrue(try diagram(in: response) === section)
    }

    // MARK: Section

    func testDiagramSectionShowsKindAndDrawing() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(sequence), theme: theme)
        _ = response.height(for: 600)
        let section = try diagram(in: response)
        XCTAssertEqual(section.titleLabel.stringValue, "Sequence diagram")
        XCTAssertTrue(section.showsDiagram)
        XCTAssertFalse(section.scroll.isHidden)
        XCTAssertTrue(section.text.isHidden)
        XCTAssertNotNil(section.canvas.layout)
        XCTAssertTrue(section.errorLabel.isHidden)
    }

    func testInvalidDiagramFallsBackToSourceWithErrorLine() throws {
        let source = "pie\n\"A\" : many\n"
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(source), theme: theme)
        _ = response.height(for: 600)
        let section = try diagram(in: response)
        XCTAssertEqual(section.error?.line, 2)
        XCTAssertFalse(section.showsDiagram)
        XCTAssertFalse(section.text.isHidden)
        XCTAssertEqual(section.text.string, source)
        XCTAssertFalse(section.errorLabel.isHidden)
        XCTAssertTrue(section.errorLabel.stringValue.hasPrefix("Diagram error, line 2: "))
        XCTAssertEqual(section.errorLabel.textColor, theme.danger)
        XCTAssertTrue(section.sourceButton.isHidden && section.diagramButton.isHidden && section.expand.isHidden)
    }

    func testSourceToggleShowsHighlightedMermaid() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(sequence), theme: theme)
        let drawnHeight = response.height(for: 600)
        let section = try diagram(in: response)
        var changes = 0
        response.onHeightChanged = { changes += 1 }
        section.sourceButton.onPress?()
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(section.showsSource)
        XCTAssertFalse(section.text.isHidden)
        XCTAssertTrue(section.scroll.isHidden)
        XCTAssertNotEqual(response.height(for: 600), drawnHeight)
        let keywordColor = section.text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(keywordColor, theme.fg, "The header keyword is highlighted")
        section.diagramButton.onPress?()
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(section.showsDiagram)
    }

    func testToggleStateSurvivesRowReuse() throws {
        let source = "Intro\n\n" + fence(sequence)
        let original = AgentResponseView(frame: .zero)
        original.setContent(source, theme: theme)
        try diagram(in: original).sourceButton.onPress?()
        let state = original.captureState()
        XCTAssertEqual(state.children[1]?.showsSource, true)

        let recreated = AgentResponseView(frame: .zero)
        recreated.setContent(source, theme: theme)
        var callbacks = 0
        recreated.onHeightChanged = { callbacks += 1 }
        recreated.restoreState(state)
        XCTAssertTrue(try diagram(in: recreated).showsSource)
        XCTAssertEqual(callbacks, 0, "Restoration must not reflow the virtualizer")
    }

    func testToggleStateSurvivesTranscriptEviction() throws {
        var items = (0..<300).map { index in
            AgentChatItem(id: "message-\(index)", kind: .assistant, text: "### Finding \(index)\n\nA selectable answer.")
        }
        items[0] = AgentChatItem(id: "diagram", kind: .assistant, text: fence(sequence))
        let document = AgentTranscriptDocument(frame: .zero)
        document.reflow(viewportWidth: 720)
        document.update(items, omittedCount: 0)
        document.updateViewport(NSRect(x: 0, y: 0, width: 720, height: 600), followingEnd: false)
        let original = try XCTUnwrap(descendants(document).compactMap { $0 as? AgentResponseDiagram }.first)
        original.sourceButton.onPress?()
        for index in 1...20 {
            let y = max(0, document.frame.height - 600) * CGFloat(index) / 20
            document.updateViewport(NSRect(x: 0, y: y, width: 720, height: 600), followingEnd: false)
        }
        XCTAssertFalse(descendants(document).contains { $0 === original }, "Scrolling away evicts the row")
        document.updateViewport(NSRect(x: 0, y: 0, width: 720, height: 600), followingEnd: false)
        let restored = try XCTUnwrap(descendants(document).compactMap { $0 as? AgentResponseDiagram }.first)
        XCTAssertFalse(restored === original, "The row was evicted and rebuilt")
        XCTAssertTrue(restored.showsSource)
    }

    func testCopyCopiesSource() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(sequence), theme: theme)
        let section = try diagram(in: response)
        NSPasteboard.general.clearContents()
        section.copy.onPress?()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), sequence)
        XCTAssertEqual(section.copy.toolTip, "Copied")
    }

    func testSequenceDiagramHasNaturalSizeAndScrollsWhenNarrow() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(sequence), theme: theme)
        let wide = response.height(for: 900)
        let section = try diagram(in: response)
        let layout = try XCTUnwrap(section.canvas.layout)
        let narrowWidth = max(120, ceil(layout.size.width) / 2)
        let narrow = response.height(for: narrowWidth)
        XCTAssertEqual(try XCTUnwrap(section.canvas.layout).size, layout.size, "Sequence diagrams keep their natural size")
        XCTAssertEqual(narrow, wide + 10, accuracy: 0.5, "A narrow column adds room for the horizontal scroller")
        XCTAssertGreaterThan(section.canvas.frame.width, section.scroll.frame.width)
    }

    func testGanttLaysOutToColumnWidth() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(gantt), theme: theme)
        _ = response.height(for: 1000)
        let section = try diagram(in: response)
        let wide = try XCTUnwrap(section.canvas.layout).size.width
        _ = response.height(for: 640)
        let narrow = try XCTUnwrap(section.canvas.layout).size.width
        XCTAssertLessThan(narrow, wide)
        XCTAssertLessThanOrEqual(narrow, 640 - AgentResponseDiagram.inset * 2 + 0.5)
        XCTAssertEqual(section.titleLabel.stringValue, "Gantt chart")
    }

    func testThemeUpdateRelaysOutWithNewColorsInPlace() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(sequence), theme: theme)
        _ = response.height(for: 600)
        let section = try diagram(in: response)
        let lightPixels = try XCTUnwrap(section.renderedImage(scale: 1)).tiffRepresentation
        response.setContent(fence(sequence), theme: darkTheme)
        _ = response.height(for: 600)
        XCTAssertTrue(try diagram(in: response) === section)
        let darkPixels = try XCTUnwrap(section.renderedImage(scale: 1)).tiffRepresentation
        XCTAssertNotEqual(lightPixels, darkPixels)
    }

    func testRenderedImageIsTwiceTheLayoutForZoom() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent(fence(sequence), theme: theme)
        _ = response.height(for: 600)
        let section = try diagram(in: response)
        let image = try XCTUnwrap(section.renderedImage())
        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(CGFloat(representation.pixelsWide), image.size.width * 2, accuracy: 1)
    }

    func testHugeDiagramImageIsBoundedByThePixelCap() throws {
        let layout = AgentDiagramLayout(size: CGSize(width: 20_000, height: 20_000), draw: { _ in })
        let image = try XCTUnwrap(AgentResponseDiagram.image(of: layout, theme: theme, scale: 2))
        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertLessThanOrEqual(representation.pixelsWide * representation.pixelsHigh, AgentResponseDiagram.maxImagePixels)
        XCTAssertGreaterThan(representation.pixelsWide, 1000)
        XCTAssertEqual(AgentResponseDiagram.clampedScale(for: CGSize(width: 100, height: 100), requested: 2), 2)
    }

    func testDiagramInsideQuoteRenders() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent("> ```mermaid\n> graph TD\n> A-->B\n> ```", theme: theme)
        _ = response.height(for: 600)
        XCTAssertEqual(try diagram(in: response).titleLabel.stringValue, "Flowchart")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
