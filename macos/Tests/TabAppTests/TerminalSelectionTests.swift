import XCTest
import TabProtocol
@testable import TabApp

final class TerminalSelectionTests: XCTestCase {
    private typealias F = TerminalFixtures

    func testWordSelectionStopsAtSpacesAndPunctuation() {
        let grid = F.grid([[F.run("git commit --amend")]])
        let word = TerminalSelection.word(at: TerminalPoint(row: 0, column: 5), in: grid)
        XCTAssertEqual(word.text(in: grid), "commit")
        let dash = TerminalSelection.word(at: TerminalPoint(row: 0, column: 11), in: grid)
        XCTAssertEqual(dash.text(in: grid), "-", "punctuation selects one cell")
        let beyond = TerminalSelection.word(at: TerminalPoint(row: 0, column: 19), in: grid)
        XCTAssertEqual(beyond.columns(row: 0, in: grid), 19..<20)
    }

    func testLineAndStreamSelectionAcrossRowsAndHistory() {
        let grid = F.grid([[F.run("screen one")], [F.run("screen two  ")]], history: [[F.run("old line")]])
        let line = TerminalSelection.line(at: TerminalPoint(row: 1, column: 3), in: grid)
        XCTAssertEqual(line.text(in: grid), "screen two")
        let stream = TerminalSelection(anchor: TerminalPoint(row: 0, column: 7), head: TerminalPoint(row: -1, column: 4))
        XCTAssertEqual(stream.text(in: grid), "line\nscreen")
        XCTAssertEqual(TerminalSelection.all(in: grid).text(in: grid), "old line\nscreen one\nscreen two")
    }

    func testWideCellsAreSelectedWhole() {
        let grid = F.grid([[F.run("a"), F.run("界", width: 2), F.run("b")]])
        let half = TerminalSelection(anchor: TerminalPoint(row: 0, column: 2), head: TerminalPoint(row: 0, column: 3))
        XCTAssertEqual(half.columns(row: 0, in: grid), 1..<3)
        XCTAssertEqual(half.text(in: grid), "界")
        let word = TerminalSelection.word(at: TerminalPoint(row: 0, column: 2), in: grid)
        XCTAssertEqual(word.text(in: grid), "a界b")
    }

    func testRectangleSelectsTheSameColumnsOnEveryRow() {
        let grid = F.grid([[F.run("abcdef")], [F.run("ghijkl")], [F.run("mnopqr")]])
        let block = TerminalSelection(anchor: TerminalPoint(row: 0, column: 4), head: TerminalPoint(row: 2, column: 1),
                                      rectangular: true)
        XCTAssertEqual(block.text(in: grid), "bcd\nhij\nnop")
        XCTAssertEqual(block.columns(row: 1, in: grid), 1..<4)
    }

    func testFingerprintNoticesChangedOutput() {
        var grid = F.grid([[F.run("hello")]])
        let selection = TerminalSelection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 5))
        let before = selection.fingerprint(in: grid)
        grid.apply(ScreenFrame(size: grid.size, seq: 1, reset: false, rows: [Row(index: 0, runs: [F.run("world")])],
                               cursor: Cursor()))
        XCTAssertNotEqual(selection.fingerprint(in: grid), before)
    }
}
