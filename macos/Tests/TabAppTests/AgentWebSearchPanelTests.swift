import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentWebSearchPanelTests: XCTestCase {
    func testSafeLinksKeepTitleAndSnippetAndRejectNonWebSchemes() throws {
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let text = AgentWebSearchPanel.result(.init(title: "Documentation", url: "//example.com/docs", snippet: "Read the guide."), theme: theme)
        XCTAssertTrue(text.string.hasPrefix("Documentation"))
        XCTAssertTrue(text.string.hasSuffix("\nRead the guide."))
        XCTAssertEqual((text.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com/docs")
        XCTAssertNil(text.attribute(.link, at: text.length - 1, effectiveRange: nil))
        let invalid = AgentWebSearchPanel.result(.init(title: "Unlinked result", url: "javascript:alert(1)"), theme: theme)
        XCTAssertEqual(invalid.string, "Unlinked result")
        XCTAssertNil(invalid.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(AgentWebSearchPanel.safeURL("file:///tmp/file"))
        XCTAssertNil(AgentWebSearchPanel.safeURL("https://"))
        XCTAssertEqual(AgentWebSearchPanel.queryPatterns(.init(input: #"{"type":"search","queries":["one","two"],"query":"three"}"#, presentation: .webSearch)), ["one", "two", "three"])
        let collapsed = AgentWebSearchPanel.result(.init(title: "A  title\nwrapped", snippet: " first\n\tsecond  third "), theme: theme)
        XCTAssertEqual(collapsed.string, "A title wrapped\nfirst second third")
        let panel = AgentWebSearchPanel(frame: .zero)
        var opened: URL?
        panel.onOpenURL = { opened = $0 }
        let url = try XCTUnwrap(AgentWebSearchPanel.safeURL("https://example.com"))
        XCTAssertTrue(panel.textView(NSTextView(), clickedOnLink: url, at: 0))
        XCTAssertEqual(opened, url)
    }

    func testTypedWebPanelGeometryAndNarrowWrapping() throws {
        _ = NSApplication.shared
        var activity = AgentToolActivity(name: "WebSearch", category: .web, input: #"{"query":"Swift documentation"}"#, presentation: .webSearch)
        activity.searchPatterns = ["Swift documentation", "AppKit text layout"]
        activity.webResults = [
            .init(title: "Documentation", url: "https://example.com/docs", snippet: "Read the guide."),
            .init(title: "Text layout reference", url: "https://example.com/layout", snippet: "A longer description that should wrap naturally in a narrow conversation."),
        ]
        let row = AgentToolDisclosure(frame: .zero)
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            row.update(.init(id: "search", kind: .tool, text: "Search", tool: activity), expanded: true, theme: theme)
            row.wantsLayer = true; row.layer?.backgroundColor = theme.bg.cgColor
            row.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width: CGFloat in [420, 180] {
                row.frame.size = NSSize(width: width, height: row.height(for: width))
                row.layoutSubtreeIfNeeded()
                let panel = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentWebSearchPanel }.first)
                XCTAssertFalse(panel.isHidden)
                XCTAssertEqual(panel.frame.minX, 12)
                XCTAssertEqual(panel.frame.minY, 48)
                let texts = panel.subviews.compactMap { $0 as? NSTextView }
                XCTAssertEqual(texts.count, 3)
                XCTAssertEqual(texts[1].frame.minY - texts[0].frame.maxY, 8)
                XCTAssertEqual(texts[2].frame.minY - texts[1].frame.maxY, 6)
                XCTAssertTrue(row.subviews.compactMap { $0 as? NSScrollView }.allSatisfy(\.isHidden))
                if let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                    row.cacheDisplay(in: row.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/web-search-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
        }
        XCTAssertGreaterThan(row.height(for: 180), row.height(for: 420))
    }

    func testHoverUnderlinesOnlyTheResultTitle() throws {
        _ = NSApplication.shared
        let panel = AgentWebSearchPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let window = NSWindow(contentRect: panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = panel
        var activity = AgentToolActivity(presentation: .webSearch)
        activity.webResults = [.init(title: "Documentation", url: "https://example.com", snippet: "A snippet")]
        panel.update(activity, theme: AppTheme(systemIsDark: false))
        panel.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSTextView }.first { $0.string.hasPrefix("Documentation") })
        func hover(_ y: CGFloat) throws {
            let point = text.convert(NSPoint(x: 10, y: y), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            panel.mouseMoved(with: event)
        }
        try hover(8)
        XCTAssertEqual(text.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        let icon = (text.string as NSString).range(of: "\u{fffc}").location
        XCTAssertNil(text.textStorage?.attribute(.underlineStyle, at: icon, effectiveRange: nil))
        try hover(24)
        XCTAssertNil(text.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil))
    }
}
