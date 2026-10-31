import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentInlineCodeTests: XCTestCase {
    func testCodeUsesBrowserRelativeSizeAndInheritsHeadingWeight() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: false)
        let source = AgentMarkdown.render("Before `code` after.\n\n## Heading `code`", theme: theme)
        let string = source.string as NSString
        let first = string.range(of: "code")
        let second = string.range(of: "code", options: .backwards)
        let firstFont = try XCTUnwrap(source.attribute(.font, at: first.location, effectiveRange: nil) as? NSFont)
        let secondFont = try XCTUnwrap(source.attribute(.font, at: second.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(firstFont.pointSize, 11.9, accuracy: 0.001)
        XCTAssertEqual(secondFont.pointSize, 15.3, accuracy: 0.001)
        let expected = try XCTUnwrap(NSFont(name: "SFMono-Semibold", size: 15.3))
        XCTAssertEqual(secondFont.fontDescriptor.object(forKey: .traits) as? NSDictionary,
                       expected.fontDescriptor.object(forKey: .traits) as? NSDictionary)
        XCTAssertNotNil(source.attribute(.agentInlineCodeBackground, at: first.location, effectiveRange: nil))
        XCTAssertNil(source.attribute(.backgroundColor, at: first.location, effectiveRange: nil))
        XCTAssertEqual(source.string, "Before code after.\nHeading code")
    }

    func testStrongCodeUsesSemiboldWithoutChangingCopyableCharacters() throws {
        let source = AgentMarkdown.inline("**`code`** and **bold**", theme: AppTheme(systemIsDark: false))
        let code = try XCTUnwrap(source.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bold = try XCTUnwrap(source.attribute(.font, at: 9, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(code.pointSize, 11.9, accuracy: 0.001)
        let expectedCode = try XCTUnwrap(NSFont(name: "SFMono-Semibold", size: 11.9))
        let expectedBold = AppFont.system(14, weight: .semibold)
        XCTAssertEqual(code.fontDescriptor.object(forKey: .traits) as? NSDictionary, expectedCode.fontDescriptor.object(forKey: .traits) as? NSDictionary)
        XCTAssertEqual(bold.fontDescriptor.object(forKey: .traits) as? NSDictionary, expectedBold.fontDescriptor.object(forKey: .traits) as? NSDictionary)
        XCTAssertEqual(source.string, "code and bold")
    }
}
