import AppKit
import CoreText
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    private typealias F = TerminalFixtures

    func testStyleColorsDecorationsFaintAndInvisible() {
        let renderer = CoreTextRenderer()
        let state = TerminalRendererTests().state(F.grid([[]], cols: 12, cursor: Cursor(visible: false)))
        var style = Style()
        style.fg = .indexed(1)
        style.bg = .indexed(2)
        style.bold = true
        style.italic = true
        style.inverse = true
        style.faint = true
        style.strikethrough = true
        style.overline = true
        style.underline = .double
        style.underlineColor = .rgb(1, 2, 3)
        let row = renderer.layoutRow(RowKey(runs: [Run(text: "X", width: 1, style: style)], selected: nil), state: state)
        XCTAssertEqual(row.backgrounds.first?.color, state.palette.indexed(1))
        XCTAssertEqual(row.glyphs.first?.color, state.palette.indexed(2))
        XCTAssertEqual(row.glyphs.first?.alpha, 0.5)
        XCTAssertEqual(row.decorations.count, 3)
        XCTAssertEqual(row.decorations.first?.color, 0x01_02_03)
        XCTAssertTrue(row.decorations.allSatisfy { $0.alpha == 0.5 })
        style.invisible = true
        let invisible = renderer.layoutRow(RowKey(runs: [Run(text: "X", width: 1, style: style)], selected: nil), state: state)
        XCTAssertTrue(invisible.glyphs.isEmpty)
        XCTAssertTrue(invisible.decorations.isEmpty)
        XCTAssertEqual(invisible.backgrounds.count, 1)
    }

    func testEveryUnderlineAndHyperlinkHoverProducePixels() {
        var state = TerminalRendererTests().state(F.grid([[F.run("      ")]], cols: 8, cursor: Cursor(visible: false)))
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let plain = Data(bytes: context.data!, count: context.bytesPerRow * context.height)
        for underline in [Underline.single, .double, .dotted, .dashed, .curly] {
            var style = Style()
            style.underline = underline
            style.strikethrough = true
            state.grid.rows[0] = [Run(text: "      ", width: 6, style: style)]
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
            XCTAssertNotEqual(Data(bytes: context.data!, count: context.bytesPerRow * context.height), plain)
        }
        state.grid.rows[0] = [F.run("      ")]
        state.link = TerminalLinkCandidate(row: 0, columns: 1..<4, text: "https://example.org")
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertNotEqual(Data(bytes: context.data!, count: context.bytesPerRow * context.height), plain)
    }

    func testImprovedContrastAndThemePaletteAdjustOnlyText() {
        var palette = TerminalPalette()
        palette.background = 0x10_10_10
        var style = Style()
        style.fg = .rgb(0x18, 0x18, 0x18)
        XCTAssertEqual(palette.style(style).foreground, 0x18_18_18)
        palette.minimumContrast = TerminalPalette.improvedContrast
        let adjusted = palette.style(style)
        XCTAssertEqual(adjusted.background, 0x10_10_10)
        XCTAssertGreaterThanOrEqual(TerminalPalette.contrast(TerminalPalette.luminance(adjusted.foreground),
                                                             TerminalPalette.luminance(adjusted.background)), 3)
        style.fg = .default
        XCTAssertEqual(palette.style(style).foreground, palette.foreground, "readable theme text is left alone")

        palette.minimumContrast = 1
        palette.forceThemePalette = true
        style.fg = .rgb(0xEE, 0x40, 0x90)
        XCTAssertEqual(palette.style(style).foreground, palette.indexed(1))
        style.fg = .indexed(5)
        XCTAssertEqual(palette.style(style).foreground, palette.indexed(5), "theme colors stay")
        style.bg = .rgb(1, 2, 3)
        XCTAssertEqual(palette.style(style).background, 0x01_02_03, "backgrounds stay")
    }

    func testDisplayP3ColorsAndSurfaces() {
        var palette = TerminalPalette()
        XCTAssertEqual(palette.cgColor(0xFF_00_00).colorSpace?.name, CGColorSpace.sRGB)
        palette.displayP3 = true
        XCTAssertEqual(palette.cgColor(0xFF_00_00).colorSpace?.name, CGColorSpace.displayP3)
        var state = TerminalRendererTests().state(F.grid([[F.run("ab")]], cols: 4, cursor: Cursor(visible: false)))
        state.palette = palette
        let renderer = CoreTextRenderer()
        renderer.prepare(state)
        XCTAssertGreaterThan(renderer.rasterCount, 0)
    }

    func testCursorShapesAndBlinkPhase() {
        var state = TerminalRendererTests().state(F.grid([[F.run("    ")]], cols: 4, cursor: Cursor(visible: false)))
        state.palette.background = 0
        state.palette.cursor = 0xFF_00_00
        state.cursor = TerminalCursorState(visible: true, row: 0, column: 1)
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        let rect = state.layout.cellRect(row: 0, column: 1)
        for shape in [CursorShape.block, .bar, .underline, .hollow] {
            state.cursor.shape = shape
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
            let center = pixel(context, rect.midpoint)
            XCTAssertEqual(center.red, shape == .block ? 255 : 0, accuracy: 2)
            let edge = shape == .underline ? CGPoint(x: rect.midX, y: rect.maxY - 0.25)
                : CGPoint(x: rect.minX + 0.25, y: rect.midY)
            XCTAssertEqual(pixel(context, edge).red, 255, accuracy: 2, "shape \(shape)")
        }
        state.cursor.visible = false
        renderer.prepare(state)
        renderer.draw(state, dirty: [rect], in: context)
        XCTAssertEqual(pixel(context, CGPoint(x: rect.minX + 0.25, y: rect.midY)).red, 0)
    }

    func testSelectionResolvesCellColorsAndWideCellForeground() {
        var state = TerminalRendererTests().state(F.grid([[F.run("ab", fg: .rgb(255, 0, 0), bg: .rgb(0, 255, 0)),
                                                          F.run("界", width: 2)]], cols: 8, cursor: Cursor(visible: false)))
        state.palette.selectionForeground = .cellBackground
        state.palette.selectionBackground = .cellForeground
        state.selection = TerminalSelection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 1))
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let selected = state.layout.cellRect(row: 0, column: 0)
        XCTAssertEqual(pixel(context, CGPoint(x: selected.minX + 0.5, y: selected.minY + 0.5)).red, 255)
        let row = renderer.layoutRow(RowKey(runs: state.grid.rows[0], selected: 0..<1), state: state)
        XCTAssertEqual(row.glyphs.first?.color, 0x00_FF_00)
    }

    func testRoundedSelectionKeepsCornersThatNeighborsContinue() {
        let corners = SelectionCorners(4..<10, above: 0..<20, below: 0..<6)
        XCTAssertFalse(corners.topLeft)
        XCTAssertFalse(corners.topRight)
        XCTAssertFalse(corners.bottomLeft)
        XCTAssertTrue(corners.bottomRight)
        let alone = SelectionCorners(4..<10, above: 0..<0, below: 0..<0)
        XCTAssertTrue(alone.topLeft && alone.topRight && alone.bottomLeft && alone.bottomRight)

        var state = TerminalRendererTests().state(F.grid([[F.run("abcdef")]], cols: 8, cursor: Cursor(visible: false)))
        state.palette.background = 0
        state.palette.selectionBackground = .rgb(RGBColor(0xFF_00_00))
        state.selection = TerminalSelection(anchor: TerminalPoint(row: 0, column: 1), head: TerminalPoint(row: 0, column: 5))
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        let rect = state.layout.cellRect(row: 0, column: 1, width: 4)
        let corner = CGPoint(x: rect.minX + 0.25, y: rect.minY + 0.25)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(pixel(context, corner).red, 255)
        state.roundedSelection = true
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(pixel(context, corner).red, 0)
        XCTAssertEqual(pixel(context, CGPoint(x: rect.midX, y: rect.minY + 0.25)).red, 255)
    }

    func testPaddingAndRowsColoredEdgeToEdgeExtendIntoIt() {
        let metrics = TerminalMetrics(cellWidth: 8, cellHeight: 16, ascent: 10, descent: 3, baseline: 12,
                                      scale: 2, lineThickness: 0.5)
        let bounds = CGRect(x: 0, y: 0, width: 93, height: 73)
        let layout = TerminalLayout(bounds: bounds, metrics: metrics)
        XCTAssertEqual(layout.viewport, Size(cols: 11, rows: 4))
        XCTAssertEqual(layout.grid.minX, TerminalLayout.padding)
        XCTAssertEqual(layout.rowRect(0).minY, 0)
        XCTAssertEqual(layout.rowRect(3).maxY, 73)
        XCTAssertEqual(TerminalLayout(bounds: bounds, metrics: metrics, basePadding: 2).grid.minX, 0)
        var state = TerminalRendererTests().state(F.grid([[F.run(" ", width: 11, bg: .rgb(255, 0, 0))], [], [], []], cols: 11,
                                                        cursor: Cursor(visible: false)))
        state.metrics = metrics
        state.layout = layout
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [bounds], in: context)
        XCTAssertEqual(pixel(context, CGPoint(x: 0.5, y: 0.5)).red, 255)
        XCTAssertNotEqual(pixel(context, CGPoint(x: 0.5, y: 72.5)).red, 255)
    }

    func testSmoothScrollingShiftsRowsAndRevealsTheRowAbove() {
        var state = TerminalRendererTests().state(F.grid([[F.run("    ")], [F.run("    ")]], cols: 4,
                                                        history: [[F.run(" ", width: 4, bg: .rgb(255, 0, 0))]],
                                                        cursor: Cursor(visible: false)))
        state.palette.background = 0
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        let top = CGPoint(x: state.layout.grid.midX, y: state.layout.grid.minY + 1)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(pixel(context, top).red, 0)
        state.smoothOffset = state.layout.cellHeight / 2
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(pixel(context, top).red, 255, "the history row above shows")
    }

    func testFontFamilyStyleFallbacksAndLigatures() {
        let fonts = TerminalFontSet(family: "Menlo", style: "Bold", fallbacks: ["Apple Color Emoji"], size: 13)
        XCTAssertEqual(CTFontCopyFamilyName(fonts.regular.font) as String, "Menlo")
        XCTAssertEqual(CTFontCopyName(fonts.regular.font, kCTFontStyleNameKey) as String?, "Bold")
        XCTAssertTrue(CTFontGetSymbolicTraits(fonts.italic.font).contains(.traitItalic))
        XCTAssertNotNil(CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(fonts.regular.font), kCTFontCascadeListAttribute))
        let missing = TerminalFontSet(family: "Tab missing font", style: "Regular", fallbacks: [], size: 13)
        XCTAssertEqual(CTFontCopyFamilyName(missing.regular.font) as String, "Menlo")
        let unknownStyle = TerminalFontSet(family: "Menlo", style: "Tab missing style", fallbacks: [], size: 13)
        XCTAssertEqual(CTFontCopyName(unknownStyle.regular.font, kCTFontStyleNameKey) as String?, "Regular")
        let plain = TerminalFontSet(family: "Menlo", style: "Regular", fallbacks: [], size: 13, ligatures: false)
        XCTAssertNotNil(plain.regular.ascii, "without ligatures ASCII never substitutes")
    }

    func testUnicodeGlyphGeometryIsReusedAndCachesInvalidateForMetrics() {
        var state = TerminalRendererTests().state(F.grid([[F.run("a"), F.run("界", width: 2)],
                                                          [F.run("b"), F.run("界", width: 2)]], cols: 10,
                                                         cursor: Cursor(visible: false)))
        let renderer = CoreTextRenderer()
        renderer.prepare(state)
        XCTAssertEqual(renderer.glyphLayoutCount, 1)
        XCTAssertEqual(renderer.cachedGlyphCount, 1)
        state.metrics.baseline += 0.5
        renderer.prepare(state)
        XCTAssertEqual(renderer.layoutCount, 4)
        XCTAssertEqual(renderer.glyphLayoutCount, 2)
    }

    func testFontSmoothingAddsInkAndGlyphCacheIsBounded() {
        var state = TerminalRendererTests().state(F.grid([[F.run("MMMM")]], cols: 6, cursor: Cursor(visible: false)))
        state.palette.background = 0
        state.palette.foreground = 0xFF_FF_FF
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let plain = Data(bytes: context.data!, count: context.bytesPerRow * context.height).reduce(0) { $0 + Int($1) }
        var settings = F.settings()
        settings.fontSmoothing = true
        state.fonts = TerminalFontSet(settings: settings)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let thick = Data(bytes: context.data!, count: context.bytesPerRow * context.height).reduce(0) { $0 + Int($1) }
        XCTAssertGreaterThan(thick, plain)
        var faint = Style()
        faint.faint = true
        state.grid.rows[0] = [Run(text: "MMMM", width: 4, style: faint)]
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let brightest = stride(from: 2, to: context.bytesPerRow * context.height, by: 4).reduce(0) {
            max($0, Int(pixels[$1]))
        }
        XCTAssertEqual(brightest, 127, accuracy: 2, "faint text draws at half strength")
        for index in 0..<1400 {
            let text = String(Unicode.Scalar(0x4E00 + index)!)
            state.grid.rows[0] = [F.run(text, width: 2)]
            renderer.prepare(state)
            XCTAssertLessThanOrEqual(renderer.cachedGlyphCount, CoreTextRenderer.glyphLimit)
            XCTAssertLessThanOrEqual(renderer.glyphBytes, CoreTextRenderer.glyphByteLimit)
        }
        XCTAssertEqual(renderer.glyphLayoutCount, 1400)
    }

    private func pixel(_ context: CGContext, _ point: CGPoint) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let x = min(max(Int(point.x * 2), 0), context.width - 1)
        let y = min(max(Int(point.y * 2), 0), context.height - 1)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset]), Int(bytes[offset + 3]))
    }
}

private extension CGRect {
    var midpoint: CGPoint { CGPoint(x: midX, y: midY) }
}
