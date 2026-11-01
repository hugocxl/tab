import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentInlineHTMLTests: XCTestCase {
    private let theme = AppTheme(systemIsDark: false)

    private func html(_ source: String) -> NSAttributedString {
        AgentMarkdown.inline(source, theme: theme, rawHTML: true)
    }

    private func attribute(_ key: NSAttributedString.Key, of word: String, in text: NSAttributedString,
                           file: StaticString = #filePath, line: UInt = #line) -> Any? {
        let range = (text.string as NSString).range(of: word)
        XCTAssertNotEqual(range.location, NSNotFound, "\(word) missing from \(text.string)", file: file, line: line)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(key, at: range.location, effectiveRange: nil)
    }

    private func font(of word: String, in text: NSAttributedString) -> NSFont? {
        attribute(.font, of: word, in: text) as? NSFont
    }

    private func weight(_ font: NSFont?) -> CGFloat {
        let traits = font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    // MARK: Formatting tags

    func testBoldTagsSetSemiboldWeight() {
        for tag in ["b", "strong"] {
            let text = html("plain <\(tag)>heavy</\(tag)> plain")
            XCTAssertEqual(text.string, "plain heavy plain")
            XCTAssertGreaterThan(weight(font(of: "heavy", in: text)), weight(font(of: "plain", in: text)), tag)
        }
    }

    func testItalicTagsSetItalicTrait() {
        for tag in ["i", "em"] {
            let text = html("a <\(tag)>slanted</\(tag)> b")
            XCTAssertEqual(text.string, "a slanted b")
            XCTAssertTrue(font(of: "slanted", in: text)?.fontDescriptor.symbolicTraits.contains(.italic) == true, tag)
            XCTAssertFalse(font(of: "a", in: text)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        }
    }

    func testStrikeTagsStrikeThrough() {
        for tag in ["s", "del", "strike"] {
            let text = html("x <\(tag)>gone</\(tag)> y")
            XCTAssertEqual(attribute(.strikethroughStyle, of: "gone", in: text) as? Int, NSUnderlineStyle.single.rawValue, tag)
            XCTAssertNil(attribute(.strikethroughStyle, of: "y", in: text))
        }
    }

    func testUnderlineTag() {
        let text = html("an <u>underlined</u> word")
        XCTAssertEqual(attribute(.underlineStyle, of: "underlined", in: text) as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testCodeAndKeyboardTagsRenderAsInlineCode() {
        for tag in ["code", "kbd"] {
            let text = html("press <\(tag)>&lt;Cmd&gt; *K*</\(tag)> now")
            XCTAssertTrue(text.string.contains("<Cmd> *K*"), "\(tag): entities decode and Markdown stays literal: \(text.string)")
            XCTAssertNotNil(attribute(.agentInlineCodeBackground, of: "Cmd", in: text), tag)
            XCTAssertNil(attribute(.agentInlineCodeBackground, of: "now", in: text))
        }
    }

    func testSubscriptAndSuperscriptShrinkAndShiftBaseline() {
        let text = html("H<sub>2</sub>O and E=mc<sup>3</sup>")
        XCTAssertEqual(text.string, "H2O and E=mc3")
        let base = font(of: "H", in: text)?.pointSize ?? 0
        let lowered = (text.string as NSString).range(of: "2")
        let raised = (text.string as NSString).range(of: "3")
        let lowFont = text.attribute(.font, at: lowered.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(lowFont?.pointSize ?? 0, base * 0.75, accuracy: 0.01)
        XCTAssertLessThan(text.attribute(.baselineOffset, at: lowered.location, effectiveRange: nil) as? CGFloat ?? 0, 0)
        XCTAssertGreaterThan(text.attribute(.baselineOffset, at: raised.location, effectiveRange: nil) as? CGFloat ?? 0, 0)
    }

    func testMarkHighlightsWithSoftAccent() {
        let text = html("a <mark>highlighted</mark> b")
        XCTAssertEqual(attribute(.backgroundColor, of: "highlighted", in: text) as? NSColor, theme.accentSoft)
        XCTAssertNil(attribute(.backgroundColor, of: "b", in: text))
    }

    func testSmallShrinksAndSpanPassesThrough() {
        let text = html("big <small>tiny</small> <span class=\"x\">same</span>")
        XCTAssertEqual(text.string, "big tiny same")
        XCTAssertLessThan(font(of: "tiny", in: text)?.pointSize ?? 99, font(of: "big", in: text)?.pointSize ?? 0)
        XCTAssertEqual(font(of: "same", in: text)?.pointSize, font(of: "big", in: text)?.pointSize)
    }

    func testBreakTagsBecomeHardLineBreaks() {
        let text = html("one<br>two<br/>three<BR />four")
        XCTAssertEqual(text.string, "one\ntwo\nthree\nfour")
        let trailing = html("end<br>")
        XCTAssertEqual(trailing.string, "end", "A trailing break neither shows a backslash nor adds a line")
    }

    func testNestedTagsCombine() {
        let text = html("<b><i>both</i></b> and **<u>md</u>**")
        let both = font(of: "both", in: text)
        XCTAssertTrue(both?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        XCTAssertGreaterThan(weight(both), 0)
        XCTAssertNotNil(attribute(.underlineStyle, of: "md", in: text))
        XCTAssertGreaterThan(weight(font(of: "md", in: text)), 0)
    }

    // MARK: Links and images

    func testAnchorTagWithHrefBecomesLink() throws {
        let text = html("see <a href=\"https://example.com/a?b=1&amp;c=2\">the docs</a> now")
        XCTAssertEqual(text.string.replacingOccurrences(of: "\u{FFFC}", with: ""), "see the docs now")
        let url = try XCTUnwrap(attribute(.link, of: "docs", in: text) as? URL)
        XCTAssertEqual(url.absoluteString, "https://example.com/a?b=1&c=2")
        XCTAssertNil(attribute(.link, of: "now", in: text))
    }

    func testUnsafeHrefStaysPlainText() {
        for href in ["javascript:alert(1)", "data:text/html,hi", "vbscript:x"] {
            let text = html("<a href=\"\(href)\" onclick=\"steal()\">click</a>")
            XCTAssertEqual(text.string, "click", href)
            XCTAssertNil(attribute(.link, of: "click", in: text), href)
        }
    }

    func testImageTagBecomesMarkdownImage() {
        let extraction = AgentInlineHTML.extract("before <img src=\"https://x.test/cat.png\" alt=\"A [cat]\" onerror=\"x()\"> after")
        XCTAssertEqual(extraction.text, "before ![A \\[cat\\]](<https://x.test/cat.png>) after")
        XCTAssertEqual(AgentInlineHTML.extract("<img src=\"javascript:x\" alt=\"no\">").text, "no")
        XCTAssertEqual(AgentInlineHTML.extract("<img src='img/local.png'/>").text, "![](<img/local.png>)")
    }

    // MARK: Sanitizer

    func testScriptsAndStylesAreRemovedWithTheirContent() {
        let text = html("safe<script>alert('x')</script> text<style>p{color:red}</style>!")
        XCTAssertEqual(text.string, "safe text!")
    }

    func testIframesAndUnknownTagsKeepOnlyText() {
        let text = html("<iframe src=\"https://evil.test\">fallback</iframe> <custom-tag data-x=1>kept</custom-tag> <div onmouseover=\"x()\">div</div>")
        XCTAssertEqual(text.string, "fallback kept div")
        XCTAssertNil(attribute(.link, of: "fallback", in: text))
    }

    func testEventAttributesNeverReachOutput() {
        let extraction = AgentInlineHTML.extract("<b onclick=\"steal()\" style=\"x\">bold</b>")
        XCTAssertFalse(extraction.text.contains("onclick"))
        XCTAssertFalse(extraction.text.contains("steal"))
        XCTAssertEqual(extraction.pairs, [[.bold]])
    }

    func testCommentsDisappear() {
        XCTAssertEqual(html("a <!-- hidden <b>x</b> --> b").string, "a b")
    }

    func testEntitiesDecode() {
        let text = html("&amp; &lt;tag&gt; a&nbsp;b &#65;&#x42; &quot;q&quot; &copy;")
        XCTAssertEqual(text.string, "& <tag> a\u{00A0}b AB \"q\" ©")
        XCTAssertEqual(AgentInlineHTML.decodeEntities("&unknown; &#0; &amp"), "&unknown; \u{FFFD} &amp")
    }

    func testCodeSpansAutolinksAndMathKeepAngleBrackets() {
        let text = html("`<b>raw</b>` and <https://example.com/x> and $a<b$")
        XCTAssertTrue(text.string.contains("<b>raw</b>"), text.string)
        XCTAssertTrue(text.string.contains("https://example.com/x"), text.string)
        XCTAssertFalse(text.string.contains("<https"), "Autolinks still render as links")
    }

    func testComparisonsAreNotTags() {
        XCTAssertEqual(html("if a <b, then c > d").string, "if a <b, then c > d")
        XCTAssertEqual(html("1 <2 and 3> 2").string, "1 <2 and 3> 2")
        XCTAssertEqual(html("x < y").string, "x < y")
    }

    func testTablesAreLeftAsText() {
        XCTAssertEqual(AgentInlineHTML.extract("<table><tr><td>1</td></tr></table>").text, "<table><tr><td>1</td></tr></table>")
    }

    // MARK: Raw-HTML gate

    func testUserMessagesKeepHTMLLiteral() {
        let text = AgentMarkdown.inline("plain <b>bold</b> <script>x</script>", theme: theme)
        XCTAssertEqual(text.string, "plain <b>bold</b> <script>x</script>")
        let blocks = AgentResponseParser.parse("<h2>Title</h2>", parseRawHTML: false)
        XCTAssertEqual(blocks, [.paragraph("<h2>Title</h2>")])
    }

    func testResponseViewHonorsRawHTMLGate() throws {
        _ = NSApplication.shared
        let assistant = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        assistant.setContent("a <b>bold</b> word", theme: theme)
        XCTAssertEqual(assistant.textViews.first?.string, "a bold word")
        let user = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        user.parseRawHTML = false
        user.setContent("a <b>bold</b> word", theme: theme)
        XCTAssertEqual(user.textViews.first?.string, "a <b>bold</b> word")
    }

    // MARK: Anchors

    func testAnchorsRegisterAsFragmentTargets() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        response.setContent("""
        [Jump](#install) and [span](#note)

        Text <a id="install"></a>Install steps here.

        Another <span id="note">note</span>.

        <a name="end">
        """, theme: theme)
        let targets = response.headingTargets
        XCTAssertEqual(Set(targets.compactMap(\.explicitID)), ["install", "note", "end"])
        let install = try XCTUnwrap(AgentMarkdownFragments.target("install", in: targets))
        XCTAssertEqual((install.text.string as NSString).substring(with: install.range), "I")
        let note = try XCTUnwrap(AgentMarkdownFragments.target("user-content-note", in: targets))
        XCTAssertEqual((note.text.string as NSString).substring(with: note.range), "note")
        XCTAssertTrue(response.openFragment("install"))
        XCTAssertTrue(response.openFragment("end"))
    }

    func testAnchorIDsAreSanitized() {
        XCTAssertEqual(AgentMarkdownFragments.anchorID(" user-content-x "), "x")
        XCTAssertNil(AgentMarkdownFragments.anchorID("two words"))
        XCTAssertNil(AgentMarkdownFragments.anchorID(""))
    }

    // MARK: Bidirectional text

    func testRightToLeftDirectionSetsParagraphBaseDirection() throws {
        let rendered = AgentMarkdown.render([.paragraph("<span dir=\"rtl\">שלום עולם</span>")], theme: theme, rawHTML: true)
        let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.baseWritingDirection, .rightToLeft)
        let direction = rendered.attribute(.writingDirection, at: 0, effectiveRange: nil) as? [NSNumber]
        XCTAssertEqual(direction?.first?.intValue, NSWritingDirection.rightToLeft.rawValue | NSWritingDirectionFormatType.embedding.rawValue)
        let plain = AgentMarkdown.render([.paragraph("no direction")], theme: theme, rawHTML: true)
        XCTAssertNotEqual((plain.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.baseWritingDirection, .rightToLeft)
    }

    func testBdoOverridesDirection() {
        let text = html("<bdo dir=\"rtl\">abc</bdo>")
        let direction = attribute(.writingDirection, of: "abc", in: text) as? [NSNumber]
        XCTAssertEqual(direction?.first?.intValue, NSWritingDirection.rightToLeft.rawValue | NSWritingDirectionFormatType.override.rawValue)
    }

    // MARK: Block HTML

    func testStandaloneBlockHTMLBecomesMarkdownBlocks() {
        XCTAssertEqual(AgentResponseParser.parse("<h2>Setup</h2>"), [.heading(2, "Setup")])
        XCTAssertEqual(AgentResponseParser.parse("<p>One\nparagraph</p>"), [.paragraph("One paragraph")])
        XCTAssertEqual(AgentResponseParser.parse("<hr>"), [.divider])
        XCTAssertEqual(AgentResponseParser.parse("<blockquote>Quoted</blockquote>"), [.quote("Quoted")])
        let list = AgentResponseParser.parse("<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>")
        XCTAssertEqual(list.count, 2)
        if case .list(let marker, let text, _, _) = list.first { XCTAssertEqual(marker, "3."); XCTAssertEqual(text, "three") }
        else { XCTFail("Expected list item, got \(list)") }
        let bullets = AgentResponseParser.parse("<ul><li>a</li><li>b</li></ul>")
        XCTAssertEqual(bullets.count, 2)
    }

    func testPreCodeBecomesFencedCode() {
        let blocks = AgentResponseParser.parse("<pre><code class=\"language-swift\">let a = 1 &lt; 2\n\n# not a heading\n</code></pre>\n\nAfter")
        XCTAssertEqual(blocks.first, .code("swift", "let a = 1 < 2\n\n# not a heading\n", closed: true))
        XCTAssertEqual(blocks.last, .paragraph("After"))
    }

    func testMalformedOrNestedBlockHTMLStaysAsWritten() {
        XCTAssertEqual(AgentResponseParser.parse("<p>unclosed"), [.paragraph("<p>unclosed")])
        XCTAssertEqual(AgentResponseParser.parse("<ul><li>a<ul><li>b</li></ul></li></ul>"), [.paragraph("<ul><li>a<ul><li>b</li></ul></li></ul>")])
        XCTAssertEqual(AgentResponseParser.parse("<table><tr><td>x</td></tr></table>"), [.paragraph("<table><tr><td>x</td></tr></table>")])
    }

    func testHeadingIDBecomesAnchor() {
        let blocks = AgentResponseParser.parse("<h3 id=\"custom\">Title</h3>")
        XCTAssertEqual(blocks, [.heading(3, "<span id=\"custom\">Title</span>")])
        let rendered = AgentMarkdown.render(blocks, theme: theme, rawHTML: true)
        XCTAssertEqual(rendered.string, "Title")
        XCTAssertEqual(rendered.attribute(.agentMarkdownAnchor, at: 0, effectiveRange: nil) as? String, "custom")
    }

    func testLargeInputSkipsHTMLPass() {
        let large = String(repeating: "a", count: AgentInlineHTML.maximumSource) + "<b>x</b>"
        XCTAssertEqual(AgentInlineHTML.extract(large).text, large)
    }
}
