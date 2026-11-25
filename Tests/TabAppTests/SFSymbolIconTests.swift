import AppKit
import XCTest
@testable import TabApp

/// Every icon in Tab is an SF Symbol; a misspelled or unavailable name would
/// silently draw nothing.
@MainActor
final class SFSymbolIconTests: XCTestCase {
    func testEveryAppIconIsAnSFSymbol() {
        let missing = AppIcon.allCases.filter { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing, [], "AppIcon cases without an SF Symbol")
    }

    func testEveryChromeIconIsAnSFSymbol() {
        let missing = ChromeIcon.allCases.filter { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing, [], "ChromeIcon cases without an SF Symbol")
    }

    func testNoUIGlyphIsNamedAsFilled() {
        let filled = AppIcon.allCases.filter { "\($0)".hasSuffix("Fill") }
        XCTAssertEqual(filled, [], "Icons are outlines; name them without Fill")
    }

    /// The Explorer draws filled variants, falling back to the outline.
    func testEveryIconHasExplorerArtwork() {
        let missing = AppIcon.allCases.filter { $0.image(size: 14, artwork: .filled) == nil }
        XCTAssertEqual(missing, [], "Icons without Explorer artwork")
    }
}
