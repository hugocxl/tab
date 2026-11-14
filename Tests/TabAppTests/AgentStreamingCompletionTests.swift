import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentStreamingCompletionTests: XCTestCase {
    private let theme = AppTheme(systemIsDark: false)

    private func complete(_ text: String) -> String { AgentStreamingCompletion.complete(text) }

    private func rendered(_ text: String) -> NSAttributedString {
        AgentMarkdown.inline(complete(text), theme: theme)
    }

    private func weight(of word: String, in text: NSAttributedString) -> CGFloat {
        let range = (text.string as NSString).range(of: word)
        guard range.location != NSNotFound, let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return -1 }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    private func isItalic(_ word: String, in text: NSAttributedString) -> Bool {
        let range = (text.string as NSString).range(of: word)
        guard range.location != NSNotFound, let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.italic)
    }

    // MARK: Ambiguous tails

    /// `Here are the steps:\n-` rendered the sentence as a heading until the next character.
    func testAStructurallyAmbiguousLastLineWaitsForTheNextText() {
        let hold = AgentStreamingCompletion.holdingBackAmbiguousTail
        XCTAssertEqual(hold("Here are the steps:\n-"), "Here are the steps:\n")
        XCTAssertEqual(hold("Title\n=="), "Title\n")
        XCTAssertEqual(hold("Intro\n##"), "Intro\n")
        XCTAssertEqual(hold("Intro\n>"), "Intro\n")
        XCTAssertEqual(hold("Steps:\n12."), "Steps:\n")
        XCTAssertEqual(hold("Code:\n``"), "Code:\n")
        XCTAssertEqual(hold("Here are the steps:\n- first"), "Here are the steps:\n- first", "Once it reads as a list item it shows")
        XCTAssertEqual(hold("Title\n---\n"), "Title\n---\n", "A finished line has decided")
        XCTAssertEqual(hold("```swift\nlet a = 1\n-"), "```swift\nlet a = 1\n-", "Code is never structure")
        // A table shows once its separator row arrives.
        XCTAssertEqual(hold("Results:\n| Name | Value |"), "Results:\n")
        XCTAssertEqual(hold("Results:\n| Name | Value |\n| --- "), "Results:\n")
        XCTAssertEqual(hold("Results:\n| Name | Value |\n| --- | --- |\n| a"), "Results:\n| Name | Value |\n| --- | --- |\n| a")
        let response = AgentResponseView(frame: .zero)
        response.isStreaming = true
        response.setContent("Here are the steps:\n-", theme: theme)
        XCTAssertFalse(response.sectionViews.contains { view in
            (view as? AgentResponseProse)?.text.textStorage?.attribute(.agentMarkdownHeading, at: 0, effectiveRange: nil) != nil
        }, "No flash of a heading")
    }

    /// A streaming repair inside a quote stayed after the message finished.
    func testAFinishedMessageRendersNestedContentAsWritten() {
        let response = AgentResponseView(frame: .zero)
        response.isStreaming = true
        let source = "> quoted *emphasis"
        response.setContent(source, theme: theme)
        response.isStreaming = false
        response.setContent(source, theme: theme)
        let texts = response.textViews.map(\.string).joined()
        let fresh = AgentResponseView(frame: .zero)
        fresh.setContent(source, theme: theme)
        XCTAssertEqual(texts, fresh.textViews.map(\.string).joined(), "The finished message renders as if it never streamed")
        XCTAssertEqual(response.textViews.first?.textStorage?.isEqual(to: try! XCTUnwrap(fresh.textViews.first?.textStorage)), true)
    }

    // MARK: Each marker

    func testUnclosedStrongStarRendersBold() {
        XCTAssertEqual(complete("Some **bold"), "Some **bold**")
        let text = rendered("Some **bold")
        XCTAssertEqual(text.string, "Some bold")
        XCTAssertGreaterThan(weight(of: "bold", in: text), weight(of: "Some", in: text))
    }

    func testUnclosedStrongUnderscoreRendersBold() {
        XCTAssertEqual(complete("Some __bold"), "Some __bold__")
        XCTAssertEqual(rendered("Some __bold").string, "Some bold")
    }

    func testUnclosedStarRendersItalic() {
        XCTAssertEqual(complete("an *italic"), "an *italic*")
        let text = rendered("an *italic")
        XCTAssertEqual(text.string, "an italic")
        XCTAssertTrue(isItalic("italic", in: text))
    }

    func testUnclosedUnderscoreRendersItalic() {
        XCTAssertEqual(complete("an _italic"), "an _italic_")
        XCTAssertTrue(isItalic("italic", in: rendered("an _italic")))
    }

    func testUnclosedStrikethroughRendersStruck() {
        XCTAssertEqual(complete("~~gone"), "~~gone~~")
        let text = rendered("now ~~gone")
        XCTAssertEqual(text.string, "now gone")
        let range = (text.string as NSString).range(of: "gone")
        XCTAssertNotNil(text.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil))
    }

    func testUnclosedCodeSpanRendersAsCode() {
        XCTAssertEqual(complete("run `swift build"), "run `swift build`")
        let text = rendered("run `swift build")
        XCTAssertEqual(text.string, "run swift build")
        let range = (text.string as NSString).range(of: "swift")
        XCTAssertNotNil(text.attribute(.agentInlineCodeBackground, at: range.location, effectiveRange: nil))
    }

    func testUnclosedLinkDestinationShowsLabelOnly() {
        XCTAssertEqual(complete("Read [the guide](https://exa"), "Read the guide")
        XCTAssertEqual(complete("Read [the guide]("), "Read the guide")
        XCTAssertEqual(rendered("Read [the guide](https://exa").string, "Read the guide")
    }

    func testUnclosedImageIsHidden() {
        XCTAssertEqual(complete("Look ![a chart](https://x.test/c"), "Look ")
        XCTAssertEqual(complete("Look ![a cha"), "Look ")
    }

    func testUnclosedLinkLabelDropsBracket() {
        XCTAssertEqual(complete("See [the gui"), "See the gui")
    }

    func testDanglingMarkersAreRemoved() {
        XCTAssertEqual(complete("Next **"), "Next ")
        XCTAssertEqual(complete("Next `"), "Next ")
        XCTAssertEqual(complete("Next **  "), "Next **  ", "A marker followed by spaces is literal text")
        XCTAssertEqual(complete("Next *"), "Next ")
    }

    // MARK: Nesting

    func testNestedEmphasisClosesInnermostFirst() {
        XCTAssertEqual(complete("**bold *and italic"), "**bold *and italic***")
        let text = rendered("**bold *and italic")
        XCTAssertEqual(text.string, "bold and italic")
        XCTAssertGreaterThan(weight(of: "italic", in: text), 0)
        XCTAssertTrue(isItalic("italic", in: text))
        XCTAssertFalse(isItalic("bold", in: text))
    }

    func testCodeInsideUnclosedBoldClosesBoth() {
        XCTAssertEqual(complete("**use `make"), "**use `make`**")
    }

    func testEmphasisInsideUnfinishedLinkLabel() {
        XCTAssertEqual(complete("[**bo](http"), "**bo**")
    }

    func testTrailingSpaceBeforeCloserIsTrimmed() {
        XCTAssertEqual(complete("**bold "), "**bold**")
    }

    // MARK: Untouched syntax

    func testClosedSyntaxIsUnchanged() {
        for source in ["**done** and *done* and `done` and [x](https://a.b) and ~~done~~", "plain text", "a_b_c snake_case"] {
            XCTAssertEqual(complete(source), source)
        }
    }

    func testMarkersInsideCodeSpansAreUntouched() {
        XCTAssertEqual(complete("`**not bold` then"), "`**not bold` then")
        XCTAssertEqual(complete("`a * b` and `_x`"), "`a * b` and `_x`")
    }

    func testURLsAndMathAreUntouched() {
        XCTAssertEqual(complete("see https://x.test/_private/a*b"), "see https://x.test/_private/a*b")
        XCTAssertEqual(complete("math $a*b$ done"), "math $a*b$ done")
    }

    func testEscapedMarkersAreLiteral() {
        XCTAssertEqual(complete("\\*not italic"), "\\*not italic")
    }

    func testIntrawordUnderscoreDoesNotOpen() {
        XCTAssertEqual(complete("call my_func"), "call my_func")
    }

    // MARK: Scope

    func testOnlyTheLastBlockIsRepaired() {
        let blocks: [AgentMarkdown.Block] = [.paragraph("first **open"), .code("", "**x\n"), .paragraph("last *open")]
        let repaired = AgentStreamingCompletion.completingLastBlock(blocks)
        XCTAssertEqual(repaired[0], .paragraph("first **open"))
        XCTAssertEqual(repaired[1], .code("", "**x\n"))
        XCTAssertEqual(repaired[2], .paragraph("last *open*"))
        XCTAssertEqual(AgentStreamingCompletion.completingLastBlock([.code("", "`a")]), [.code("", "`a")])
        XCTAssertEqual(AgentStreamingCompletion.completingLastBlock([.heading(2, "A **b")]), [.heading(2, "A **b**")])
    }

    func testStreamingResponseRepairsAndCompletedMessageIsUnchanged() {
        _ = NSApplication.shared
        let source = "Intro paragraph.\n\nNow **bold and [link](https://ex"
        let response = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        response.isStreaming = true
        response.setContent(source, theme: theme)
        XCTAssertEqual(response.textViews.first?.string, "Intro paragraph.\nNow bold and link")
        // The message completes with the same text: it renders exactly as written.
        response.isStreaming = false
        response.setContent(source, theme: theme)
        XCTAssertEqual(response.textViews.first?.string, "Intro paragraph.\nNow **bold and [link](https://ex")
    }

    func testCompletedMessageNeverTakesRepairPath() {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        response.setContent("Literal **stars", theme: theme)
        XCTAssertEqual(response.textViews.first?.string, "Literal **stars")
    }
}
