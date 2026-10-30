import CoreGraphics
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class TerminalGraphicsTests: XCTestCase {
    func testGeneratedPlacementCropOffsetScrollAndClear() {
        let red: [UInt8] = [255, 0, 0, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let blue: [UInt8] = [0, 0, 255, 255]
        let image = GraphicImage(id: 1, generation: 1, width: 2, height: 2, rgba: Data(red + green + blue + green))
        var placement = GraphicPlacement(image: 1, id: 1, column: 1, row: 0, offset: (4, 4), size: (2, 2),
                                         source: (0, 0, 2, 2), z: 1)
        var grid = TerminalFixtures.grid([[], [], [], []], cols: 8, history: [[]], cursor: Cursor(visible: false))
        grid.graphics = Graphics(cell: CellSize(width: 16, height: 32), images: [image], placements: [placement])
        var state = TerminalRendererTests().state(grid)
        state.metrics = TerminalMetrics(cellWidth: 8, cellHeight: 16, ascent: 10, descent: 3, baseline: 12,
                                        scale: 2, lineThickness: 0.5)
        state.layout = TerminalLayout(bounds: CGRect(x: 0, y: 0, width: 68, height: 68), metrics: state.metrics,
                                       options: TerminalOptions())
        state.palette.background = 0
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        func render() {
            renderer.prepare(state)
            renderer.draw(state, dirty: [state.layout.bounds], in: context)
        }
        render()
        let x = state.layout.grid.minX + 8 + 2
        let y = state.layout.grid.minY + 2
        XCTAssertEqual(rgb(context, x: x + 2, y: y + 2), 0xFF_00_00)
        XCTAssertEqual(rgb(context, x: x + 2, y: y + 29), 0x00_00_FF)
        XCTAssertEqual(rgb(context, x: x - 1, y: y + 2), 0)
        let bytes = renderer.imageBytes
        XCTAssertEqual(bytes, 16)
        placement.source = (1, 0, 1, 2)
        state.grid.graphics?.placements = [placement]
        render()
        XCTAssertEqual(rgb(context, x: x + 8, y: y + 16), 0x00_FF_00)
        state.grid.scroll(by: 1)
        render()
        XCTAssertEqual(rgb(context, x: x + 8, y: y + 2), 0)
        XCTAssertEqual(rgb(context, x: x + 8, y: y + 18), 0x00_FF_00)
        state.grid.apply(ScreenFrame(size: grid.size, seq: 1, reset: false, rows: [Row(index: 0, runs: [])],
                                     cursor: Cursor(visible: false), graphics: Graphics(cell: CellSize(width: 16, height: 32))))
        render()
        XCTAssertEqual(rgb(context, x: x + 8, y: y + 18), 0)
        XCTAssertEqual(renderer.imageBytes, 0)
    }

    func testPlacementZOrderAndImageGeneration() {
        let red = GraphicImage(id: 1, generation: 1, width: 1, height: 1, rgba: Data([255, 0, 0, 255]))
        let blue = GraphicImage(id: 2, generation: 1, width: 1, height: 1, rgba: Data([0, 0, 255, 255]))
        func placement(_ image: UInt32, _ z: Int32) -> GraphicPlacement {
            GraphicPlacement(image: image, id: image, column: 0, row: 0, offset: (0, 0), size: (1, 1),
                             source: (0, 0, 1, 1), z: z)
        }
        var state = TerminalRendererTests().state(TerminalFixtures.grid([[]], cols: 4, cursor: Cursor(visible: false)))
        state.grid.graphics = Graphics(cell: state.metrics.physicalCellSize, images: [red, blue],
                                       placements: [placement(1, 5), placement(2, 1)])
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let rect = state.layout.cellRect(row: 0, column: 0)
        XCTAssertEqual(rgb(context, x: rect.midX, y: rect.midY), 0xFF_00_00)
        state.grid.graphics?.images[0] = GraphicImage(id: 1, generation: 2, width: 1, height: 1, rgba: Data([0, 255, 0, 255]))
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(rgb(context, x: rect.midX, y: rect.midY), 0x00_FF_00)
        XCTAssertEqual(renderer.imageBytes, 8)
    }

    func testVeryNegativeImagesSitBehindCellBackgrounds() {
        let image = GraphicImage(id: 1, generation: 1, width: 1, height: 1, rgba: Data([0, 0, 255, 255]))
        var state = TerminalRendererTests().state(TerminalFixtures.grid(
            [[TerminalFixtures.run(" ", bg: .rgb(255, 0, 0)), TerminalFixtures.run(" ")]], cols: 4,
            cursor: Cursor(visible: false)))
        let placement = GraphicPlacement(image: 1, id: 1, column: 0, row: 0, offset: (0, 0), size: (2, 1),
                                         source: (0, 0, 1, 1), z: .min)
        state.grid.graphics = Graphics(cell: state.metrics.physicalCellSize, images: [image], placements: [placement])
        let renderer = CoreTextRenderer()
        let context = TerminalRendererTests.context(state.layout)
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        let first = state.layout.cellRect(row: 0, column: 0)
        let second = state.layout.cellRect(row: 0, column: 1)
        XCTAssertEqual(rgb(context, x: first.midX, y: first.midY), 0xFF_00_00)
        XCTAssertEqual(rgb(context, x: second.midX, y: second.midY), 0x00_00_FF)
        state.grid.graphics?.placements[0].z = -1
        renderer.prepare(state)
        renderer.draw(state, dirty: [state.layout.bounds], in: context)
        XCTAssertEqual(rgb(context, x: first.midX, y: first.midY), 0x00_00_FF)
    }

    private func rgb(_ context: CGContext, x: CGFloat, y: CGFloat) -> UInt32 {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = Int(y * 2) * context.bytesPerRow + Int(x * 2) * 4
        return UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset])
    }
}
