import CoreGraphics
import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

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

    func testOnlyChangedRowsAreLaidOutAgain() {
        let renderer = CoreTextRenderer()
        var grid = F.grid((0..<6).map { [F.run("row \($0)", fg: .indexed(UInt8($0)))] }, cols: 40)
        let state = { (grid: RunGrid) in self.state(grid) }
        let context = Self.context(state(grid).layout)
        renderer.draw(state(grid), dirty: [state(grid).layout.bounds], in: context)
        XCTAssertEqual(renderer.layoutCount, 6)

        renderer.draw(state(grid), dirty: [state(grid).layout.bounds], in: context)
        XCTAssertEqual(renderer.layoutCount, 6, "unchanged rows are reused")

        grid.apply(ScreenFrame(size: grid.size, seq: 1, reset: false, rows: [Row(index: 2, runs: [F.run("changed")])],
                               cursor: Cursor()))
        renderer.invalidate(rows: [2])
        renderer.draw(state(grid), dirty: [state(grid).layout.rowRect(2)], in: context)
        XCTAssertEqual(renderer.layoutCount, 7, "only the changed row is laid out")

        grid.apply(ScreenFrame(size: grid.size, seq: 2, reset: false, rows: [Row(index: 4, runs: [F.run("changed")])],
                               cursor: Cursor()))
        renderer.draw(state(grid), dirty: [state(grid).layout.bounds], in: context)
        XCTAssertEqual(renderer.layoutCount, 7, "rows with cached content share one layout")
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
        renderer.draw(state, dirty: [state.layout.bounds], in: context)

        var cold: [Double] = []
        var warm: [Double] = []
        for _ in 0..<5 {
            renderer.invalidateAll()
            var start = CFAbsoluteTimeGetCurrent()
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
            cold.append(CFAbsoluteTimeGetCurrent() - start)
            start = CFAbsoluteTimeGetCurrent()
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
            warm.append(CFAbsoluteTimeGetCurrent() - start)
        }
        let coldMedian = cold.sorted()[2] * 1000
        let warmMedian = warm.sorted()[2] * 1000
        // Laying out every row is the worst case (a resize or a font change);
        // unoptimized test builds get twice the budget for it.
        #if DEBUG
        let layoutBudget = 32.0
        #else
        let layoutBudget = 16.0
        #endif
        XCTAssertLessThan(warmMedian, 16, "cached full redraw took \(warmMedian) ms")
        XCTAssertLessThan(coldMedian, layoutBudget, "full layout and redraw took \(coldMedian) ms")
        measure {
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
        }
    }

    private func state(_ grid: RunGrid) -> TerminalRenderState {
        let settings = F.settings()
        let fonts = TerminalFontSet(settings: settings)
        let metrics = TerminalMetrics(fonts: fonts, cellWidth: .natural, cellHeight: .natural, scale: 2)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(grid.size.cols) * metrics.cellWidth + 4,
                            height: CGFloat(grid.size.rows) * metrics.cellHeight + 4)
        let layout = TerminalLayout(bounds: bounds, metrics: metrics, options: settings.options)
        return TerminalRenderState(grid: grid, layout: layout, metrics: metrics, fonts: Self.fonts(settings),
                                   palette: TerminalPalette(),
                                   cursor: TerminalCursorState(visible: true, row: Int(grid.cursor.row),
                                                               column: Int(grid.cursor.col)))
    }

    private static var cachedFonts: TerminalFontSet?

    private static func fonts(_ settings: TerminalSettings) -> TerminalFontSet {
        if let cachedFonts { return cachedFonts }
        let fonts = TerminalFontSet(settings: settings)
        cachedFonts = fonts
        return fonts
    }

    private static func context(_ layout: TerminalLayout) -> CGContext {
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
