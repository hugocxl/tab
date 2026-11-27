import AppKit
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class AgentMarkdownFragmentTests: XCTestCase {
    func testUnicodeAndDuplicateSlugsMatchSource() {
        XCTAssertEqual(AgentMarkdownFragments.identifiers(for: ["Résumé & **code**!", "Same", "Same", "Same-1", "Same", "!!!"]),
                       ["résumé--code", "same", "same-1", "same-1-1", "same-2", nil])
        XCTAssertEqual(AgentMarkdownFragments.normalize("user-content-user-content-r%C3%A9sum%C3%A9"), "résumé")
        XCTAssertEqual(AgentResponseLink.parse("#same-1"), .fragment("same-1"))
    }

    func testFragmentRevealsNestedDetailsAndStaysInsideItsMessage() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: false)
        let response = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        response.setContent("""
        [Go to the second heading](#same-1)

        # Same

        <details>
        <summary>Hidden</summary>

        <details>
        <summary>Nested</summary>

        # Same

        [Back](#same)
        </details>
        </details>
        """, theme: theme)
        let collapsed = response.height(for: 500)
        XCTAssertEqual(response.headingTargets.map(\.title), ["Same", "Same"])
        XCTAssertTrue(response.openFragment("user-content-same-1"))
        XCTAssertGreaterThan(response.height(for: 500), collapsed)
        XCTAssertFalse(response.openFragment("missing"))
        let nested = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseContainer }.first)
        XCTAssertTrue(nested.captureState().expanded == true)
        XCTAssertTrue(nested.response.openFragment("same"), "Nested links route back to their message root")
        let inline = AgentMarkdown.inline("[Go](#same-1)", theme: theme)
        let destination = try XCTUnwrap(inline.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        XCTAssertEqual(destination.relativeString, "#same-1")
    }

    func testNavigationAlignsHeadingToTranscriptViewport() throws {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 150))
        let response = AgentResponseView(frame: .zero)
        response.setContent(String(repeating: "Paragraph before the heading.\n\n", count: 20) + "# Destination\n\n" + String(repeating: "After.\n\n", count: 20), theme: AppTheme(systemIsDark: false))
        let height = response.height(for: 500)
        response.frame = NSRect(x: 0, y: 0, width: 500, height: height)
        scroll.documentView = response
        XCTAssertTrue(response.openFragment("destination"))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 150)
        let target = try XCTUnwrap(response.headingTargets.first)
        let layout = try XCTUnwrap(target.text.layoutManager)
        let container = try XCTUnwrap(target.text.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: target.range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let y = response.convert(rect.origin, from: target.text).y + target.text.textContainerOrigin.y
        XCTAssertEqual(scroll.contentView.bounds.minY, y, accuracy: 1)
    }
}
