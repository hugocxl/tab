import AppKit
import XCTest
@testable import TabApp

/// Checks the package artwork keeps the square drawing contract used by Tab.
@MainActor
final class IconOpticalSizeTests: XCTestCase {
    func testInlineIconsRemainCenteredAndSmallerThanFullSize() throws {
        let color = NSColor(white: 0.6, alpha: 1)
        let full = try XCTUnwrap(AppIcon.wrench.image(size: 14))
        let inline = try XCTUnwrap(AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale))
        let fullInk = full.inkBounds
        let inlineInk = inline.inkBounds
        XCTAssertEqual(full.size, NSSize(width: 14, height: 14))
        XCTAssertEqual(inline.size, full.size)
        XCTAssertGreaterThan(fullInk.width, inlineInk.width)
        XCTAssertGreaterThan(fullInk.height, inlineInk.height)
        XCTAssertEqual(inlineInk.midX, 7, accuracy: 1)
        XCTAssertEqual(inlineInk.midY, 7, accuracy: 1)
        XCTAssertTrue(full === AppIcon.wrench.image(size: 14))
        XCTAssertFalse(full === inline)
        for image in [AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale, color: color),
                      AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale, hue: .gray, theme: .shared),
                      AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale, theme: .shared),
                      AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale, theme: .shared, tint: color)] {
            XCTAssertEqual(try XCTUnwrap(image).inkBounds, inlineInk)
        }
    }

    func testSignatureMarksFitTheirSquareCanvas() throws {
        for icon in AppIcon.signatureHues.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let image = try XCTUnwrap(icon.image(size: 16, color: .black), icon.rawValue)
            let ink = image.inkBounds
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16), icon.rawValue)
            XCTAssertGreaterThan(ink.width, 0, icon.rawValue)
            XCTAssertGreaterThan(ink.height, 0, icon.rawValue)
            XCTAssertGreaterThanOrEqual(ink.minX, 0, icon.rawValue)
            XCTAssertGreaterThanOrEqual(ink.minY, 0, icon.rawValue)
            XCTAssertLessThanOrEqual(ink.maxX, 16, icon.rawValue)
            XCTAssertLessThanOrEqual(ink.maxY, 16, icon.rawValue)
        }
    }
}
