import AppKit
import XCTest
@testable import TabApp

/// Keeps conversation glyphs and signature marks at consistent optical sizes.
@MainActor
final class IconOpticalSizeTests: XCTestCase {
    func testInlineSizeMatchesFormerSymbolsWithoutChangingFullSize() throws {
        let color = NSColor(white: 0.6, alpha: 1)
        func symbol(_ name: String, size: CGFloat) -> NSImage? {
            guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.8, weight: .regular, scale: .medium)) else { return nil }
            let glyph = s.size
            let scale = min(1, size / max(glyph.width, 1), size / max(glyph.height, 1))
            let fitted = NSSize(width: glyph.width * scale, height: glyph.height * scale)
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                s.draw(in: NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2, width: fitted.width, height: fitted.height))
                return true
            }
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect); color.setFill(); rect.fill(using: .sourceIn); return true
            }
            return tinted
        }
        let reference = try XCTUnwrap(symbol("wrench.adjustable", size: 14))
        let full = try XCTUnwrap(AppIcon.wrench.image(size: 14, scale: 1))
        let inline = try XCTUnwrap(AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale))
        let expected = reference.inkBounds, actual = inline.inkBounds
        for (value, target) in [(actual.width, expected.width), (actual.height, expected.height),
                                (actual.minX, expected.minX), (actual.minY, expected.minY)] {
            XCTAssertEqual(value, target, accuracy: 1)
        }
        XCTAssertEqual(full.inkBounds, NSRect(x: 0, y: 0, width: 14, height: 14))
        XCTAssertTrue(full === AppIcon.wrench.image(size: 14))
        XCTAssertFalse(full === inline)
        XCTAssertEqual(inline.size, full.size)
        for image in [AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale, color: color),
                      AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale, hue: .gray, theme: .shared),
                      AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale, theme: .shared),
                      AppIcon.wrench.image(size: 14, scale: AppIcon.inlineScale, theme: .shared, tint: color)] {
            XCTAssertEqual(try XCTUnwrap(image).inkBounds, actual)
        }
    }

    func testSignatureMarksShareDuoFrameAndGlyphSize() throws {
        let documents: Set<AppIcon> = [.file, .fileSymlink, .fileTable, .fileText, .folder, .folderOpen,
                                      .slides, .spreadsheet, .video, .zip, .dot]
        let marks = Set(AppIcon.signatureHues.keys).subtracting(documents)
        let scale = 8
        let pixels = 16 * scale
        for icon in marks.sorted(by: { $0.rawValue < $1.rawValue }) {
            let image = try XCTUnwrap(icon.image(size: 16, color: .black), icon.rawValue)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: pixels * 4, bitsPerPixel: 32
            ))
            bitmap.size = NSSize(width: 16, height: 16)
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
            let data = try XCTUnwrap(bitmap.bitmapData)
            func inkSize(alpha: UInt8) -> NSSize {
                var minX = pixels, maxX = -1, minY = pixels, maxY = -1
                for y in 0..<pixels {
                    for x in 0..<pixels where data[y * bitmap.bytesPerRow + x * 4 + 3] > alpha {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
                guard maxX >= minX, maxY >= minY else { return .zero }
                return NSSize(width: CGFloat(maxX + 1 - minX) / CGFloat(scale),
                              height: CGFloat(maxY + 1 - minY) / CGFloat(scale))
            }
            let full = inkSize(alpha: 12), solid = inkSize(alpha: 127)
            XCTAssertEqual(full.width, 16, accuracy: 0.5, icon.rawValue)
            XCTAssertEqual(full.height, 16, accuracy: 0.5, icon.rawValue)
            let largerSide = max(solid.width, solid.height)
            XCTAssertGreaterThanOrEqual(largerSide, 9.75, icon.rawValue)
            XCTAssertLessThanOrEqual(largerSide, 10.75, icon.rawValue)
        }
    }
}
