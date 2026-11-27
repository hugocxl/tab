import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentListMarkerTests: XCTestCase {
    private struct Item: Decodable, Equatable { var marker: String; var text: String }
    private struct Fixture: Decodable { var source: String; var items: [Item] }

    func testNumberingAndMarkersMatchSourceLists() throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        for fixture in fixtures {
            let items = AgentResponseParser.parse(fixture.source).compactMap { block -> Item? in
                if case .list(let marker, let text, _, _) = block { return Item(marker: marker, text: text) }
                return nil
            }
            XCTAssertEqual(items, fixture.items, fixture.source)
        }
    }

    func testMixedKindsCountMatchingAncestorsAndRestartAfterParagraph() {
        let blocks = AgentResponseParser.parse("1. Outer\n   - Bullet\n\n     27. Nested\n     1. Next\n\nParagraph\n\n9. Restart")
        let markers = blocks.compactMap { block -> String? in
            if case .list(let marker, _, _, _) = block { return marker }; return nil
        }
        XCTAssertEqual(markers, ["1.", "•", "aa.", "ab.", "9."])
    }

    func testBulletGeometryAndCopyMatchBrowser() throws {
        _ = NSApplication.shared
        let source = "- Disc\n  - Circle\n    - Square\n- Second"
        let view = AgentRichTextView(frame: .zero)
        view.setContent(AgentMarkdown.render(source, theme: AppTheme(systemIsDark: false)))
        _ = view.height(for: 500)
        XCTAssertEqual(view.string, "•\tDisc\n◦\tCircle\n▪\tSquare\n•\tSecond")
        let manager = try XCTUnwrap(view.layoutManager)
        // Actual source DOM text origins and screenshot marker bounds, relative to the root.
        for (word, x, y) in [("Disc", 20.0, 0.0), ("Circle", 40.0, 33.140625), ("Square", 60.0, 66.28125), ("Second", 20.0, 99.421875)] {
            let range = (view.string as NSString).range(of: word)
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = manager.location(forGlyphAt: glyph)
            XCTAssertEqual(fragment.minX + location.x, x, accuracy: 0.001, word)
            XCTAssertEqual(fragment.minY + location.y, y + 16, accuracy: 0.001, word)
            let rect = AgentListBullet.rect(textX: x, baseline: y + 16, font: AppFont.system(14))
            XCTAssertEqual(rect, NSRect(x: x - 16, y: floor(y + 9), width: 5, height: 5))
        }
        XCTAssertEqual(AgentListBullet.rect(textX: 20, baseline: 14, font: AppFont.system(12)), NSRect(x: 5, y: 8, width: 4, height: 4))
    }

    func testNativeBulletSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let root = BulletFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            root.wantsLayer = true; root.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1) : .white).cgColor
            let response = AgentResponseView(frame: .zero)
            response.setContent("- Disc\n  - Circle\n    - Square\n- Second", theme: theme)
            response.frame = NSRect(x: 20, y: 20, width: 460, height: response.height(for: 460))
            root.addSubview(response)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = root
            defer { window.close() }
            root.layoutSubtreeIfNeeded()
            let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let bitmap = raw.retagging(with: .sRGB) ?? raw
            bitmap.size = root.bounds.size
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("bullet-markers-\(dark).png"))
        }
    }

    func testNativeOrderedListSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let root = BulletFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            root.wantsLayer = true; root.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1) : .white).cgColor
            let response = AgentResponseView(frame: .zero)
            response.setContent("1. One\n2. Two\n\nParagraph\n\n9. Nine\n10. Ten\n\nParagraph\n\n99. Outer\n    - Nested\n100. Next", theme: theme)
            response.frame = NSRect(x: 20, y: 20, width: 460, height: response.height(for: 460))
            root.addSubview(response)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = root
            defer { window.close() }
            root.layoutSubtreeIfNeeded()
            let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let bitmap = raw.retagging(with: .sRGB) ?? raw
            bitmap.size = root.bounds.size
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("ordered-markers-\(dark).png"))
        }
    }

    func testNativeRichListSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let root = BulletFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
            root.wantsLayer = true; root.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1) : .white).cgColor
            let response = AgentResponseView(frame: .zero)
            response.setContent("99. First\n\n    ```swift\n    let value = 1\n    ```\n\n100. Next\n\nParagraph\n\n9. First\n10. Table\n\n    | A | B |\n    | - | - |\n    | x | y |\n\n11. Last", theme: theme)
            response.frame = NSRect(x: 20, y: 20, width: 560, height: response.height(for: 560))
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
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("rich-list-markers-\(dark).png"))
        }
    }

    func testOrderedListGuttersMatchSource() throws {
        struct Fixture: Decodable {
            struct Item: Decodable { let text: String; let x: Double }
            let source: String; let items: [Item]
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.gutterOracle.utf8))
        for fixture in fixtures {
            let view = AgentRichTextView(frame: .zero)
            view.setContent(AgentMarkdown.render(fixture.source, theme: AppTheme(systemIsDark: false)))
            _ = view.height(for: 500)
            let manager = try XCTUnwrap(view.layoutManager)
            for item in fixture.items {
                let range = (view.string as NSString).range(of: item.text)
                XCTAssertNotEqual(range.location, NSNotFound)
                let glyph = manager.glyphIndexForCharacter(at: range.location)
                XCTAssertEqual(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x, item.x, accuracy: 0.001, fixture.source + " / " + item.text)
            }
        }
    }

    private static let gutterOracle = ########"""
    [
      {
        "source": "1. One\n2. Two",
        "items": [
          {
            "text": "One",
            "x": 20,
            "y": 2,
            "padding": "20px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          },
          {
            "text": "Two",
            "x": 20,
            "y": 28.75,
            "padding": "20px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          }
        ]
      },
      {
        "source": "9. Nine\n10. Ten",
        "items": [
          {
            "text": "Nine",
            "x": 35.265625,
            "y": 2,
            "padding": "35.2734px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          },
          {
            "text": "Ten",
            "x": 35.265625,
            "y": 28.75,
            "padding": "35.2734px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          }
        ]
      },
      {
        "source": "99. Ninety-nine\n100. Hundred",
        "items": [
          {
            "text": "Ninety-nine",
            "x": 44.078125,
            "y": 2,
            "padding": "44.0918px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          },
          {
            "text": "Hundred",
            "x": 44.078125,
            "y": 28.75,
            "padding": "44.0918px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          }
        ]
      },
      {
        "source": "1. Outer\n   1. Inner\n   2. Next",
        "items": [
          {
            "text": "Outer",
            "x": 20,
            "y": 2,
            "padding": "20px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          },
          {
            "text": "Inner",
            "x": 40,
            "y": 35.140625,
            "padding": "20px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          },
          {
            "text": "Next",
            "x": 40,
            "y": 61.890625,
            "padding": "20px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          }
        ]
      },
      {
        "source": "99. Outer\n    - Nested\n100. Next",
        "items": [
          {
            "text": "Outer",
            "x": 44.078125,
            "y": 2,
            "padding": "44.0918px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          },
          {
            "text": "Nested",
            "x": 64.078125,
            "y": 35.140625,
            "padding": "20px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          },
          {
            "text": "Next",
            "x": 44.078125,
            "y": 68.28125,
            "padding": "44.0918px",
            "font": "14px / 22.75px -apple-system, \"system-ui\", \"Inter Variable\", \"Segoe UI\", system-ui, sans-serif"
          }
        ]
      }
    ]
    """########

    func testRichListGuttersSurviveSectionPartitioningAndStreaming() throws {
        struct Fixture: Decodable {
            struct Item: Decodable { let text: String; let x: Double }
            let source: String; let items: [Item]
        }
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.richGutterOracle.utf8))
        let response = AgentResponseView(frame: .zero)
        let theme = AppTheme(systemIsDark: false)
        func position(_ word: String) throws -> CGFloat {
            func texts(_ view: NSView) -> [AgentRichTextView] {
                if let text = view as? AgentRichTextView { return [text] }
                return view.subviews.flatMap(texts)
            }
            response.frame = NSRect(x: 0, y: 0, width: 500, height: response.height(for: 500))
            response.layoutSubtreeIfNeeded()
            let text = try XCTUnwrap(texts(response).first { $0.string.contains(word) })
            let manager = try XCTUnwrap(text.layoutManager)
            let range = (text.string as NSString).range(of: word)
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            return text.convert(NSPoint.zero, to: response).x + manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x
        }
        // Appending the 100th counter must widen the existing rich section too.
        response.setContent(fixtures[0].source.components(separatedBy: "\n\n100.")[0], theme: theme)
        XCTAssertEqual(try position("First"), 35.265625, accuracy: 0.001)
        for fixture in fixtures {
            response.setContent(fixture.source, theme: theme)
            for item in fixture.items {
                XCTAssertEqual(try position(item.text), item.x, accuracy: 0.001, item.text)
            }
        }
    }

    private static let richGutterOracle = ########"""
    [
      {
        "source": "99. First\n\n    ```swift\n    let value = 1\n    ```\n\n100. Next",
        "items": [
          {
            "text": "First",
            "x": 44.078125
          },
          {
            "text": "Next",
            "x": 44.078125
          }
        ]
      },
      {
        "source": "9. First\n10. Table\n\n    | A | B |\n    | - | - |\n    | x | y |\n\n11. Last",
        "items": [
          {
            "text": "First",
            "x": 35.265625
          },
          {
            "text": "Table",
            "x": 35.265625
          },
          {
            "text": "Last",
            "x": 35.265625
          }
        ]
      }
    ]
    """########

    // source e5909e53 DOM: OL start/index and computed list-style-type, with native glyph labels.
    private static let oracle = ########"""
    [
      {
        "source": "1. One\n1. Two\n1. Three",
        "items": [
          {
            "text": "One",
            "kind": "OL",
            "style": "decimal",
            "number": 1,
            "marker": "1."
          },
          {
            "text": "Two",
            "kind": "OL",
            "style": "decimal",
            "number": 2,
            "marker": "2."
          },
          {
            "text": "Three",
            "kind": "OL",
            "style": "decimal",
            "number": 3,
            "marker": "3."
          }
        ]
      },
      {
        "source": "3. Three\n9. Four\n2. Five",
        "items": [
          {
            "text": "Three",
            "kind": "OL",
            "style": "decimal",
            "number": 3,
            "marker": "3."
          },
          {
            "text": "Four",
            "kind": "OL",
            "style": "decimal",
            "number": 4,
            "marker": "4."
          },
          {
            "text": "Five",
            "kind": "OL",
            "style": "decimal",
            "number": 5,
            "marker": "5."
          }
        ]
      },
      {
        "source": "1. One\n\n1. Two",
        "items": [
          {
            "text": "One",
            "kind": "OL",
            "style": "decimal",
            "number": 1,
            "marker": "1."
          },
          {
            "text": "Two",
            "kind": "OL",
            "style": "decimal",
            "number": 2,
            "marker": "2."
          }
        ]
      },
      {
        "source": "1. One\n\nParagraph\n\n7. Seven",
        "items": [
          {
            "text": "One",
            "kind": "OL",
            "style": "decimal",
            "number": 1,
            "marker": "1."
          },
          {
            "text": "Seven",
            "kind": "OL",
            "style": "decimal",
            "number": 7,
            "marker": "7."
          }
        ]
      },
      {
        "source": "1. One\n   1. Inner\n   1. Next\n2. Two",
        "items": [
          {
            "text": "One",
            "kind": "OL",
            "style": "decimal",
            "number": 1,
            "marker": "1."
          },
          {
            "text": "Inner",
            "kind": "OL",
            "style": "lower-alpha",
            "number": 1,
            "marker": "a."
          },
          {
            "text": "Next",
            "kind": "OL",
            "style": "lower-alpha",
            "number": 2,
            "marker": "b."
          },
          {
            "text": "Two",
            "kind": "OL",
            "style": "decimal",
            "number": 2,
            "marker": "2."
          }
        ]
      },
      {
        "source": "1. One\n   1. Inner\n      1. Deep\n      1. Next",
        "items": [
          {
            "text": "One",
            "kind": "OL",
            "style": "decimal",
            "number": 1,
            "marker": "1."
          },
          {
            "text": "Inner",
            "kind": "OL",
            "style": "lower-alpha",
            "number": 1,
            "marker": "a."
          },
          {
            "text": "Deep",
            "kind": "OL",
            "style": "lower-roman",
            "number": 1,
            "marker": "i."
          },
          {
            "text": "Next",
            "kind": "OL",
            "style": "lower-roman",
            "number": 2,
            "marker": "ii."
          }
        ]
      },
      {
        "source": "- One\n  - Inner\n    - Deep",
        "items": [
          {
            "text": "One",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          },
          {
            "text": "Inner",
            "kind": "UL",
            "style": "circle",
            "number": null,
            "marker": "\u25e6"
          },
          {
            "text": "Deep",
            "kind": "UL",
            "style": "square",
            "number": null,
            "marker": "\u25aa"
          }
        ]
      },
      {
        "source": "1. One\n2) New delimiter\n7) Next",
        "items": [
          {
            "text": "One",
            "kind": "OL",
            "style": "decimal",
            "number": 1,
            "marker": "1."
          },
          {
            "text": "New delimiter",
            "kind": "OL",
            "style": "decimal",
            "number": 2,
            "marker": "2."
          },
          {
            "text": "Next",
            "kind": "OL",
            "style": "decimal",
            "number": 3,
            "marker": "3."
          }
        ]
      },
      {
        "source": "- One\n* Two\n+ Three",
        "items": [
          {
            "text": "One",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          },
          {
            "text": "Two",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          },
          {
            "text": "Three",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          }
        ]
      },
      {
        "source": "-\n- empty next",
        "items": [
          {
            "text": "",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          },
          {
            "text": "empty next",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          }
        ]
      },
      {
        "source": "-\tTabbed\n- second",
        "items": [
          {
            "text": "Tabbed",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          },
          {
            "text": "second",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          }
        ]
      },
      {
        "source": "- outer\n  - nested\n    3. deep\n      continuation",
        "items": [
          {
            "text": "outer",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          },
          {
            "text": "nested\n3. deep\ncontinuation",
            "kind": "UL",
            "style": "circle",
            "number": null,
            "marker": "\u25e6"
          }
        ]
      },
      {
        "source": "1. Outer\n   - Bullet\n     27. Nested\n     1. Next",
        "items": [
          {
            "text": "Outer",
            "kind": "OL",
            "style": "decimal",
            "number": 1,
            "marker": "1."
          },
          {
            "text": "Bullet\n27. Nested",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          },
          {
            "text": "Next",
            "kind": "OL",
            "style": "lower-alpha",
            "number": 1,
            "marker": "a."
          }
        ]
      },
      {
        "source": "1. Outer\n   - Bullet\n\n     27. Nested\n     1. Next",
        "items": [
          {
            "text": "Outer",
            "kind": "OL",
            "style": "decimal",
            "number": 1,
            "marker": "1."
          },
          {
            "text": "Bullet",
            "kind": "UL",
            "style": "disc",
            "number": null,
            "marker": "\u2022"
          },
          {
            "text": "Nested",
            "kind": "OL",
            "style": "lower-alpha",
            "number": 27,
            "marker": "aa."
          },
          {
            "text": "Next",
            "kind": "OL",
            "style": "lower-alpha",
            "number": 28,
            "marker": "ab."
          }
        ]
      }
    ]
    """########
}

private final class BulletFixture: NSView { override var isFlipped: Bool { true } }
