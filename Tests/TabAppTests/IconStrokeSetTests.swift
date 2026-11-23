import XCTest
import Icons
@testable import TabApp

/// Keeps every UI glyph on @hugocxl/icons' stroke set: only brand and
/// language logos, which have no stroke version, may come from elsewhere.
@MainActor
final class IconStrokeSetTests: XCTestCase {
    func testEveryUIGlyphHasAStrokeVersion() {
        let missing = AppIcon.allCases.filter { StrokeIcon(rawValue: $0.rawValue) == nil && $0.signatureHue == nil }
        XCTAssertEqual(missing, [], "UI glyphs without a stroke version")
    }

    func testNoUIGlyphIsNamedAsFilled() {
        let filled = AppIcon.allCases.filter { "\($0)".hasSuffix("Fill") }
        XCTAssertEqual(filled, [], "Stroke icons are outlines; name them without Fill")
    }

    /// The Explorer draws the default set, under the icons' original names.
    func testEveryIconHasExplorerArtwork() {
        let missing = AppIcon.allCases.filter { $0.image(size: 14, artwork: .duotone) == nil }
        XCTAssertEqual(missing, [], "Icons without default-set artwork for the Explorer")
    }
}
