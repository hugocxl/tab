import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentMarkdownFlowTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Block: Decodable { let text: String; let tag: String; let y: Double; let height: Double }
        let source: String
        let height: Double
        let blocks: [Block]
    }

    func testFractionalFlowMatchesSourceAcrossNestedSections() throws {
        _ = NSApplication.shared
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(Self.oracle.utf8))
        let response = AgentResponseView(frame: .zero)
        response.setContent(fixture.source, theme: AppTheme(systemIsDark: false))
        let height = response.height(for: 500)
        response.frame = NSRect(x: 0, y: 0, width: 500, height: height)
        response.layoutSubtreeIfNeeded()
        XCTAssertEqual(height, fixture.height, accuracy: 0.001)
        func texts(in view: NSView) -> [AgentRichTextView] {
            if let text = view as? AgentRichTextView { return [text] }
            return view.subviews.flatMap { texts(in: $0) }
        }
        let views = texts(in: response)
        for block in fixture.blocks {
            if block.tag == "HR" {
                let divider = try XCTUnwrap(response.subviews.first { $0 is AgentResponseDivider })
                XCTAssertEqual(divider.frame.minY, block.y, accuracy: 0.001)
                XCTAssertEqual(divider.frame.height, block.height, accuracy: 0.001)
                continue
            }
            let view = try XCTUnwrap(views.first { $0.string.contains(block.text) })
            let range = (view.string as NSString).range(of: block.text)
            let manager = try XCTUnwrap(view.layoutManager)
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let font = try XCTUnwrap(view.textStorage?.attribute(.agentMarkdownLineFont, at: range.location, effectiveRange: nil) as? NSFont)
            let style = try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            let baseline = font.ascender.rounded() + floor((style.minimumLineHeight - font.ascender.rounded() - (-font.descender).rounded()) / 2)
            let origin = view.convert(NSPoint.zero, to: response)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = origin.y + fragment.minY + manager.location(forGlyphAt: glyph).y - baseline
            XCTAssertEqual(y, block.y, accuracy: 0.001, block.text)
            XCTAssertEqual(style.minimumLineHeight, block.height, accuracy: 0.001, block.text)
        }
    }

    // Actual ChatMarkdown DOM bounds at source e5909e53.
    private static let oracle = ########"""
    {
      "source": "First paragraph.\n\nSecond paragraph.\n\n## Heading\n\nThird paragraph.\n\n> Quoted line.\n\nFinal paragraph.\n\n---\n\nEnd.",
      "height": 243.234375,
      "blocks": [
        {
          "text": "First paragraph.",
          "tag": "P",
          "y": 0,
          "height": 22.75
        },
        {
          "text": "Second paragraph.",
          "tag": "P",
          "y": 33.140625,
          "height": 22.75
        },
        {
          "text": "Heading",
          "tag": "H2",
          "y": 75.890625,
          "height": 23.390625
        },
        {
          "text": "Third paragraph.",
          "tag": "P",
          "y": 109.671875,
          "height": 22.75
        },
        {
          "text": "Quoted line.",
          "tag": "P",
          "y": 142.8125,
          "height": 22.75
        },
        {
          "text": "Final paragraph.",
          "tag": "P",
          "y": 175.953125,
          "height": 22.75
        },
        {
          "text": "",
          "tag": "HR",
          "y": 209.09375,
          "height": 1
        },
        {
          "text": "End.",
          "tag": "P",
          "y": 220.484375,
          "height": 22.75
        }
      ]
    }
    """########
}
