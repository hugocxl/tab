import TabProtocol
import XCTest
@testable import TabTerminal

final class GraphicsTests: XCTestCase {
    func testKittyImagesArePlacedAndClearedWithTheScreen() throws {
        let terminal = try makeTerminal()
        try terminal.setCellSize(CellSize(width: 10, height: 20))
        terminal.feed("\u{1b}_Ga=T,f=24,s=1,v=1,i=7;/wAA\u{1b}\\")
        let graphics = try terminal.graphics()
        XCTAssertEqual(graphics.cell, CellSize(width: 10, height: 20))
        XCTAssertEqual(graphics.images.map(\.id), [7])
        XCTAssertEqual(graphics.images.first?.rgba, Data([255, 0, 0, 255]))
        XCTAssertEqual(graphics.placements.count, 1)
        XCTAssertEqual(graphics.placements.first?.image, 7)
        XCTAssertEqual(graphics.placements.first.map { [$0.size.cols, $0.size.rows] }, [1, 1])
        XCTAssertEqual(try terminal.graphics().images.first?.generation, graphics.images.first?.generation)
        _ = terminal.takePtyOutput()
        XCTAssertTrue(try terminal.clearScreen())
        XCTAssertEqual(try terminal.graphics().placements.count, 0)
        XCTAssertEqual(try terminal.graphics().images.count, 0)
    }
}
