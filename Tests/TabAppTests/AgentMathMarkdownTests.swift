import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentMathMarkdownTests: XCTestCase {
    private static let catalog = ThemeCatalog.load(customDirectory: nil)
    private let theme = AppTheme(catalog: catalog, systemIsDark: false)
    private let darkTheme = AppTheme(catalog: catalog, systemIsDark: true)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func spans(_ text: String) -> [AgentMarkdownMath.Span] {
        let extracted = AgentMarkdownMath.extract(text)
        return extracted.text.compactMap { extracted.spans[$0] }
    }

    private func attachments(_ rendered: NSAttributedString) -> [(NSTextAttachment, String)] {
        var result: [(NSTextAttachment, String)] = []
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            result.append((attachment, rendered.attribute(.agentMathSource, at: range.location, effectiveRange: nil) as? String ?? ""))
        }
        return result
    }

    // MARK: Inline parsing

    func testSingleDollarInlineMath() {
        XCTAssertEqual(spans("Euler: $e^{i\\pi} + 1 = 0$."), [.init(latex: "e^{i\\pi} + 1 = 0", display: false)])
    }

    func testPricesAreNotMath() {
        XCTAssertEqual(spans("It costs $5 and $6 today."), [])
        XCTAssertEqual(spans("Between $5-$10 per seat"), [])
        XCTAssertEqual(spans("$ x$ and $x $ are not math"), [])
    }

    func testEscapedDollarIsLiteral() {
        XCTAssertEqual(spans("Pay \\$5 or \\$x\\$"), [])
        let rendered = AgentMarkdown.inline("Pay \\$5 now", theme: theme)
        XCTAssertEqual(rendered.string, "Pay $5 now")
        XCTAssertTrue(attachments(rendered).isEmpty)
    }

    func testParenthesisAndBracketDelimiters() {
        XCTAssertEqual(spans("where \\(x^2\\) and \\[y\\]"),
                       [.init(latex: "x^2", display: false), .init(latex: "y", display: true)])
    }

    func testInlineDoubleDollarIsDisplayStyle() {
        XCTAssertEqual(spans("the sum $$\\sum_i x_i$$ grows"), [.init(latex: "\\sum_i x_i", display: true)])
    }

    func testDollarsInsideCodeSpansAreUntouched() {
        XCTAssertEqual(spans("Run `echo $HOME $PATH` and `$x$`"), [])
        let rendered = AgentMarkdown.inline("Run `echo $x$` now", theme: theme)
        XCTAssertTrue(rendered.string.contains("echo $x$"))
        XCTAssertTrue(attachments(rendered).isEmpty)
    }

    func testMathNeverCrossesIntoCode() {
        XCTAssertEqual(spans("costs $5 then `echo $HOME`"), [])
    }

    func testUnclosedInlineMathStaysText() {
        let rendered = AgentMarkdown.inline("Streaming $x^2 + y", theme: theme)
        XCTAssertEqual(rendered.string, "Streaming $x^2 + y")
        XCTAssertTrue(attachments(rendered).isEmpty)
    }

    func testInlineMathKeepsSurroundingMarkdown() {
        let rendered = AgentMarkdown.inline("**bold** $a_1$ and *$b$*", theme: theme)
        let math = attachments(rendered)
        XCTAssertEqual(math.map(\.1), ["a_1", "b"])
        XCTAssertTrue(rendered.string.hasPrefix("bold \u{FFFC} and \u{FFFC}"))
    }

    func testPrivateUseCharactersInSourceSurvive() {
        let rendered = AgentMarkdown.inline("Icon \u{E000} then $x$", theme: theme)
        XCTAssertTrue(rendered.string.contains("\u{E000}"))
        XCTAssertEqual(attachments(rendered).map(\.1), ["x"])
    }

    // MARK: Attachments

    func testAttachmentBaselineMatchesEngine() throws {
        let rendered = AgentMarkdown.inline("Area $\\frac{a}{b}$", theme: theme)
        let attachment = try XCTUnwrap(attachments(rendered).first?.0)
        let options = AgentMathTypesetter.Options(displayMode: false, fontSize: (14 * AgentMarkdownMath.relativeSize).rounded(),
                                                  color: AgentMarkdownPalette(theme: theme).body, errorColor: theme.danger)
        let engine = AgentMathTypesetter.image("\\frac{a}{b}", options: options, scale: NSScreen.main?.backingScaleFactor ?? 2)
        XCTAssertEqual(attachment.bounds.origin.y, engine.baselineOffset, accuracy: 0.001)
        XCTAssertEqual(attachment.bounds.size, engine.image.size)
        XCTAssertLessThan(attachment.bounds.origin.y, 0, "A fraction descends below the baseline")
    }

    func testAttachmentsAreReusedSoUnchangedProseCompareEqual() {
        let first = AgentMarkdown.inline("Value $x^2$", theme: theme)
        let second = AgentMarkdown.inline("Value $x^2$", theme: theme)
        XCTAssertTrue(first.isEqual(to: second))
    }

    func testInlineMathKeepsFixedLineHeight() {
        let response = AgentResponseView(frame: .zero)
        response.setContent("Plain line one", theme: theme)
        let plain = response.height(for: 400)
        response.setContent("Line $\\frac{a}{b}$ one", theme: theme)
        XCTAssertEqual(response.height(for: 400), plain, accuracy: 0.5)
    }

    func testInlineMathInHeadingsListsAndTables() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent("# Title $x$\n\n- item $y$\n\n| a | b |\n| --- | --- |\n| $z$ | 1 |", theme: theme)
        _ = response.height(for: 600)
        let texts = descendants(response).compactMap { $0 as? NSTextView }
        let sources = texts.flatMap { text -> [String] in
            guard let storage = text.textStorage else { return [] }
            return attachments(storage).map(\.1)
        }
        XCTAssertEqual(Set(sources), ["x", "y", "z"])
    }

    func testThemeChangeRerendersInlineMath() throws {
        let light = AgentMarkdown.inline("Value $x$", theme: theme)
        let dark = AgentMarkdown.inline("Value $x$", theme: darkTheme)
        let lightAttachment = try XCTUnwrap(attachments(light).first?.0)
        let darkAttachment = try XCTUnwrap(attachments(dark).first?.0)
        XCTAssertFalse(lightAttachment === darkAttachment, "Images bake their colors")
    }

    // MARK: Display blocks

    func testDisplayMathOwnParagraph() {
        XCTAssertEqual(AgentResponseParser.parse("Before\n\n$$\nx^2 + y^2\n$$\n\nAfter"),
                       [.paragraph("Before"), .math("x^2 + y^2"), .paragraph("After")])
        XCTAssertEqual(AgentResponseParser.parse("$$E = mc^2$$"), [.math("E = mc^2")])
    }

    func testDisplayMathInterruptsParagraph() {
        XCTAssertEqual(AgentResponseParser.parse("The formula:\n$$\na + b\n$$"),
                       [.paragraph("The formula:"), .math("a + b")])
    }

    func testBracketDisplayMath() {
        XCTAssertEqual(AgentResponseParser.parse("\\[\n\\int_0^1 x\\,dx\n\\]"), [.math("\\int_0^1 x\\,dx")])
        XCTAssertEqual(AgentResponseParser.parse("\\[ a = b \\]"), [.math("a = b")])
    }

    func testMathFences() {
        XCTAssertEqual(AgentResponseParser.parse("```math\n\\alpha\n```"), [.math("\\alpha")])
        XCTAssertEqual(AgentResponseParser.parse("```latex\n\\beta\n```"), [.math("\\beta")])
        XCTAssertEqual(AgentResponseParser.parse("```KaTeX\n\\gamma\n```"), [.math("\\gamma")])
    }

    func testUnclosedDisplayMathStreamsAsText() {
        XCTAssertEqual(AgentResponseParser.parse("$$\nx^2 +"), [.paragraph("$$\nx^2 +")])
        XCTAssertEqual(AgentResponseParser.parse("```math\n\\alpha"), [.code("math", "\\alpha\n", closed: false)])
        XCTAssertEqual(AgentResponseParser.parse("$$a$$ and more"), [.paragraph("$$a$$ and more")])
    }

    func testDollarsInsideCodeFencesStayCode() {
        XCTAssertEqual(AgentResponseParser.parse("```sh\necho $$ $HOME\n$$\n```"), [.code("sh", "echo $$ $HOME\n$$\n", closed: true)])
    }

    func testDisplayMathInsideListItemBecomesBlock() throws {
        let blocks = AgentResponseParser.parse("- Energy:\n  $$\n  E = mc^2\n  $$")
        guard case .listBlock(_, let source, _, _) = try XCTUnwrap(blocks.first) else { return XCTFail("Expected a rich list item") }
        XCTAssertEqual(AgentResponseParser.parse(source), [.paragraph("Energy:"), .math("E = mc^2")])
    }

    // MARK: Sections

    func testDisplayMathSectionIsMeasuredAndReusedInPlace() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent("Intro\n\n$$x$$\n\nOutro", theme: theme)
        let height = response.height(for: 500)
        let math = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseMath }.first)
        XCTAssertEqual(math.latex, "x")
        XCTAssertGreaterThan(math.frame.height, AgentResponseMath.padding * 2)
        response.setContent("Intro\n\n$$\\sum_{i=0}^{n} \\frac{x_i}{2}$$\n\nOutro", theme: theme)
        XCTAssertGreaterThan(response.height(for: 500), height)
        let updated = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseMath }.first)
        XCTAssertTrue(updated === math)
        XCTAssertEqual(math.latex, "\\sum_{i=0}^{n} \\frac{x_i}{2}")
        XCTAssertEqual(math.equation.frame.width, 500, "The equation view spans the column and centers itself")
    }

    func testDisplayMathThemeUpdateRetypesetsWithoutNewSection() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent("$$a+b$$", theme: theme)
        _ = response.height(for: 400)
        let math = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseMath }.first)
        let updates = response.sectionUpdateCount
        response.setContent("$$a+b$$", theme: darkTheme)
        XCTAssertEqual(response.sectionUpdateCount, updates + 1)
        XCTAssertTrue(response.subviews.compactMap { $0 as? AgentResponseMath }.first === math)
    }

    func testStreamingDisplayMathTurnsIntoSectionWhenClosed() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent("$$\nx^2", theme: theme)
        XCTAssertTrue(response.subviews.compactMap { $0 as? AgentResponseMath }.isEmpty)
        response.setContent("$$\nx^2\n$$", theme: theme)
        XCTAssertEqual(response.subviews.compactMap { $0 as? AgentResponseMath }.count, 1)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
