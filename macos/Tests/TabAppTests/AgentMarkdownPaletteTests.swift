import AppKit
@testable import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentMarkdownPaletteTests: XCTestCase {
    private let source = "# Heading\n\n###### Muted\n\nText **bold** and *emphasis*, [link](https://example.com) and `code`.\n\n> Quote\n\n- Marker\n\n| A | B |\n|---|---|\n| Cell | Value |\n\n---"

    func testRenderedTextAndRulesUseSelectedAppTheme() throws {
        _ = NSApplication.shared
        let scheme = ColorScheme(background: RGBColor(0x102030), foreground: RGBColor(0xD0E0F0), palette: [4: RGBColor(0xAA33BB)])
        let theme = AppTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Custom", scheme: scheme)]), darkTheme: "Custom", systemIsDark: true)
        let colors = AgentMarkdownPalette(theme: theme)
        let content = AgentMarkdown.render(source, theme: theme)
        for (text, expected) in [("Heading", theme.fg), ("Muted", theme.fgMuted), ("Text", theme.fg), ("bold", theme.fg), ("link", theme.accent), ("code", theme.fg), ("•", theme.fg)] {
            let range = (content.string as NSString).range(of: text)
            XCTAssertNotEqual(range.location, NSNotFound)
            let color = (content.attribute(.agentListBullet, at: range.location, effectiveRange: nil) as? NSColor)
                ?? (content.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(color, expected)
        }
        let code = (content.string as NSString).range(of: "code")
        XCTAssertEqual(content.attribute(.agentInlineCodeBackground, at: code.location, effectiveRange: nil) as? NSColor, theme.selection)
        XCTAssertEqual(colors.quoteRule, theme.border)
        XCTAssertEqual(colors.tableRule, theme.border)
        XCTAssertEqual(colors.divider, theme.border)
    }

    func testDividerIsAFullWidthOnePixelSection() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent("Before\n\n---\n\nAfter", theme: AppTheme(systemIsDark: false))
        _ = response.height(for: 460)
        let divider = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseDivider }.first)
        XCTAssertEqual(divider.frame.width, 460)
        XCTAssertEqual(divider.frame.height, 1)
        XCTAssertEqual(response.subviews.count, 3)
        _ = response.height(for: 280)
        XCTAssertEqual(divider.frame.width, 280)
    }

    func testNativePaletteSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let root = MarkdownPaletteFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor(srgbRed: dark ? 17.0/255 : 1, green: dark ? 17.0/255 : 1, blue: dark ? 17.0/255 : 1, alpha: 1).cgColor
            let response = AgentResponseView(frame: .zero)
            response.setContent(source, theme: theme)
            response.frame = NSRect(x: 20, y: 20, width: 460, height: response.height(for: 460))
            root.addSubview(response)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = root
            defer { window.close() }
            root.layoutSubtreeIfNeeded()
            let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 500,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let bitmap = raw.retagging(with: .sRGB) ?? raw
            bitmap.size = root.bounds.size
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("markdown-colors-\(dark).png"))
        }
    }

}

private final class MarkdownPaletteFixture: NSView { override var isFlipped: Bool { true } }
