import AppKit
import XCTest
@testable import TabApp

@MainActor
final class ChromeButtonTests: XCTestCase {
    /// Buttons side by side in the sidebars show the same space between
    /// their glyphs, however wide each glyph is.
    func testGlyphsSideBySideKeepTheSameVisibleGap() {
        let rows: [[ChromeIcon]] = [[.command, .plusCircle], [.addProject, .globeBadgePlus]]
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

    func testEveryChromeIconHasAnImage() {
        for icon in ChromeIcon.allCases {
            let image = icon.image(size: ChromeButton.glyph)
            XCTAssertNotNil(image, "\(icon.stroke.rawValue) did not load")
            XCTAssertEqual(image?.size, NSSize(width: ChromeButton.glyph, height: ChromeButton.glyph))
        }
    }
}
