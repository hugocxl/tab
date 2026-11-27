import AppKit
import XCTest
import TabCore
@testable import TabApp

@MainActor
final class AgentMarkdownReferenceTests: XCTestCase {
    func testDefinitionsAndCaseInsensitiveFullCollapsedAndShortcutReferences() {
        let lines = ["[Guide]: <https://example.com/a> \"A title\"", "", "[second]:", "  https://example.org", "  'Title'"]
        let first = AgentMarkdownReferences.definition(in: lines, at: 0)
        XCTAssertEqual(first?.label, "guide")
        XCTAssertEqual(first?.destination, "https://example.com/a")
        XCTAssertEqual(first?.count, 1)
        let second = AgentMarkdownReferences.definition(in: lines, at: 2)
        XCTAssertEqual(second?.destination, "https://example.org")
        XCTAssertEqual(second?.count, 3)
        let definitions = ["guide": "https://example.com", "two words": "#destination"]
        XCTAssertEqual(AgentMarkdownReferences.resolve("[**Read**][GUIDE] [Guide][] [guide] [Two  Words]", definitions: definitions),
                       "[**Read**](<https://example.com>) [Guide](<https://example.com>) [guide](<https://example.com>) [Two  Words](<#destination>)")
        XCTAssertEqual(AgentMarkdownReferences.resolve("`[guide]` \\[guide] [x](path/[guide]) [missing]", definitions: definitions),
                       "`[guide]` \\[guide] [x](path/[guide]) [missing]")
    }

    func testForwardDefinitionsResolveNestedViewsAndTablesAfterStreaming() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: false)
        let response = AgentResponseView(frame: .zero)
        let source = """
        A [guide][manual].

        > A [quoted guide][manual].

        | Link |
        | --- |
        | [manual] |

        ```md
        [manual]: https://wrong.example
        [manual]
        ```
        """
        response.setContent(source, theme: theme)
        _ = response.height(for: 600)
        let before = response.sectionUpdateCount
        response.setContent(source + "\n\n[manual]: https://example.com\n\n[manual]: https://ignored.example", theme: theme)
        _ = response.height(for: 600)
        XCTAssertGreaterThan(response.sectionUpdateCount, before)
        let textViews = descendants(response).compactMap { $0 as? AgentRichTextView }
        let links = textViews.flatMap { view -> [URL] in
            let text = view.attributedString()
            var links: [URL] = []
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let url = value as? URL { links.append(url) }
            }
            return links
        }
        XCTAssertEqual(links.filter { $0.absoluteString == "https://example.com" }.count, 3)
        XCTAssertFalse(links.contains { $0.absoluteString == "https://ignored.example" })
        let code = try XCTUnwrap(descendants(response).compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertEqual(code.code, "[manual]: https://wrong.example\n[manual]\n")
        XCTAssertFalse(textViews.contains { $0.string.contains("[manual]: https://example.com") })
    }

    func testDefinitionsDoNotInterruptParagraphsOrBecomeFootnotes() {
        XCTAssertEqual(AgentResponseParser.parse("Existing paragraph\n[id]: https://example.com"),
                       [.paragraph("Existing paragraph\n[id]: https://example.com")])
        XCTAssertNil(AgentMarkdownReferences.definition(in: ["[^note]: A footnote"], at: 0))
        let blocks = AgentResponseParser.parse("> [manual]: https://example.com\n\n[manual]")
        XCTAssertEqual(AgentMarkdownReferences.collect(blocks, parseRawHTML: true)["manual"], "https://example.com")
        let compatibility = AgentMarkdown.render("[manual]\n\n[manual]: https://example.com", theme: AppTheme(systemIsDark: false))
        XCTAssertEqual(compatibility.string.trimmingCharacters(in: .newlines), "manual")
        XCTAssertEqual((compatibility.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com")
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
