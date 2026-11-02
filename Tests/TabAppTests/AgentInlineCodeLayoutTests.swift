import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentInlineCodeLayoutTests: XCTestCase {
    func testInlineCodeBoxesMatchBrowserWithoutChangingSelection() throws {
        struct Fixture: Decodable {
            struct Code: Decodable { let text: String; let x: Double; let width: Double; let textX: Double; let y: Double; let height: Double; let ascent: Double; let descent: Double }
            let source: String; let text: String; let codes: [Code]
        }
        _ = NSApplication.shared
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.oracle.utf8))
        for (fixture, systemFont) in fixtures.flatMap({ [($0, false), ($0, true)] }) {
            let view = AgentRichTextView(frame: .zero)
            view.setContent(render(fixture.source, systemFont: systemFont))
            _ = view.height(for: 500)
            XCTAssertEqual(view.string, fixture.text)
            let manager = try XCTUnwrap(view.layoutManager)
            let container = try XCTUnwrap(view.textContainer)
            var spans: [NSRange] = []
            view.textStorage?.enumerateAttribute(.agentInlineCodeIdentity, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
                if value != nil { spans.append(range) }
            }
            XCTAssertEqual(spans.count, fixture.codes.count)
            for (span, code) in zip(spans, fixture.codes) {
                let glyphs = manager.glyphRange(forCharacterRange: span, actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                let size = view.textStorage?.attribute(.agentExternalLinkFontSize, at: span.location, effectiveRange: nil) as? CGFloat
                let icon = size.map { AgentExternalLinkLayout.inset(fontSize: $0) } ?? 0
                let padding = view.textStorage?.attribute(.agentInlineCodeLeading, at: span.location, effectiveRange: nil) as? CGFloat ?? 0
                // Chromium and AppKit light system fonts differ slightly in optical tracking.
                XCTAssertEqual(rect.minX + icon, code.x, accuracy: 0.2, fixture.source)
                XCTAssertEqual(rect.width - icon, code.width, accuracy: 0.05, fixture.source)
                XCTAssertEqual(rect.minX + icon + padding, code.textX, accuracy: 0.2, fixture.source)
                let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: span.location, effectiveRange: nil) as? NSFont)
                let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let baseline = fragment.minY + manager.location(forGlyphAt: glyphs.location).y
                let background = AgentInlineCodeLayout.backgroundRect(x: rect.minX + icon, width: rect.width - icon, baseline: baseline, font: font)
                // TextKit can shift heading baselines by one point when the fallback
                // descent differs from SF Mono. Keep the named-face oracle exact.
                let baselineAccuracy = font.fontName.hasPrefix("SFMono-") ? 0.001 : 1.001
                XCTAssertEqual(background.minY, code.y + code.ascent - font.ascender.rounded(), accuracy: baselineAccuracy, fixture.source)
                XCTAssertEqual(background.height, code.height - code.ascent - code.descent + font.ascender.rounded() + (-font.descender).rounded(), accuracy: 0.001, fixture.source)
                view.setSelectedRange(span)
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                XCTAssertTrue(view.writeSelection(to: pasteboard, type: NSPasteboard.PasteboardType("NSStringPboardType")))
                XCTAssertEqual(pasteboard.string(forType: .string), code.text)
                _ = view.height(for: 120)
                XCTAssertEqual(view.selectedRange(), span)
                _ = view.height(for: 500)
            }
        }
    }

    func testCodeWordsWrapAtBrowserWordBoundaries() throws {
        for (source, width, expected) in [
            ("Before `alpha beta gamma delta` after", 140.0, ["alpha beta ", "gamma delta"]),
            ("Before `abcdefghijklmno` after", 100.0, ["abcdefghijkl", "mno"]),
            ("`alpha beta gamma delta`", 100.0, ["alpha beta ", "gamma delta"])
        ] {
            let view = AgentRichTextView(frame: .zero)
            view.setContent(AgentMarkdown.render(source, theme: AppTheme(systemIsDark: false)))
            _ = view.height(for: width)
            let storage = try XCTUnwrap(view.textStorage)
            let manager = try XCTUnwrap(view.layoutManager)
            var lines: [String] = []
            var lastY: CGFloat?
            for index in 0..<storage.length where storage.attribute(.agentInlineCodeIdentity, at: index, effectiveRange: nil) != nil {
                let glyph = manager.glyphIndexForCharacter(at: index)
                let y = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                if lastY != y { lines.append(""); lastY = y }
                lines[lines.count - 1] += (storage.string as NSString).substring(with: NSRange(location: index, length: 1))
            }
            XCTAssertEqual(lines, expected, source)
        }
    }

    func testWrappedCodeGlyphPositionsMatchBrowser() throws {
        struct Fixture: Decodable {
            struct Character: Decodable { let text: String; let x: Double; let y: Double }
            struct Fragment: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
            let source: String; let width: Double; let height: Double; let chars: [Character]; let fragments: [Fragment]?
        }
        let fixtures = try [Self.wrapOracle, Self.listWrapOracle].flatMap { try JSONDecoder().decode([Fixture].self, from: Data($0.utf8)) }
        for (fixture, systemFont) in fixtures.flatMap({ [($0, false), ($0, true)] }) {
            let view = AgentRichTextView(frame: .zero)
            view.setContent(render(fixture.source, systemFont: systemFont))
            XCTAssertEqual(view.height(for: fixture.width), fixture.height, accuracy: 0.001, fixture.source)
            let storage = try XCTUnwrap(view.textStorage)
            let manager = try XCTUnwrap(view.layoutManager)
            var offset = 0
            for index in 0..<storage.length where storage.attribute(.agentInlineCodeIdentity, at: index, effectiveRange: nil) != nil {
                let expected = fixture.chars[offset]; offset += 1
                if expected.text == " " { continue }
                let glyph = manager.glyphIndexForCharacter(at: index)
                let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let location = manager.location(forGlyphAt: glyph)
                let font = try XCTUnwrap(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                let padding = storage.attribute(.agentInlineCodeLeading, at: index, effectiveRange: nil) as? CGFloat ?? 0
                let iconSize = storage.attribute(.agentExternalLinkFontSize, at: index, effectiveRange: nil) as? CGFloat
                let icon = iconSize.map { AgentExternalLinkLayout.inset(fontSize: $0) } ?? 0
                XCTAssertEqual(fragment.minX + location.x + padding + icon, expected.x, accuracy: 0.2, fixture.source + " / " + String(offset))
                XCTAssertEqual(fragment.minY + location.y - font.ascender.rounded(), expected.y + 11 - font.ascender.rounded(), accuracy: 0.001, fixture.source)
            }
            XCTAssertEqual(offset, fixture.chars.count)
            guard let fragments = fixture.fragments else { continue }
            var codeRange = NSRange()
            storage.enumerateAttribute(.agentInlineCodeIdentity, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if value != nil { codeRange = range; stop.pointee = true }
            }
            let allGlyphs = manager.glyphRange(forCharacterRange: codeRange, actualCharacterRange: nil)
            let container = try XCTUnwrap(view.textContainer)
            let font = try XCTUnwrap(storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
            var fragmentIndex = 0
            manager.enumerateLineFragments(forGlyphRange: allGlyphs) { line, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(allGlyphs, lineGlyphs)
                let painted = NSMaxRange(part) < NSMaxRange(allGlyphs) ? AgentInlineCodeLayout.visibleGlyphs(part, manager: manager, storage: storage) : part
                let used = manager.boundingRect(forGlyphRange: painted, in: container)
                let char = manager.characterIndexForGlyph(at: part.location)
                let iconSize = storage.attribute(.agentExternalLinkFontSize, at: char, effectiveRange: nil) as? CGFloat
                let icon = iconSize.map { AgentExternalLinkLayout.inset(fontSize: $0) } ?? 0
                let leading = part.location > allGlyphs.location ? AgentInlineCodeLayout.inset(font: font) : 0
                let trailing = NSMaxRange(part) < NSMaxRange(allGlyphs) ? AgentInlineCodeLayout.inset(font: font) : 0
                let background = AgentInlineCodeLayout.backgroundRect(x: used.minX + icon - leading, width: used.width - icon + leading + trailing,
                    baseline: line.minY + manager.location(forGlyphAt: part.location).y, font: font)
                let expected = fragments[fragmentIndex]; fragmentIndex += 1
                XCTAssertEqual(background.minX, expected.x, accuracy: 0.2, fixture.source)
                XCTAssertEqual(background.minY, expected.y + 11 - font.ascender.rounded(), accuracy: 0.001, fixture.source)
                XCTAssertEqual(background.width, expected.width, accuracy: 0.05, fixture.source)
                XCTAssertEqual(background.height, expected.height - 14 + font.ascender.rounded() + (-font.descender).rounded(), accuracy: 0.001, fixture.source)
            }
            XCTAssertEqual(fragmentIndex, fragments.count)
        }
    }

    // The browser fixtures use SF Mono (11px ascent / 3px descent at 11.9pt).
    // That optional face isn't installed on clean Macs, including CI runners.
    // Exercise the fallback locally too; only vertical ink bounds depend on the face.
    private func render(_ source: String, systemFont: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: AgentMarkdown.render(source, theme: AppTheme(systemIsDark: false)))
        if systemFont {
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let font = value as? NSFont,
                      text.attribute(.agentInlineCodeIdentity, at: range.location, effectiveRange: nil) != nil else { return }
                let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
                let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
                text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: NSFont.Weight(rawValue: weight)), range: range)
            }
        }
        return text
    }

    private static let listWrapOracle = ########"""
    [
      {
        "source": "- Before `alpha beta gamma delta` after",
        "width": 140,
        "height": 68.25,
        "chars": [
          {
            "text": "a",
            "x": 70.890625,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": "l",
            "x": 78.234375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "p",
            "x": 85.59375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "h",
            "x": 92.953125,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 100.3125,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 107.65625,
            "y": 5,
            "width": 0
          },
          {
            "text": "b",
            "x": 25.15625,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "e",
            "x": 32.5,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 39.859375,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 47.21875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": " ",
            "x": 54.578125,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "g",
            "x": 61.921875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 69.28125,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 76.640625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 84,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 91.359375,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 98.703125,
            "y": 27.75,
            "width": 0
          },
          {
            "text": "d",
            "x": 25.15625,
            "y": 50.5,
            "width": 7.359375
          },
          {
            "text": "e",
            "x": 32.5,
            "y": 50.5,
            "width": 7.375
          },
          {
            "text": "l",
            "x": 39.859375,
            "y": 50.5,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 47.21875,
            "y": 50.5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 54.578125,
            "y": 50.5,
            "width": 7.359375
          }
        ]
      },
      {
        "source": "- Outer\n  - Before `alpha beta gamma delta` after",
        "width": 180,
        "height": 78.640625,
        "chars": [
          {
            "text": "a",
            "x": 90.890625,
            "y": 38.140625,
            "width": 7.359375
          },
          {
            "text": "l",
            "x": 98.234375,
            "y": 38.140625,
            "width": 7.375
          },
          {
            "text": "p",
            "x": 105.59375,
            "y": 38.140625,
            "width": 7.375
          },
          {
            "text": "h",
            "x": 112.953125,
            "y": 38.140625,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 120.3125,
            "y": 38.140625,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 127.65625,
            "y": 38.140625,
            "width": 7.375
          },
          {
            "text": "b",
            "x": 135.015625,
            "y": 38.140625,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 142.375,
            "y": 38.140625,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 149.734375,
            "y": 38.140625,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 157.09375,
            "y": 38.140625,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 164.4375,
            "y": 38.140625,
            "width": 0
          },
          {
            "text": "g",
            "x": 45.15625,
            "y": 60.890625,
            "width": 7.359375
          },
          {
            "text": "a",
            "x": 52.5,
            "y": 60.890625,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 59.859375,
            "y": 60.890625,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 67.21875,
            "y": 60.890625,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 74.578125,
            "y": 60.890625,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 81.921875,
            "y": 60.890625,
            "width": 7.375
          },
          {
            "text": "d",
            "x": 89.28125,
            "y": 60.890625,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 96.640625,
            "y": 60.890625,
            "width": 7.375
          },
          {
            "text": "l",
            "x": 104,
            "y": 60.890625,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 111.359375,
            "y": 60.890625,
            "width": 7.359375
          },
          {
            "text": "a",
            "x": 118.703125,
            "y": 60.890625,
            "width": 7.375
          }
        ]
      },
      {
        "source": "99. Before `alpha beta gamma delta` after",
        "width": 166,
        "height": 45.5,
        "chars": [
          {
            "text": "a",
            "x": 86.15625,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": "l",
            "x": 93.5,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "p",
            "x": 100.859375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "h",
            "x": 108.21875,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 115.578125,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 122.921875,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "b",
            "x": 130.28125,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 137.640625,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 145,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 152.359375,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 159.703125,
            "y": 5,
            "width": 0
          },
          {
            "text": "g",
            "x": 40.421875,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "a",
            "x": 47.765625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 55.125,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 62.484375,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 69.84375,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 77.1875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "d",
            "x": 84.546875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 91.90625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "l",
            "x": 99.265625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 106.625,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "a",
            "x": 113.96875,
            "y": 27.75,
            "width": 7.375
          }
        ]
      },
      {
        "source": "- [ ] Before `alpha beta gamma delta` after",
        "width": 140,
        "height": 68.25,
        "chars": [
          {
            "text": "a",
            "x": 72.4375,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": "l",
            "x": 79.78125,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "p",
            "x": 87.140625,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "h",
            "x": 94.5,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 101.859375,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 109.203125,
            "y": 5,
            "width": 0
          },
          {
            "text": "b",
            "x": 25.15625,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "e",
            "x": 32.5,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 39.859375,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 47.21875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": " ",
            "x": 54.578125,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "g",
            "x": 61.921875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 69.28125,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 76.640625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 84,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 91.359375,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 98.703125,
            "y": 27.75,
            "width": 0
          },
          {
            "text": "d",
            "x": 25.15625,
            "y": 50.5,
            "width": 7.359375
          },
          {
            "text": "e",
            "x": 32.5,
            "y": 50.5,
            "width": 7.375
          },
          {
            "text": "l",
            "x": 39.859375,
            "y": 50.5,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 47.21875,
            "y": 50.5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 54.578125,
            "y": 50.5,
            "width": 7.359375
          }
        ]
      }
    ]
    """########

    private static let wrapOracle = ########"""
    [
      {
        "source": "Before `alpha beta gamma delta` after",
        "width": 140,
        "height": 45.5,
        "fragments": [
          {
            "x": 45.734375,
            "y": 2.8125,
            "width": 83.875,
            "height": 18.375
          },
          {
            "x": 0,
            "y": 25.5625,
            "width": 91.234375,
            "height": 18.375
          }
        ],
        "chars": [
          {
            "text": "a",
            "x": 50.890625,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": "l",
            "x": 58.234375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "p",
            "x": 65.59375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "h",
            "x": 72.953125,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 80.3125,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 87.65625,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "b",
            "x": 95.015625,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 102.375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 109.734375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 117.09375,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 124.4375,
            "y": 5,
            "width": 0
          },
          {
            "text": "g",
            "x": 5.15625,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "a",
            "x": 12.5,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 19.859375,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 27.21875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 34.578125,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 41.921875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "d",
            "x": 49.28125,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 56.640625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "l",
            "x": 64,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 71.359375,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "a",
            "x": 78.703125,
            "y": 27.75,
            "width": 7.375
          }
        ]
      },
      {
        "source": "Before `abcdefghijklmno` after",
        "width": 100,
        "height": 68.25,
        "fragments": [
          {
            "x": 0,
            "y": 25.5625,
            "width": 98.59375,
            "height": 18.375
          },
          {
            "x": 0,
            "y": 48.3125,
            "width": 32.390625,
            "height": 18.375
          }
        ],
        "chars": [
          {
            "text": "a",
            "x": 5.15625,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "b",
            "x": 12.5,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "c",
            "x": 19.859375,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "d",
            "x": 27.21875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 34.578125,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "f",
            "x": 41.921875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "g",
            "x": 49.28125,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "h",
            "x": 56.640625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "i",
            "x": 64,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "j",
            "x": 71.359375,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "k",
            "x": 78.703125,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "l",
            "x": 86.0625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 5.15625,
            "y": 50.5,
            "width": 7.359375
          },
          {
            "text": "n",
            "x": 12.5,
            "y": 50.5,
            "width": 7.375
          },
          {
            "text": "o",
            "x": 19.859375,
            "y": 50.5,
            "width": 7.375
          }
        ]
      },
      {
        "source": "`alpha beta gamma delta`",
        "width": 100,
        "height": 45.5,
        "fragments": [
          {
            "x": 0,
            "y": 2.8125,
            "width": 83.875,
            "height": 18.375
          },
          {
            "x": 0,
            "y": 25.5625,
            "width": 91.234375,
            "height": 18.375
          }
        ],
        "chars": [
          {
            "text": "a",
            "x": 5.15625,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": "l",
            "x": 12.5,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "p",
            "x": 19.859375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "h",
            "x": 27.21875,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 34.578125,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 41.921875,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "b",
            "x": 49.28125,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 56.640625,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 64,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 71.359375,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 78.703125,
            "y": 5,
            "width": 0
          },
          {
            "text": "g",
            "x": 5.15625,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "a",
            "x": 12.5,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 19.859375,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "m",
            "x": 27.21875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 34.578125,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 41.921875,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "d",
            "x": 49.28125,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 56.640625,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "l",
            "x": 64,
            "y": 27.75,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 71.359375,
            "y": 27.75,
            "width": 7.359375
          },
          {
            "text": "a",
            "x": 78.703125,
            "y": 27.75,
            "width": 7.375
          }
        ]
      },
      {
        "source": "Text [`alpha beta`](https://localhost) tail",
        "width": 140,
        "height": 45.5,
        "fragments": [
          {
            "x": 50.6875,
            "y": 2.8125,
            "width": 83.875,
            "height": 18.375
          }
        ],
        "chars": [
          {
            "text": "a",
            "x": 55.84375,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": "l",
            "x": 63.1875,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "p",
            "x": 70.546875,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "h",
            "x": 77.90625,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 85.265625,
            "y": 5,
            "width": 7.359375
          },
          {
            "text": " ",
            "x": 92.609375,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "b",
            "x": 99.96875,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "e",
            "x": 107.328125,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "t",
            "x": 114.6875,
            "y": 5,
            "width": 7.375
          },
          {
            "text": "a",
            "x": 122.046875,
            "y": 5,
            "width": 7.359375
          }
        ]
      }
    ]
    """########

    func testAdjacentCodeSpansContributeSeparatePaddingToTableSizing() {
        let text = AgentMarkdown.inline("`a`**`b`**", theme: AppTheme(systemIsDark: false))
        XCTAssertEqual(text.string, "ab")
        XCTAssertEqual(AgentInlineCodeLayout.additionalWidth(text), 20.625, accuracy: 0.001)
    }

    func testNativeInlineCodeSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let root = InlineCodeFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
            root.wantsLayer = true; root.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1) : .white).cgColor
            let response = AgentResponseView(frame: .zero)
            response.setContent("Before `x` after\n\nBefore `foo` after\n\n**`bold`** tail\n\n[`a`](https://localhost) tail\n\n`a` `b` tail", theme: theme)
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
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("inline-code-padding-\(dark).png"))
        }
    }

    func testNativeWrappedCodeSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let root = InlineCodeFixture(frame: NSRect(x: 0, y: 0, width: 700, height: 260))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        var x: CGFloat = 20
        for (source, width) in [("Before `alpha beta gamma delta` after", 140.0), ("Before `abcdefghijklmno` after", 100.0), ("`alpha beta gamma delta`", 100.0), ("Text [`alpha beta`](https://localhost) tail", 140.0)] {
            let response = AgentResponseView(frame: .zero)
            response.setContent(source, theme: theme)
            response.frame = NSRect(x: x, y: 20, width: width, height: response.height(for: width))
            root.addSubview(response); x += width + 30
        }
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 260,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = raw.retagging(with: .sRGB) ?? raw
        bitmap.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("wrapped-inline-code.png"))
    }

    func testNativeWrappedListCodeSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let root = InlineCodeFixture(frame: NSRect(x: 0, y: 0, width: 800, height: 280))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        var x: CGFloat = 20
        for (source, width) in [("- Before `alpha beta gamma delta` after", 140.0), ("- Outer\n  - Before `alpha beta gamma delta` after", 180.0), ("99. Before `alpha beta gamma delta` after", 160.0), ("- [ ] Before `alpha beta gamma delta` after", 140.0)] {
            let response = AgentResponseView(frame: .zero)
            response.setContent(source, theme: theme)
            response.frame = NSRect(x: x, y: 20, width: width, height: response.height(for: width))
            root.addSubview(response); x += width + 25
        }
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 280,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmap = raw.retagging(with: .sRGB) ?? raw
        bitmap.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("wrapped-list-code.png"))
    }

    private static let oracle = ########"""
    [
      {
        "source": "Before `x` after",
        "text": "Before x after",
        "codes": [
          {
            "font": "11.9px / 19.3375px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 11,
            "descent": 3,
            "text": "x",
            "x": 45.734375,
            "width": 17.671875,
            "textX": 50.890625,
            "textWidth": 7.359375,
            "y": 2.8125,
            "height": 18.375,
            "textY": 5,
            "textHeight": 14,
            "padding": "4.165px",
            "fontSize": "11.9px"
          }
        ]
      },
      {
        "source": "Before `foo` after",
        "text": "Before foo after",
        "codes": [
          {
            "font": "11.9px / 19.3375px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 11,
            "descent": 3,
            "text": "foo",
            "x": 45.734375,
            "width": 32.390625,
            "textX": 50.890625,
            "textWidth": 22.078125,
            "y": 2.8125,
            "height": 18.375,
            "textY": 5,
            "textHeight": 14,
            "padding": "4.165px",
            "fontSize": "11.9px"
          }
        ]
      },
      {
        "source": "**`bold`** tail",
        "text": "bold tail",
        "codes": [
          {
            "font": "600 11.9px / 19.3375px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 11,
            "descent": 3,
            "text": "bold",
            "x": 0,
            "width": 39.75,
            "textX": 5.15625,
            "textWidth": 29.4375,
            "y": 2.8125,
            "height": 18.375,
            "textY": 5,
            "textHeight": 14,
            "padding": "4.165px",
            "fontSize": "11.9px"
          }
        ]
      },
      {
        "source": "[`a`](https://localhost) tail",
        "text": "a tail",
        "codes": [
          {
            "font": "11.9px / 19.3375px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 11,
            "descent": 3,
            "text": "a",
            "x": 20.296875,
            "width": 17.671875,
            "textX": 25.453125,
            "textWidth": 7.359375,
            "y": 2.8125,
            "height": 18.375,
            "textY": 5,
            "textHeight": 14,
            "padding": "4.165px",
            "fontSize": "11.9px"
          }
        ]
      },
      {
        "source": "`a` `b` tail",
        "text": "a b tail",
        "codes": [
          {
            "font": "11.9px / 19.3375px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 11,
            "descent": 3,
            "text": "a",
            "x": 0,
            "width": 17.671875,
            "textX": 5.15625,
            "textWidth": 7.359375,
            "y": 2.8125,
            "height": 18.375,
            "textY": 5,
            "textHeight": 14,
            "padding": "4.165px",
            "fontSize": "11.9px"
          },
          {
            "font": "11.9px / 19.3375px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 11,
            "descent": 3,
            "text": "b",
            "x": 21.328125,
            "width": 17.671875,
            "textX": 26.484375,
            "textWidth": 7.359375,
            "y": 2.8125,
            "height": 18.375,
            "textY": 5,
            "textHeight": 14,
            "padding": "4.165px",
            "fontSize": "11.9px"
          }
        ]
      },
      {
        "source": "# `heading`",
        "text": "heading",
        "codes": [
          {
            "font": "600 17px / 22.1px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 16,
            "descent": 4,
            "text": "heading",
            "x": 0,
            "width": 87.4375,
            "textX": 6.9375,
            "textWidth": 73.5625,
            "y": 1.3125,
            "height": 25.375,
            "textY": 4,
            "textHeight": 20,
            "padding": "5.95px",
            "fontSize": "17px"
          }
        ]
      },
      {
        "source": "## `heading`",
        "text": "heading",
        "codes": [
          {
            "font": "600 15.3px / 19.89px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 15,
            "descent": 4,
            "text": "heading",
            "x": 0,
            "width": 78.90625,
            "textX": 6.34375,
            "textWidth": 66.21875,
            "y": 0.484375,
            "height": 24.03125,
            "textY": 3,
            "textHeight": 19,
            "padding": "5.355px",
            "fontSize": "15.3px"
          }
        ]
      },
      {
        "source": "### `heading`",
        "text": "heading",
        "codes": [
          {
            "font": "600 13.6px / 17.68px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 13,
            "descent": 3,
            "text": "heading",
            "x": 0,
            "width": 70.359375,
            "textX": 5.75,
            "textWidth": 58.859375,
            "y": 0.640625,
            "height": 20.71875,
            "textY": 3,
            "textHeight": 16,
            "padding": "4.76px",
            "fontSize": "13.6px"
          }
        ]
      },
      {
        "source": "#### `heading`",
        "text": "heading",
        "codes": [
          {
            "font": "600 11.9px / 15.47px ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace",
            "ascent": 11,
            "descent": 3,
            "text": "heading",
            "x": 0,
            "width": 61.8125,
            "textX": 5.15625,
            "textWidth": 51.5,
            "y": 0.8125,
            "height": 18.375,
            "textY": 3,
            "textHeight": 14,
            "padding": "4.165px",
            "fontSize": "11.9px"
          }
        ]
      }
    ]
    """########
}

private final class InlineCodeFixture: NSView { override var isFlipped: Bool { true } }
