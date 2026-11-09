import AppKit
import XCTest
@testable import TabApp

@MainActor
final class ChromeButtonTests: XCTestCase {
    /// Buttons side by side in the sidebars show the same space between
    /// their glyphs, however wide each glyph is.
    func testGlyphsSideBySideKeepTheSameVisibleGap() {
        let rows: [[SystemSymbol]] = [[.command, .plusCircle], [.addProject, .globeBadgePlus]]
        for icons in rows {
            let buttons = icons.map { ChromeButton($0, label: $0.rawValue) }
            CircleButton.layOut(buttons, trailingAt: 300, y: 0)
            let left = buttons[0], right = buttons[1]
            let gap = (right.frame.midX - right.glyphExtent.left) - (left.frame.midX + left.glyphExtent.right)
            XCTAssertEqual(gap, CircleButton.glyphSpacing, accuracy: 0.75, "\(icons)")
        }
    }

    func testTabIconButtonsKeepTheSameVisibleGap() {
        let buttons = [AppIcon.folder, .gitBranch].map { ChromeButton($0, label: $0.rawValue) }
        CircleButton.layOut(buttons, trailingAt: 300, y: 0)
        let left = buttons[0], right = buttons[1]
        let gap = (right.frame.midX - right.glyphExtent.left) - (left.frame.midX + left.glyphExtent.right)
        XCTAssertEqual(gap, CircleButton.glyphSpacing, accuracy: 0.75)
    }

    /// The composed globe badge sticks out of the globe instead of eating
    /// into it, so the globe stays as large as the plain glyph.
    func testBadgedGlobeKeepsTheGlobeFullSize() throws {
        let globe = try XCTUnwrap(SystemSymbol.globe.image(size: ChromeButton.glyph))
        let badged = try XCTUnwrap(SystemSymbol.globeBadgePlus.image(size: ChromeButton.glyph))
        XCTAssertGreaterThan(badged.size.width, globe.size.width)
        XCTAssertGreaterThan(badged.inkBounds.width, globe.inkBounds.width)
        XCTAssertGreaterThan(badged.inkBounds.height, globe.inkBounds.height)
    }
}
