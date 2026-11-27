import UIKit
import XCTest
@testable import TabMobileUI

final class MarkdownRendererTests: XCTestCase {
    private func spaceAbove(_ line: String, in text: NSAttributedString) -> CGFloat? {
        let location = (text.string as NSString).range(of: line).location
        guard location != NSNotFound else { return nil }
        return (text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?
            .paragraphSpacingBefore
    }

    /// Headings, paragraphs and lists used to run into each other.
    func testBlocksAreSpacedApartAndHeadingsMore() throws {
        let text = MarkdownRenderer.render("Intro.\n\n## Costs\n\nFirst point.\n\n- one\n- two\n\nAfter.")
        let paragraph = try XCTUnwrap(spaceAbove("First point.", in: text))
        let heading = try XCTUnwrap(spaceAbove("Costs", in: text))
        let item = try XCTUnwrap(spaceAbove("two", in: text))
        XCTAssertEqual(spaceAbove("Intro.", in: text), 0)
        XCTAssertGreaterThan(paragraph, 0)
        XCTAssertGreaterThan(heading, paragraph)
        XCTAssertGreaterThan(item, 0)
        XCTAssertLessThan(item, paragraph)
        XCTAssertEqual(spaceAbove("After.", in: text), paragraph)
    }

    func testCodeBlockLinesStayTogether() throws {
        let text = MarkdownRenderer.render("Run:\n\n```\nlet a = 1\nlet b = 2\n```")
        XCTAssertGreaterThan(try XCTUnwrap(spaceAbove("let a", in: text)), 0)
        XCTAssertEqual(spaceAbove("let b", in: text), 0)
    }
}
