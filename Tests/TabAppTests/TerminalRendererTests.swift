import CoreGraphics
import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

/// Offscreen Debug measurements at 2x scale, 2026-10-30, on this Mac:
/// original renderer: 45.5 ms / 1000 single-row frames; 3300 cached layouts
/// during 10000-line scrolling, with 12480600 bytes of estimated layout payload.
/// Prepared CGLayers: 135.3 ms / 1000 frames; 512 layouts (1936384 bytes),
/// plus 19398912 bytes of visible row backing pixels. Warm styled 200x60
/// preparation and draw: 0.69 ms median; cold: 15.65 ms median.
/// Payload accounting includes strings, glyphs, positions and fixed object
/// allowances; it excludes allocator metadata and Core Text's shared fonts.
/// Resident growth is printed separately and depends on allocator reuse.
@MainActor
final class TerminalRendererTests: XCTestCase {
    private typealias F = TerminalFixtures

    func testBackgroundRunsMergeByColorAndSkipTheDefault() {
        let palette = TerminalPalette()
        let red = Color.rgb(200, 0, 0)
        var inverse = Style()
        inverse.inverse = true
        let runs = [F.run("ab", bg: red), F.run("cd", bg: red), F.run("ef"), F.run("g", bg: .indexed(4)),
                    F.run("界", width: 2, bg: .indexed(4)), Run(text: "x", width: 1, style: inverse),
                    F.run("tail", bg: red)]
        let spans = CoreTextRenderer.backgroundSpans(runs, palette: palette, cols: 12)
        XCTAssertEqual(spans.map(\.columns), [0..<4, 6..<9, 9..<10, 10..<12])
        XCTAssertEqual(spans.map(\.color), [0xC8_00_00, palette.indexed(4), palette.foreground, 0xC8_00_00])
    }

    func testOnlyChangedRowIsLaidOutRasterizedAndBlittedAt200By50() {
        var grid = F.grid((0..<50).map { [F.run("row \($0)")] }, cols: 200, cursor: Cursor(visible: false))
        let renderer = CoreTextRenderer()
        var state = state(grid)
        let context = Self.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(renderer.layoutCount, 50)
        XCTAssertEqual(renderer.rasterCount, 50)
        XCTAssertEqual(renderer.drawCount, 50)
        var layouts: [Int] = []
        var rasters: [Int] = []
        var draws: [Int] = []
        renderer.onLayoutRow = { layouts.append($0) }
        renderer.onRasterRow = { rasters.append($0) }
        renderer.onDrawRow = { draws.append($0) }
        grid.apply(ScreenFrame(size: grid.size, seq: 1, reset: false,
                               rows: [Row(index: 23, runs: [F.run("changed")])], cursor: grid.cursor))
        state.grid = grid
        renderer.invalidate(rows: [23])
        renderer.prepare(state)
        XCTAssertEqual(layouts, [23])
        XCTAssertEqual(rasters, [23])
        let misses = renderer.layoutCount
        let allocations = renderer.surfaceAllocationCount
        renderer.draw(state, dirty: [state.layout.rowRect(23), state.layout.rowRect(23)], in: context)
        XCTAssertEqual(draws, [23], "overlapping dirty rectangles blit once")
        XCTAssertEqual(renderer.layoutCount, misses, "draw cannot lay out text")
        XCTAssertEqual(renderer.surfaceAllocationCount, allocations, "draw cannot allocate row buffers")
        renderer.prepare(state)
        XCTAssertEqual(renderer.rasterCount, 51, "unchanged frames do not rasterize")
        XCTAssertEqual(renderer.surfaceAllocationCount, 50, "changed frames reuse row buffers")
    }

    func testScrollingOneLineReusesFortyNineLayouts() {
        var grid = F.grid((0..<50).map { [F.run("screen \($0)")] }, cols: 200, history: [[F.run("history")]],
                          cursor: Cursor(visible: false))
        let renderer = CoreTextRenderer()
        var state = state(grid)
        renderer.prepare(state)
        grid.scroll(by: 1)
        state.grid = grid
        renderer.prepare(state)
        XCTAssertEqual(renderer.layoutCount, 51)
        grid.scrollToBottom()
        state.grid = grid
        renderer.prepare(state)
        XCTAssertEqual(renderer.layoutCount, 51, "scrolling back shares cached content")
    }

    func testFullScreenChangeRebuildsEveryLineOnce() {
        var grid = F.grid((0..<50).map { [F.run("before \($0)")] }, cols: 200, cursor: Cursor(visible: false))
        let renderer = CoreTextRenderer()
        var state = state(grid)
        renderer.prepare(state)
        grid.apply(ScreenFrame(size: grid.size, seq: 1, reset: true,
                               rows: (0..<50).map { Row(index: UInt16($0), runs: [F.run("after \($0)")]) }, cursor: grid.cursor))
        state.grid = grid
        let context = Self.context(state.layout)
        renderer.prepare(state)
        XCTAssertEqual(renderer.layoutCount, 100)
        XCTAssertEqual(renderer.rasterCount, 100)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(renderer.drawCount, 50)
        renderer.prepare(state)
        XCTAssertEqual(renderer.layoutCount, 100)
        XCTAssertEqual(renderer.rasterCount, 100)
    }

    func testViewDoesNotInvalidateStationaryCursorOnChangedRowFrames() {
        let renderer = CoreTextRenderer()
        let view = TerminalView(settings: F.settings(), palette: TerminalPalette(), renderer: renderer)
        view.setFrameSize(CGSize(width: 1600, height: 900))
        view.setGrid(F.grid((0..<50).map { [F.output("row \($0)")] }, cols: 200))
        view.viewWillDraw()
        view.needsDisplay = false
        var rasterized: [Int] = []
        renderer.onRasterRow = { rasterized.append($0) }
        var invalidated = IndexSet()
        renderer.onInvalidateRows = { invalidated.formUnion($0) }
        view.updateGrid { grid in
            grid.apply(ScreenFrame(size: grid.size, seq: 1, reset: false,
                                   rows: [Row(index: 23, runs: [F.output("changed")])], cursor: grid.cursor))
        }
        view.viewWillDraw()
        XCTAssertEqual(rasterized, [23])
        XCTAssertEqual(invalidated, [23])
    }

    func testFullGridRedrawsWellUnderAFrame() {
        let cols: UInt16 = 200
        let rows = 60
        var lines: [[Run]] = []
        for row in 0..<rows {
            var runs: [Run] = []
            var column = 0
            while column < Int(cols) {
                let width = 1 + (row * 7 + column) % 9
                let text = String(repeating: "abcdefghij"[(column + row) % 10], count: min(width, Int(cols) - column))
                var style = Style()
                style.fg = .indexed(UInt8((row + column) % 16))
                style.bg = (row + column) % 3 == 0 ? .rgb(UInt8(row * 4), UInt8(column), 40) : .default
                style.bold = column % 5 == 0
                style.underline = column % 11 == 0 ? .single : .none
                runs.append(Run(text: text, width: UInt16(text.count), style: style))
                column += text.count
            }
            lines.append(runs)
        }
        let grid = F.grid(lines, cols: cols, cursor: Cursor(row: 10, col: 10))
        let renderer = CoreTextRenderer()
        let state = state(grid)
        let context = Self.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)

        var cold: [Double] = []
        var warm: [Double] = []
        for _ in 0..<5 {
            renderer.invalidateAll()
            var start = CFAbsoluteTimeGetCurrent()
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
            cold.append(CFAbsoluteTimeGetCurrent() - start)
            start = CFAbsoluteTimeGetCurrent()
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
            warm.append(CFAbsoluteTimeGetCurrent() - start)
        }
        let coldMedian = cold.sorted()[2] * 1000
        let warmMedian = warm.sorted()[2] * 1000
        #if DEBUG
        let layoutBudget = 32.0
        #else
        let layoutBudget = 16.0
        #endif
        print("Terminal styled 200x60 cold median: \(coldMedian) ms; warm median: \(warmMedian) ms")
        XCTAssertLessThan(warmMedian, 16, "cached full redraw took \(warmMedian) ms")
        XCTAssertLessThan(coldMedian, layoutBudget, "full layout and redraw took \(coldMedian) ms")
        measure {
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
        }
    }

    /// Codesh sends changed rows at about 60 Hz (docs/tech/README.md) and
    /// benchmarks 600 single-row updates in element/cache_tests.rs. Reserve
    /// one quarter of a 16 ms tick for Tab: 4 ms/frame, 4 s/1000 frames in Debug.
    func testThousandSingleRowFramesBudget() {
        var grid = F.grid((0..<50).map { [F.output("row \($0)")] }, cols: 200)
        let renderer = CoreTextRenderer()
        var state = state(grid)
        let context = Self.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let start = CFAbsoluteTimeGetCurrent()
        for tick in 0..<1000 {
            let row = tick % 50
            grid.apply(ScreenFrame(size: grid.size, seq: UInt64(tick + 1), reset: false,
                                   rows: [Row(index: UInt16(row), runs: [F.output("frame \(tick)")])],
                                   cursor: Cursor(visible: false)))
            state.grid = grid
            renderer.invalidate(rows: IndexSet(integer: row))
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.rowRect(row)], in: context)
        }
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("Terminal 200x50, 1000 changed-row frames: \(milliseconds) ms; layouts=\(renderer.layoutCount)")
        XCTAssertEqual(renderer.layoutCount, 1050)
        XCTAssertLessThan(milliseconds, 4000)
    }

    func testTenThousandScrollbackCacheBound() {
        let history = (0..<10000).map { [F.output("history \($0)")] }
        var grid = F.grid((0..<50).map { [F.run("screen \($0)")] }, cols: 200, history: history)
        let renderer = CoreTextRenderer()
        var state = state(grid)
        let context = Self.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let residentBefore = F.residentBytes()
        var peak = 0
        var peakBytes = 0
        for _ in 0..<200 {
            grid.scroll(by: 50)
            state.grid = grid
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
            peak = max(peak, renderer.cachedLineCount)
            peakBytes = max(peakBytes, renderer.layoutBytes + renderer.surfaceBytes + renderer.glyphBytes + renderer.imageBytes)
            XCTAssertLessThanOrEqual(renderer.cachedLineCount, CoreTextRenderer.lineLimit)
            XCTAssertLessThanOrEqual(renderer.layoutBytes, CoreTextRenderer.lineByteLimit)
            XCTAssertLessThanOrEqual(renderer.glyphBytes, CoreTextRenderer.glyphByteLimit)
            XCTAssertLessThanOrEqual(renderer.imageBytes, CoreTextRenderer.imageByteLimit)
        }
        print("Terminal 10000-line scrollback: peak cached lines=\(peak), payload+bitmap bytes=\(peakBytes), surfaces=\(renderer.surfaceBytes)")
        print("Terminal scroll resident growth: \(Int64(F.residentBytes()) - Int64(residentBefore)) bytes")
        XCTAssertEqual(renderer.surfaceAllocationCount, 50)
        XCTAssertLessThan(peakBytes, 32 * 1024 * 1024)
    }

    func state(_ grid: RunGrid) -> TerminalRenderState {
        let settings = F.settings()
        let fonts = TerminalFontSet(settings: settings)
        let metrics = TerminalMetrics(fonts: fonts, cellWidth: .natural, cellHeight: .natural, scale: 2)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(grid.size.cols) * metrics.cellWidth + 4,
                            height: CGFloat(grid.size.rows) * metrics.cellHeight + 4)
        let layout = TerminalLayout(bounds: bounds, metrics: metrics, options: settings.options)
        return TerminalRenderState(grid: grid, layout: layout, metrics: metrics, fonts: Self.fonts(settings),
                                   palette: TerminalPalette(),
                                   cursor: TerminalCursorState(visible: grid.cursor.visible, row: Int(grid.cursor.row),
                                                               column: Int(grid.cursor.col)))
    }

    private static var cachedFonts: TerminalFontSet?

    private static func fonts(_ settings: TerminalSettings) -> TerminalFontSet {
        if let cachedFonts { return cachedFonts }
        let fonts = TerminalFontSet(settings: settings)
        cachedFonts = fonts
        return fonts
    }

    static func context(_ layout: TerminalLayout) -> CGContext {
        let width = Int(layout.bounds.width * 2)
        let height = Int(layout.bounds.height * 2)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: 0, y: layout.bounds.height)
        context.scaleBy(x: 1, y: -1)
        return context
    }
}

private extension String {
    subscript(index: Int) -> Character { self[self.index(startIndex, offsetBy: index)] }
}
