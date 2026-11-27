import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentTableCodeWrapTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Code: Decodable {
            struct Character: Decodable { let text: String; let x: Double; let y: Double }
            let chars: [Character]
        }
        let source: String; let width: Double; let codes: [Code]
    }

    func testCellCodePositionsAndLineBreaksMatchBrowser() throws {
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        for fixture in fixtures {
            let response = AgentResponseView(frame: .zero)
            response.setContent(fixture.source, theme: AppTheme(systemIsDark: false))
            response.frame = NSRect(x: 0, y: 0, width: fixture.width, height: response.height(for: fixture.width))
            response.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(response.subviews.first { $0 is AgentResponseTable } as? AgentResponseTable)
            let storage = try XCTUnwrap(table.text.textStorage)
            let manager = try XCTUnwrap(table.text.layoutManager)
            var spans: [NSRange] = []
            storage.enumerateAttribute(.agentInlineCodeIdentity, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value != nil { spans.append(range) }
            }
            XCTAssertEqual(spans.count, fixture.codes.count)
            for (span, code) in zip(spans, fixture.codes) {
                var firstY: CGFloat?
                for (offset, expected) in code.chars.enumerated() {
                    let index = span.location + offset
                    let glyph = manager.glyphIndexForCharacter(at: index)
                    let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let location = manager.location(forGlyphAt: glyph)
                    let y = fragment.minY + location.y
                    if firstY == nil { firstY = y }
                    if expected.text == " " { continue }
                    let padding = storage.attribute(.agentInlineCodeLeading, at: index, effectiveRange: nil) as? CGFloat ?? 0
                    // Allow subpixel optical-tracking differences in the light system font.
                    XCTAssertEqual(fragment.minX + location.x + padding, expected.x, accuracy: 0.2, fixture.source)
                    // TextKit table rows still round their outer height; compare the
                    // code's line spacing independently of that documented gap.
                    XCTAssertEqual(y - (firstY ?? 0), expected.y - (code.chars.first?.y ?? 0), accuracy: 0.001, fixture.source)
                }
            }
        }
    }

    func testNativeTableCodeSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let root = TableCodeFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        var x: CGFloat = 20
        for fixture in fixtures.prefix(2) {
            let response = AgentResponseView(frame: .zero)
            response.setContent(fixture.source, theme: theme)
            response.frame = NSRect(x: x, y: 20, width: fixture.width, height: response.height(for: fixture.width))
            root.addSubview(response); x += fixture.width + 40
        }
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 320,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = raw.retagging(with: .sRGB) ?? raw
        bitmap.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("wrapped-table-code.png"))
    }

    private static let oracle = ########"""
    [
      {
        "source": "| Value |\n| --- |\n| Before `alpha beta gamma delta` after |",
        "width": 140,
        "height": 102.21875,
        "codes": [
          {
            "chars": [
              {
                "text": "a",
                "x": 50.890625,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": "l",
                "x": 58.234375,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "p",
                "x": 65.59375,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "h",
                "x": 72.953125,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 80.3125,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 87.65625,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "b",
                "x": 95.015625,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "e",
                "x": 102.375,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 109.734375,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 117.09375,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 124.4375,
                "y": 53.53125,
                "width": 0
              },
              {
                "text": "g",
                "x": 5.15625,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "a",
                "x": 12.5,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 19.859375,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 27.21875,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 34.578125,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 41.921875,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "d",
                "x": 49.28125,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "e",
                "x": 56.640625,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "l",
                "x": 64,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 71.359375,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "a",
                "x": 78.703125,
                "y": 76.28125,
                "width": 7.375
              }
            ]
          }
        ]
      },
      {
        "source": "| A | B |\n| --- | --- |\n| Before `alpha beta gamma delta` after | Before `alpha beta gamma delta` after |",
        "width": 220,
        "height": 124.96875,
        "codes": [
          {
            "chars": [
              {
                "text": "a",
                "x": 50.890625,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": "l",
                "x": 58.234375,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "p",
                "x": 65.59375,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "h",
                "x": 72.953125,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 80.3125,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 87.65625,
                "y": 53.53125,
                "width": 0
              },
              {
                "text": "b",
                "x": 5.15625,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "e",
                "x": 12.5,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 19.859375,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 27.21875,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": " ",
                "x": 34.578125,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "g",
                "x": 41.921875,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 49.28125,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 56.640625,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 64,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 71.359375,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 78.703125,
                "y": 76.28125,
                "width": 0
              },
              {
                "text": "d",
                "x": 5.15625,
                "y": 99.03125,
                "width": 7.359375
              },
              {
                "text": "e",
                "x": 12.5,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "l",
                "x": 19.859375,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 27.21875,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 34.578125,
                "y": 99.03125,
                "width": 7.359375
              }
            ]
          },
          {
            "chars": [
              {
                "text": "a",
                "x": 172.890625,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": "l",
                "x": 180.234375,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "p",
                "x": 187.59375,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "h",
                "x": 194.953125,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 202.3125,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 209.65625,
                "y": 53.53125,
                "width": 0
              },
              {
                "text": "b",
                "x": 127.15625,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "e",
                "x": 134.5,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 141.859375,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 149.21875,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": " ",
                "x": 156.578125,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "g",
                "x": 163.921875,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 171.28125,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 178.640625,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 186,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 193.359375,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 200.703125,
                "y": 76.28125,
                "width": 0
              },
              {
                "text": "d",
                "x": 127.15625,
                "y": 99.03125,
                "width": 7.359375
              },
              {
                "text": "e",
                "x": 134.5,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "l",
                "x": 141.859375,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 149.21875,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 156.578125,
                "y": 99.03125,
                "width": 7.359375
              }
            ]
          }
        ]
      },
      {
        "source": "| A | B |\n| :---: | ---: |\n| Before `alpha beta gamma delta` after | Before `alpha beta gamma delta` after |",
        "width": 220,
        "height": 124.96875,
        "codes": [
          {
            "chars": [
              {
                "text": "a",
                "x": 53.46875,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": "l",
                "x": 60.8125,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "p",
                "x": 68.171875,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "h",
                "x": 75.53125,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 82.890625,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 90.234375,
                "y": 53.53125,
                "width": 0
              },
              {
                "text": "b",
                "x": 12.21875,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "e",
                "x": 19.5625,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 26.921875,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 34.28125,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": " ",
                "x": 41.640625,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "g",
                "x": 48.984375,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 56.34375,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 63.703125,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 71.0625,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 78.421875,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 85.765625,
                "y": 76.28125,
                "width": 0
              },
              {
                "text": "d",
                "x": 13.765625,
                "y": 99.03125,
                "width": 7.359375
              },
              {
                "text": "e",
                "x": 21.109375,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "l",
                "x": 28.46875,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 35.828125,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 43.1875,
                "y": 99.03125,
                "width": 7.359375
              }
            ]
          },
          {
            "chars": [
              {
                "text": "a",
                "x": 178.0625,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": "l",
                "x": 185.40625,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "p",
                "x": 192.765625,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "h",
                "x": 200.125,
                "y": 53.53125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 207.484375,
                "y": 53.53125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 214.828125,
                "y": 53.53125,
                "width": 0
              },
              {
                "text": "b",
                "x": 141.28125,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "e",
                "x": 148.625,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 155.984375,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 163.34375,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": " ",
                "x": 170.703125,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": "g",
                "x": 178.046875,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 185.40625,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 192.765625,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "m",
                "x": 200.125,
                "y": 76.28125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 207.484375,
                "y": 76.28125,
                "width": 7.359375
              },
              {
                "text": " ",
                "x": 214.828125,
                "y": 76.28125,
                "width": 0
              },
              {
                "text": "d",
                "x": 144.375,
                "y": 99.03125,
                "width": 7.359375
              },
              {
                "text": "e",
                "x": 151.71875,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "l",
                "x": 159.078125,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "t",
                "x": 166.4375,
                "y": 99.03125,
                "width": 7.375
              },
              {
                "text": "a",
                "x": 173.796875,
                "y": 99.03125,
                "width": 7.359375
              }
            ]
          }
        ]
      }
    ]
    """########
}

private final class TableCodeFixture: NSView { override var isFlipped: Bool { true } }
