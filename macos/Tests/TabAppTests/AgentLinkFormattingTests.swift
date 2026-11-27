import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentLinkFormattingTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Node: Decodable {
            let text: String
            let fontSize: Double
            let weight: Double
            let italic: Bool
            let code: Bool
            let strike: Bool
            let link: String?
        }
        let source: String
        let visible: String
        let nodes: [Node]
    }

    func testLabelsMatchBrowserFormattingAndDestinations() throws {
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        for fixture in fixtures {
            let rendered = AgentMarkdown.inline(fixture.source, theme: AppTheme(systemIsDark: false))
            // innerText inserts synthetic breaks around source inline-flex link wrappers.
            XCTAssertEqual(rendered.string, fixture.visible.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), fixture.source)
            for node in fixture.nodes {
                let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = (rendered.string as NSString).range(of: text)
                XCTAssertNotEqual(range.location, NSNotFound, text)
                guard range.location != NSNotFound else { continue }
                let attributes = rendered.attributes(at: range.location, effectiveRange: nil)
                let font = try XCTUnwrap(attributes[.font] as? NSFont)
                XCTAssertEqual(font.pointSize, node.fontSize, accuracy: 0.001, text)
                XCTAssertEqual(NSFontManager.shared.traits(of: font).contains(.italicFontMask), node.italic, text)
                XCTAssertEqual(NSFontManager.shared.traits(of: font).contains(.boldFontMask), node.weight >= 600, text)
                XCTAssertEqual(attributes[.agentInlineCodeBackground] != nil, node.code, text)
                if node.code {
                    XCTAssertEqual(attributes[.foregroundColor] as? NSColor, AgentMarkdownPalette(theme: AppTheme(systemIsDark: false)).heading)
                }
                XCTAssertEqual(attributes[.strikethroughStyle] != nil, node.strike, text)
                XCTAssertEqual((attributes[.link] as? URL)?.absoluteString, node.link, text)
            }
        }
    }

    /// The link detector reads `main.rs` as `http://main.rs`; prose must only link what is
    /// written as a link.
    func testDetectedLinksNeedASchemeOrWww() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: false)
        func links(_ source: String) -> [String] {
            let rendered = AgentMarkdown.inline(source, theme: theme)
            var found: [String] = []
            rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                if let url = value as? URL { found.append(url.absoluteString) }
            }
            return found
        }
        for prose in ["I updated main.rs and lib.rs.", "The ASP.NET host reads notes.ai and script.pl.",
                      "Run it from config.yaml, then index.ts."] {
            XCTAssertEqual(links(prose), [], prose)
        }
        XCTAssertEqual(links("See https://example.com/docs for details."), ["https://example.com/docs"])
        XCTAssertEqual(links("Mirror at http://example.org."), ["http://example.org"])
        XCTAssertEqual(links("Visit www.example.com today."), ["http://www.example.com"])
        XCTAssertEqual(links("Write to mailto:team@example.com please."), ["mailto:team@example.com"])
        XCTAssertTrue(AgentMarkdown.isExplicitWebLink("HTTPS://EXAMPLE.COM"))
        XCTAssertFalse(AgentMarkdown.isExplicitWebLink("main.rs"))
    }

    func testFaviconInsetPreservesSelectionAndCopyText() throws {
        _ = NSApplication.shared
        let text = AgentRichTextView(frame: .zero)
        let content = AgentMarkdown.inline("[Hello](https://example.com) after", theme: AppTheme(systemIsDark: false))
        text.setContent(content)
        _ = text.height(for: 500)
        let layout = try XCTUnwrap(text.layoutManager)
        let firstWidth = content.attributedSubstring(from: NSRange(location: 0, length: 1)).size().width
        // The source renderer's 14px icon + .25em leading and .2em trailing margins at 14px.
        XCTAssertEqual(layout.location(forGlyphAt: 1).x - layout.location(forGlyphAt: 0).x, firstWidth + 20.3, accuracy: 0.01)
        XCTAssertEqual(text.string, "Hello after")
        text.setSelectedRange(NSRange(location: 0, length: 5))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let plainText = NSPasteboard.PasteboardType("NSStringPboardType")
        XCTAssertTrue(text.writeSelection(to: pasteboard, type: plainText))
        XCTAssertEqual(pasteboard.string(forType: plainText), "Hello")
        text.setContent(AgentMarkdown.inline("[Hello](https://example.com) after more", theme: AppTheme(systemIsDark: false)))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
        _ = text.height(for: 150)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
    }

    func testProtocolPrefixDoesNotBreakBeforeItsSlash() throws {
        _ = NSApplication.shared
        for prefix in ["https://", "http://"] {
            let content = AgentMarkdown.render("Before [" + prefix + "example.com/long/path](https://example.com)", theme: AppTheme(systemIsDark: false))
            let text = AgentRichTextView(frame: .zero)
            text.setContent(content)
            for width: CGFloat in [40, 60, 80, 100, 140] {
                _ = text.height(for: width)
                let layout = try XCTUnwrap(text.layoutManager)
                let range = (text.string as NSString).range(of: prefix)
                var noBreak = NSRange()
                XCTAssertNotNil(text.textStorage?.attribute(.agentExternalLinkNoBreak, at: range.location, longestEffectiveRange: &noBreak, in: NSRange(location: 0, length: content.length)))
                XCTAssertEqual(noBreak, range)
                let first = layout.glyphIndexForCharacter(at: range.location)
                let last = layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
                XCTAssertEqual(layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY,
                               layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY, "\(prefix) width \(width), first fragment \(layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil)), measured prefix \(content.attributedSubstring(from: range).size().width)")
                // Each prefix character remains a normal, independently selectable glyph.
                for character in (range.location + 1)..<NSMaxRange(range) {
                    XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: character)).contains(.null))
                }
            }
        }
    }

    func testNativeFormattedLinkSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        let root = LinkFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        let response = AgentResponseView(frame: .zero)
        response.setContent(fixtures.map(\.source).joined(separator: "\n\n"), theme: AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false))
        response.frame = NSRect(x: 20, y: 20, width: 560, height: response.height(for: 560))
        root.addSubview(response)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 260,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = raw.retagging(with: .sRGB) ?? raw
        bitmap.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("formatted-links.png"))
    }

    func testNativeProviderIconSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        let root = LinkFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        let response = AgentResponseView(frame: .zero)
        response.setContent(["github.com", "gitlab.com", "bitbucket.org", "codeberg.org", "git.cafe", "localhost"].map { "[" + $0 + "](https://" + $0 + ")" }.joined(separator: "\n\n"), theme: AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false))
        response.frame = NSRect(x: 20, y: 20, width: 560, height: response.height(for: 560))
        root.addSubview(response)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 260,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = raw.retagging(with: .sRGB) ?? raw
        bitmap.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("provider-icons.png"))
    }

    func testNativeAdjacentLinkSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        let root = LinkFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        let response = AgentResponseView(frame: .zero)
        response.setContent("[a](https://localhost)[b](https://localhost)\n\n[**a**](https://localhost)[*b*](https://localhost)\n\n[a](https://localhost) [b](https://localhost)", theme: AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false))
        response.frame = NSRect(x: 20, y: 20, width: 560, height: response.height(for: 560))
        root.addSubview(response)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 260,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = raw.retagging(with: .sRGB) ?? raw
        bitmap.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("adjacent-links.png"))
    }

    func testNativeNarrowLinkOverflowSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        let root = LinkFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        var x: CGFloat = 20
        for width: CGFloat in [40, 80, 140] {
            let response = AgentResponseView(frame: .zero)
            response.setContent("Before [https://example.com/long/path](https://localhost)", theme: AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false))
            response.frame = NSRect(x: x, y: 20, width: width, height: response.height(for: width))
            root.addSubview(response)
            x += width + 100
        }
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let firstResponse = try XCTUnwrap(root.subviews.first as? AgentResponseView)
        let firstText = try XCTUnwrap(firstResponse.subviews.flatMap(\.subviews).compactMap { $0 as? AgentRichTextView }.first)
        XCTAssertGreaterThanOrEqual(firstText.frame.width, 66)
        let firstLayout = try XCTUnwrap(firstText.layoutManager)
        XCTAssertEqual(firstLayout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).width, 40)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstText.textContainer).containerSize.width, 66)

        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = raw.retagging(with: .sRGB) ?? raw
        bitmap.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("narrow-link-overflow.png"))
    }

    private static let oracle = ########"""
    [
      {
        "source": "[**bold** and *soft*](https://example.com)",
        "visible": "bold and soft",
        "nodes": [
          {
            "text": "bold",
            "fontSize": 14,
            "weight": 600,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": " and ",
            "fontSize": 14,
            "weight": 400,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": "soft",
            "fontSize": 14,
            "weight": 400,
            "italic": true,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          }
        ]
      },
      {
        "source": "[`code` and ~~gone~~](https://example.com)",
        "visible": "code and gone",
        "nodes": [
          {
            "text": "code",
            "fontSize": 11.9,
            "weight": 400,
            "italic": false,
            "code": true,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": " and ",
            "fontSize": 14,
            "weight": 400,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": "gone",
            "fontSize": 14,
            "weight": 400,
            "italic": false,
            "code": false,
            "strike": true,
            "link": "https://example.com"
          }
        ]
      },
      {
        "source": "**[bold *italic*](https://example.com)**",
        "visible": "bold italic",
        "nodes": [
          {
            "text": "bold ",
            "fontSize": 14,
            "weight": 600,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": "italic",
            "fontSize": 14,
            "weight": 600,
            "italic": true,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          }
        ]
      },
      {
        "source": "[**été中**](https://example.com)",
        "visible": "été中",
        "nodes": [
          {
            "text": "été中",
            "fontSize": 14,
            "weight": 600,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          }
        ]
      },
      {
        "source": "[**first**\r\n*second*](https://example.com)",
        "visible": "first second",
        "nodes": [
          {
            "text": "first",
            "fontSize": 14,
            "weight": 600,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": "\r\n",
            "fontSize": 14,
            "weight": 400,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": "second",
            "fontSize": 14,
            "weight": 400,
            "italic": true,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          }
        ]
      },
      {
        "source": "Before[ **bold** ](https://example.com)after",
        "visible": "Before\n bold after",
        "nodes": [
          {
            "text": "Before",
            "fontSize": 14,
            "weight": 400,
            "italic": false,
            "code": false,
            "strike": false,
            "link": null
          },
          {
            "text": " ",
            "fontSize": 14,
            "weight": 400,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": "bold",
            "fontSize": 14,
            "weight": 600,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": " ",
            "fontSize": 14,
            "weight": 400,
            "italic": false,
            "code": false,
            "strike": false,
            "link": "https://example.com"
          },
          {
            "text": "after",
            "fontSize": 14,
            "weight": 400,
            "italic": false,
            "code": false,
            "strike": false,
            "link": null
          }
        ]
      }
    ]
    """########
}

@MainActor
private final class LinkFixture: NSView { override var isFlipped: Bool { true } }
