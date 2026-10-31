import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentMarkdownWhitespaceTests: XCTestCase {
    private struct Fixture: Decodable { let source: String; let visible: String; let height: Double }

    func testVisibleTextAndLineCountMatchBrowserWhitespace() throws {
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        try assertFixtures(fixtures, lineBreaks: false)
    }

    func testUserMessagesPreserveSoftBreaksLikeSource() throws {
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.userOracle.utf8))
        try assertFixtures(fixtures, lineBreaks: true)
    }

    private func assertFixtures(_ fixtures: [Fixture], lineBreaks: Bool) throws {
        let theme = AppTheme(systemIsDark: false)
        for fixture in fixtures {
            let response = AgentResponseView(frame: .zero)
            response.lineBreaks = lineBreaks
            response.setContent(fixture.source, theme: theme)
            _ = response.height(for: 500)
            let text = try XCTUnwrap(response.subviews.flatMap(\.subviews).compactMap { $0 as? AgentRichTextView }.first)
            XCTAssertEqual(text.string, fixture.visible, fixture.source)
            let layout = try XCTUnwrap(text.layoutManager)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
            XCTAssertEqual(lines, Int((fixture.height / 22.75).rounded()), fixture.source)
        }
    }

    func testCollapsePreservesFormattingAndLinkTargets() throws {
        let rendered = AgentMarkdown.inline("one **bold**   [link](https://example.com)\nnext", theme: AppTheme(systemIsDark: false))
        XCTAssertEqual(rendered.string, "one bold link next")
        let link = (rendered.string as NSString).range(of: "link")
        XCTAssertEqual((rendered.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com")
        let bold = (rendered.string as NSString).range(of: "bold")
        let font = try XCTUnwrap(rendered.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    // Real rendered innerText and paragraph heights at source e5909e53.
    private static let oracle = ########"""
    [
      {
        "source": "one\ntwo",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "one  \ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one\\\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one    two",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "one\ttwo",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "`one    two`",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "`one\ntwo`",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "one\r\ntwo",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "one\u00a0\u00a0two",
        "visible": "one\u00a0\u00a0two",
        "height": 22.75
      },
      {
        "source": "one&#32;&#32;\ntwo",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "**one  \ntwo**",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "`one  \ntwo`",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "**one**  \ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one **bold**   two",
        "visible": "one bold two",
        "height": 22.75
      },
      {
        "source": "[link](https://example.com  \n \"title\")",
        "visible": "link",
        "height": 22.75
      },
      {
        "source": "\u4e2d\u6587\n\u4e2d\u6587",
        "visible": "\u4e2d\u6587 \u4e2d\u6587",
        "height": 22.75
      },
      {
        "source": "one  \r\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one  \rtwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one\\\r\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      }
    ]
    """########
    private static let userOracle = ########"""
    [
      {
        "source": "one\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one  \ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one\\\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one    two",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "one\ttwo",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "`one    two`",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "`one\ntwo`",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "one\r\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one  two",
        "visible": "one  two",
        "height": 22.75
      },
      {
        "source": "one&#32;&#32;\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "**one  \ntwo**",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "`one  \ntwo`",
        "visible": "one two",
        "height": 22.75
      },
      {
        "source": "**one**  \ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one **bold**   two",
        "visible": "one bold two",
        "height": 22.75
      },
      {
        "source": "[link](https://example.com  \n \"title\")",
        "visible": "link",
        "height": 22.75
      },
      {
        "source": "中文\n中文",
        "visible": "中文\n中文",
        "height": 45.5
      },
      {
        "source": "one  \r\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one  \rtwo",
        "visible": "one\ntwo",
        "height": 45.5
      },
      {
        "source": "one\\\r\ntwo",
        "visible": "one\ntwo",
        "height": 45.5
      }
    ]
    """########

}
