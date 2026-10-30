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
        var state = TerminalRendererTests().state(F.grid([[]], cols: 12, cursor: Cursor(visible: false)))
        state.palette.boldIsBright = true
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
        XCTAssertEqual(row.backgrounds.first?.color, state.palette.indexed(9))
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

    func testExplicitDefaultColoredCellsStayOpaqueOverVibrancy() {
        var state = TerminalRendererTests().state(F.grid([[F.run(" ", bg: .rgb(0, 0, 0))]], cols: 4,
                                                        cursor: Cursor(visible: false)))
        state.palette.background = 0
        state.palette.backgroundOpacity = 0.4
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(pixel(context, state.layout.cellRect(row: 0, column: 0).midpoint).alpha, 255)
        XCTAssertEqual(pixel(context, state.layout.cellRect(row: 0, column: 2).midpoint).alpha, 102, accuracy: 1)
        state.palette.backgroundOpacityCells = true
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(pixel(context, state.layout.cellRect(row: 0, column: 0).midpoint).alpha, 102, accuracy: 1)
        XCTAssertFalse(renderer.isBackgroundOpaque)
    }

    func testCursorShapesOpacityThicknessAndBlinkPhase() {
        var state = TerminalRendererTests().state(F.grid([[F.run("    ")]], cols: 4, cursor: Cursor(visible: false)))
        state.palette.background = 0
        state.palette.cursor = 0xFF_00_00
        state.palette.cursorOpacity = 0.5
        state.cursor = TerminalCursorState(visible: true, row: 0, column: 1, thickness: .pixels(3))
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        let rect = state.layout.cellRect(row: 0, column: 1)
        for shape in [CursorShape.block, .bar, .underline, .hollow] {
            state.cursor.shape = shape
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
            let center = pixel(context, rect.midpoint)
            XCTAssertEqual(center.red, shape == .block ? 127 : 0, accuracy: 2)
            let edge = shape == .underline ? CGPoint(x: rect.midX, y: rect.maxY - 0.5)
                : CGPoint(x: rect.minX + 0.5, y: rect.midY)
            XCTAssertEqual(pixel(context, edge).red, 127, accuracy: 2, "shape \(shape)")
        }
        state.cursor.visible = false
        renderer.prepare(state)
        renderer.draw(state, dirty: [rect], in: context)
        XCTAssertEqual(pixel(context, CGPoint(x: rect.minX + 0.5, y: rect.midY)).red, 0)
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

    func testPaddingBalanceAndExtension() {
        let metrics = TerminalMetrics(cellWidth: 8, cellHeight: 16, ascent: 10, descent: 3, baseline: 12,
                                      scale: 2, lineThickness: 0.5)
        var options = TerminalOptions()
        options.paddingX = [3, 5]
        options.paddingY = [7, 9]
        options.paddingBalance = true
        let bounds = CGRect(x: 0, y: 0, width: 93, height: 73)
        let layout = TerminalLayout(bounds: bounds, metrics: metrics, options: options)
        XCTAssertEqual(layout.viewport, Size(cols: 10, rows: 3))
        XCTAssertEqual(layout.grid.minX, 5.5)
        XCTAssertEqual(layout.grid.minY, 11.5)
        XCTAssertEqual(layout.rowRect(0).minY, 0)
        XCTAssertEqual(layout.rowRect(2).maxY, 73)
        XCTAssertEqual(layout.rows(in: CGRect(x: 0, y: 11.5, width: 93, height: 16)), 0..<1)
        var state = TerminalRendererTests().state(F.grid([[F.run(" ", width: 10, bg: .rgb(255, 0, 0))], [], []], cols: 10,
                                                        cursor: Cursor(visible: false)))
        state.metrics = metrics
        state.layout = layout
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [bounds], in: context)
        XCTAssertEqual(pixel(context, CGPoint(x: 1, y: 1)).red, 255)
        options.paddingColor = .background
        state.layout = TerminalLayout(bounds: bounds, metrics: metrics, options: options)
        renderer.prepare(state)
        renderer.draw(state, dirty: [bounds], in: context)
        XCTAssertNotEqual(pixel(context, CGPoint(x: 1, y: 1)).red, 255)
    }

    func testFontFamiliesTraitsFeaturesAndUnicodeMaps() {
        var settings = F.settings()
        settings.fontFamilies = ["Tab missing font", "Courier", "Menlo"]
        settings.font.bold = ["Tab missing bold", "Menlo"]
        settings.font.features = [FontFeature("liga", 0), FontFeature("calt", 0)]
        settings.font.codepoints = [FontMap(start: 0x41, end: 0x41, family: "Menlo")]
        settings.font.thicken = true
        settings.font.thickenStrength = 128
        let fonts = TerminalFontSet(settings: settings)
        XCTAssertEqual(CTFontCopyFamilyName(fonts.regular.font) as String, "Courier")
        XCTAssertEqual(CTFontCopyFamilyName(fonts.bold.font) as String, "Menlo")
        XCTAssertTrue(CTFontGetSymbolicTraits(fonts.italic.font).contains(.traitItalic))
        XCTAssertTrue(fonts.thicken)
        XCTAssertEqual(fonts.thickenStrength, 128.0 / 255.0, accuracy: 0.001)
        let mapped = fonts.mappedFont(for: "A", base: fonts.italic.font)
        XCTAssertEqual(mapped.map { CTFontCopyFamilyName($0) as String }, "Menlo")
        XCTAssertTrue(mapped.map { CTFontGetSymbolicTraits($0).contains(.traitItalic) } ?? false)
        XCTAssertNil(fonts.mappedFont(for: "B", base: fonts.regular.font))
        let descriptor = CTFontCopyFontDescriptor(fonts.regular.font)
        XCTAssertNotNil(CTFontDescriptorCopyAttribute(descriptor, kCTFontCascadeListAttribute))
        let featureFonts = TerminalFontSet(families: ["Times New Roman"], size: 13, options: settings.font)
        XCTAssertNotNil(CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(featureFonts.regular.font), kCTFontFeatureSettingsAttribute))
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

    func testThickeningAddsInkAndGlyphCacheIsBounded() {
        var state = TerminalRendererTests().state(F.grid([[F.run("MMMM")]], cols: 6, cursor: Cursor(visible: false)))
        state.palette.background = 0
        state.palette.foreground = 0xFF_FF_FF
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let plain = Data(bytes: context.data!, count: context.bytesPerRow * context.height).reduce(0) { $0 + Int($1) }
        var settings = F.settings()
        settings.font.thicken = true
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
        XCTAssertEqual(brightest, 127, accuracy: 2, "faint applies once to fill and stroke together")
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
