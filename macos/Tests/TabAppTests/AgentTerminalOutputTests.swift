import AppKit
import CryptoKit
@testable import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentTerminalOutputTests: XCTestCase {
    private func render(_ source: String, dark: Bool = false) -> NSAttributedString {
        AgentTerminalOutput(dark: dark, baseColor: .gray).render(source)
    }

    func testCursorRewritesPreserveUnchangedTextAndEraseRequestedRegions() {
        let cases: [(String, String)] = [
            ("progress 100%\rDone", "Doneress 100%"),
            ("progress 100%\r\u{1b}[KDone", "Done"),
            ("abc\u{8}Z", "abZ"),
            ("one\ntwo\u{1b}[A\rONE", "ONE\ntwo"),
            ("abc\u{1b}[2DXY", "aXY"),
            ("abc\r\u{1b}[1K", " bc"),
            ("one\ntwo\u{1b}[2Jclean", "clean"),
            ("abc\u{1b}7\rX\u{1b}8!", "Xbc!"),
            ("a\u{1b}]0;window title\u{7}b", "ab"),
            ("visible\u{1b}[38;2;255", "visible"),
        ]
        for (source, expected) in cases { XCTAssertEqual(render(source).string, expected, source.debugDescription) }
    }

    func testSGRPalettesExtendedColorsResetsAndTextTraits() throws {
        for dark in [false, true] {
            let value = render("\u{1b}[1;2;3;4;9;32mA\u{1b}[22;23;24;29;39mB\u{1b}[38;5;196mC\u{1b}[38:2::12:34:56mD", dark: dark)
            XCTAssertEqual(value.string, "ABCD")
            let first = try XCTUnwrap(value.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            let green = AgentTerminalStyle.color(TerminalPalette(dark: dark).colors[2]).withAlphaComponent(0.65)
            XCTAssertEqual(first, green)
            XCTAssertNotNil(value.attribute(.underlineStyle, at: 0, effectiveRange: nil))
            XCTAssertNotNil(value.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
            let font = try XCTUnwrap(value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
            XCTAssertNil(value.attribute(.underlineStyle, at: 1, effectiveRange: nil))
            XCTAssertEqual(value.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor, .gray)
            XCTAssertEqual(value.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, AgentTerminalStyle.color(0xff0000))
            XCTAssertEqual(value.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor, AgentTerminalStyle.color(0x0c2238))
        }
    }

    func testBackgroundContrastAndInverseUseExistingTerminalColors() {
        let darkBadge = render("\u{1b}[32;42mPASS")
        XCTAssertEqual(darkBadge.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, AgentTerminalStyle.color(TerminalPalette(dark: false).background))
        XCTAssertEqual(darkBadge.attribute(.agentTerminalBackground, at: 0, effectiveRange: nil) as? NSColor, AgentTerminalStyle.color(TerminalPalette(dark: false).colors[2]))
        let lightBadge = render("\u{1b}[48;2;255;255;0mPASS")
        XCTAssertEqual(lightBadge.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, AgentTerminalStyle.color(TerminalPalette(dark: false).foreground))
        let inverse = render("\u{1b}[7mX\u{1b}[27mY")
        XCTAssertNotNil(inverse.attribute(.agentTerminalBackground, at: 0, effectiveRange: nil))
        XCTAssertNil(inverse.attribute(.agentTerminalBackground, at: 1, effectiveRange: nil))
    }

    func testCommandOutputUsesCustomAppANSIColorsAndPreservesExplicitRGB() {
        let scheme = ColorScheme(background: RGBColor(0x102030), foreground: RGBColor(0xD0E0F0), palette: [1: RGBColor(0xA12345), 2: RGBColor(0x21A345)])
        let theme = AppTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Custom", scheme: scheme)]), darkTheme: "Custom", systemIsDark: true)
        let activity = AgentToolActivity(name: "Run", category: .command, output: "\u{1b}[31mR\u{1b}[32mG\u{1b}[38;2;12;34;56mB")
        let output = AgentCommandPresentation.output(activity, theme: theme)
        XCTAssertEqual(output.string, "RGB")
        for (offset, value) in [UInt32(0xA12345), 0x21A345, 0x0C2238].enumerated() {
            XCTAssertEqual(output.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor, AgentTerminalStyle.color(value))
        }
    }

    func testOutputTailAndCursorWindowAreBounded() {
        let source = String(repeating: "x", count: 70_000)
        let result = render(source).string
        XCTAssertTrue(result.hasPrefix("Earlier output not shown\n"))
        XCTAssertEqual(result.utf16.count, 65_536 + "Earlier output not shown\n".utf16.count)
        let lines = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let output = render(lines + "\u{1b}[99999A\rEDIT").string
        XCTAssertTrue(output.hasPrefix("line 0\nline 1\n"))
        XCTAssertTrue(output.contains("EDIT 36"))
        XCTAssertTrue(output.hasSuffix("line 99"))
    }

    // SHA-256 values exported from source e5909e53 normalizeTerminalOutput in Chromium.
    func testNormalizedOutputMatchesSourceOracleByteForByteAtLimits() {
        let plainLines = (0..<8000).map { "line \($0)\n" }.joined()
        let longStyled = "\u{1b}[31m" + String(repeating: "x", count: 70_000)
        let denseSpans = (0..<5000).map { index -> String in "\u{1b}[\(31 + index % 2)m\(index % 10)" }.joined()
        let styledLines = (0..<2000).map { index -> String in "\u{1b}[\(31 + index % 2)m" + String(repeating: "text", count: 20) + "\n" }.joined()
        let unicode = String(repeating: "😀", count: 40_000)
        let cursorBudget = String(repeating: "a", count: 50_000) + "\n" + String(repeating: "b", count: 50_000) + "\u{1b}[A\rZ"
        let sources = [plainLines, longStyled, denseSpans, styledLines, unicode, cursorBudget]
        let expected = [
            ("plain-lines", "8dc19305f731e208e98ad29cc375e688377c09df47543a3959662a084c2ccbf8", 65530, true),
            ("long-styled", "88ebd3c85c263f1393672118c760cb1e244897fccd0ab28ba35dcd8adb46f475", 65543, true),
            ("dense-spans", "eaefc1f14c1996d5b835f2b2c42edd81e29b59ed5d9cbec0a866239bdf272848", 14909, false),
            ("styled-lines", "cebeb53b4a6816a0dd314829eb8b5564dc3f7e06f4bbf0058aa5cdffbae51204", 65504, true),
            ("unicode", "a8e29b973ea93fb8354c76954b5f5a8770da52520060744ee9d59b4c365b5122", 65536, true),
            ("cursor-budget", "9733d357a3d177d769b48c01c4275e0b957335ffdaff98d4ac52312286f61685", 65536, true),
        ]
        for (source, oracle) in zip(sources, expected) {
            let output = AgentTerminalOutput(dark: false, baseColor: .gray).normalize(source)
            let hash = SHA256.hash(data: Data(output.text.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, oracle.1, oracle.0)
            XCTAssertEqual(output.text.utf16.count, oracle.2, oracle.0)
            XCTAssertEqual(output.truncated, oracle.3, oracle.0)
        }
    }

    func testStyledOutputSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        let source = "\u{1b}[1;32mSuccess\u{1b}[0m  \u{1b}[32;42m PASS \u{1b}[0m\n\u{1b}[2mDim\u{1b}[22m  \u{1b}[3mItalic\u{1b}[23m  \u{1b}[4mUnderline\u{1b}[24m  \u{1b}[9mStrike\u{1b}[29m\n\u{1b}[38;5;196mIndexed red\u{1b}[39m  \u{1b}[38;2;12;134;156mRGB teal\u{1b}[0m\nprogress 50%\r\u{1b}[KDone"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let view = AgentRichTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 110))
            view.setContent(render(source, dark: dark))
            view.drawsBackground = true
            view.backgroundColor = dark ? AgentTerminalStyle.color(0x18181b) : .white
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            _ = view.height(for: 420)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/terminal-styles-\(dark ? "dark" : "light").png"))
        }
    }

    func testStyledSpanLimitKeepsRemainderAsPlainText() {
        let source = String(repeating: "\u{1b}[31mred\n", count: 1500)
        let output = render(source)
        XCTAssertEqual(output.string, String(repeating: "red\n", count: 1500))
        XCTAssertEqual(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, AgentTerminalStyle.color(TerminalPalette(dark: false).colors[1]))
        XCTAssertEqual(output.attribute(.foregroundColor, at: output.length - 2, effectiveRange: nil) as? NSColor, .gray)
    }
}
