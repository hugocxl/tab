import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentMarkdownBaselineTests: XCTestCase {
    func testBaselinesMatchBrowserLineBoxes() throws {
        _ = NSApplication.shared
        struct Fixture: Decodable { let source: String; let baseline: Double; let lineHeight: Double }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        for fixture in fixtures {
            let view = AgentRichTextView(frame: .zero)
            view.setContent(AgentMarkdown.render(fixture.source, theme: AppTheme(systemIsDark: false)))
            _ = view.height(for: 500)
            let manager = try XCTUnwrap(view.layoutManager)
            XCTAssertEqual(manager.location(forGlyphAt: 0).y, fixture.baseline, accuracy: 0.05, fixture.source)
            XCTAssertEqual(manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height, fixture.lineHeight, accuracy: 0.05, fixture.source)
        }
    }

    func testMultilineAndParagraphSpacingSurviveBaselineAdjustment() throws {
        let view = AgentRichTextView(frame: .zero)
        view.setContent(AgentMarkdown.render("First  \nSecond\n\nThird", theme: AppTheme(systemIsDark: false)))
        _ = view.height(for: 500)
        let manager = try XCTUnwrap(view.layoutManager)
        for (word, baseline) in [("First", 16.0), ("Second", 38.75), ("Third", 71.9)] {
            let range = (view.string as NSString).range(of: word)
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            XCTAssertEqual(fragment.minY + manager.location(forGlyphAt: glyph).y, baseline, accuracy: 0.05, word)
        }
    }

    // Actual DOM baseline markers and computed line heights at source e5909e53.
    private static let oracle = ########"""
    [
      {
        "ascent": 14,
        "descent": 3,
        "source": "Body text",
        "baseline": 16,
        "height": 22.75,
        "lineHeight": 22.75,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 14,
        "descent": 3,
        "source": "**Strong** and *italic*",
        "baseline": 16,
        "height": 22.75,
        "lineHeight": 22.75,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 14,
        "descent": 3,
        "source": "Body `code` text",
        "baseline": 16,
        "height": 22.75,
        "lineHeight": 22.75,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 19,
        "descent": 4,
        "source": "# Heading",
        "baseline": 20,
        "height": 26,
        "lineHeight": 26,
        "fontSize": 20,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 17,
        "descent": 4,
        "source": "## Heading",
        "baseline": 18,
        "height": 23.390625,
        "lineHeight": 23.4,
        "fontSize": 18,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 15,
        "descent": 3,
        "source": "### Heading",
        "baseline": 16,
        "height": 20.796875,
        "lineHeight": 20.8,
        "fontSize": 16,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 14,
        "descent": 3,
        "source": "#### Heading",
        "baseline": 14,
        "height": 18.1875,
        "lineHeight": 18.2,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 14,
        "descent": 3,
        "source": "> Quote text",
        "baseline": 16,
        "height": 22.75,
        "lineHeight": 22.75,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 14,
        "descent": 3,
        "source": "- List text",
        "baseline": 16,
        "height": 22.75,
        "lineHeight": 22.75,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 14,
        "descent": 3,
        "source": "`code`",
        "baseline": 16,
        "height": 22.75,
        "lineHeight": 22.75,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 14,
        "descent": 3,
        "source": "Emoji 😀",
        "baseline": 16,
        "height": 22.75,
        "lineHeight": 22.75,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      },
      {
        "ascent": 14,
        "descent": 3,
        "source": "中文",
        "baseline": 16,
        "height": 22.75,
        "lineHeight": 22.75,
        "fontSize": 14,
        "fontFamily": "-apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
      }
    ]
    """########
}
