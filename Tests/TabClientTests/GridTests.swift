import TabProtocol
import XCTest
@testable import TabClient

final class GridTests: XCTestCase {
    private func run(_ text: String) -> Run {
        Run(text: text, width: UInt16(text.count))
    }

    private func row(_ index: UInt16, _ text: String) -> Row {
        Row(index: index, runs: text.isEmpty ? [] : [run(text)])
    }

    private func snapshot(prompts: [UInt16] = [], history: [Row] = [], historyCursor: HistoryCursor? = nil,
                          historyTotal: UInt64 = 0, rows: UInt16 = 3) -> AttachSnapshot {
        AttachSnapshot(channel: ChannelId(1), size: Size(cols: 10, rows: rows), rows: [row(0, "first"), row(2, "third")],
                       cursor: Cursor(row: 2, col: 5), directory: "/tmp", prompts: prompts, history: history,
                       historyCursor: historyCursor, historyTotal: historyTotal)
    }

    private func frame(_ seq: UInt64, reset: Bool, _ rows: [Row], size: Size = Size(cols: 10, rows: 3),
                       historyRows: UInt64 = 0) -> ScreenFrame {
        var modes = Modes()
        modes.applicationCursorKeys = true
        modes.bracketedPaste = true
        return ScreenFrame(size: size, seq: seq, reset: reset, rows: rows, cursor: Cursor(row: 0, col: 1, visible: false),
                           modes: modes, historyRows: historyRows)
    }

    func testPartialFrameReplacesOnlyItsRowsAndUpdatesCursorAndModes() {
        var grid = RunGrid(snapshot: snapshot())
        _ = grid.takeChanges()
        let update = frame(1, reset: false, [row(1, "second"), row(2, ""), row(9, "ignored")])
        let changes = grid.apply(update)
        XCTAssertEqual(grid.rowText(0), "first")
        XCTAssertEqual(grid.rowText(1), "second")
        XCTAssertEqual(grid.rowText(2), "")
        XCTAssertEqual(grid.rows.count, 3)
        XCTAssertEqual(grid.cursor, update.cursor)
        XCTAssertEqual(grid.modes, update.modes)
        XCTAssertFalse(changes.full)
        XCTAssertEqual(changes.rows, IndexSet([1, 2]))
        XCTAssertEqual(grid.takeChanges(), changes)
        XCTAssertTrue(grid.takeChanges().isEmpty)
    }

    func testResetFrameBlanksUnnamedRowsAndGrowsToItsRows() {
        var grid = RunGrid(snapshot: snapshot())
        XCTAssertTrue(grid.apply(frame(1, reset: true, [row(1, "only")])).full)
        XCTAssertEqual(grid.rows, [[], [run("only")], []])
        grid.apply(frame(2, reset: true, [row(4, "fifth")]))
        XCTAssertEqual(grid.rows.count, 5)
        XCTAssertEqual(grid.rowText(1), "")
        XCTAssertEqual(grid.rowText(4), "fifth")
    }

    func testResetAfterADelayedLargerFrameReturnsToTheRequestedHeight() {
        var grid = RunGrid(snapshot: snapshot())
        grid.resize(Size(cols: 10, rows: 8))
        grid.resize(Size(cols: 10, rows: 3))
        grid.apply(frame(1, reset: true, (0 ..< 8).map { row($0, "") }))
        grid.apply(frame(2, reset: true, (0 ..< 3).map { row($0, "") }))
        XCTAssertEqual(grid.rows.count, 3)
        XCTAssertEqual(grid.historyTotal, 0)
        XCTAssertTrue(grid.rows.allSatisfy(\.isEmpty))
    }

    func testFutureMarksWaitForFramesAndResetFramesCannotReuseOldMarks() {
        var grid = RunGrid(snapshot: AttachSnapshot(
            channel: ChannelId(1), size: Size(cols: 10, rows: 4), rows: [], cursor: Cursor(row: 1, col: 0),
            directory: "/tmp", prompts: [0, 3], history: [Row(index: 0, runs: []), Row(index: 0, runs: [])],
            historyCursor: HistoryCursor(2), historyTotal: 4))
        func plain(_ seq: UInt64, _ reset: Bool) -> ScreenFrame {
            ScreenFrame(size: Size(cols: 10, rows: 3), seq: seq, reset: reset, rows: [], cursor: Cursor(row: 1, col: 0),
                        historyRows: 4)
        }
        grid.screenPrompts(seq: 3, rows: [2])
        XCTAssertEqual(grid.prompts, [0, 3])
        grid.apply(plain(2, false))
        XCTAssertEqual(grid.prompts, [0])
        grid.apply(plain(3, true))
        XCTAssertEqual(grid.prompts, [2])
        grid.screenPrompts(seq: 1, rows: [0])
        XCTAssertEqual(grid.prompts, [2])
        grid.screenPrompts(seq: 5, rows: [])
        grid.apply(plain(5, false))
        XCTAssertTrue(grid.prompts.isEmpty)
        grid.screenPrompts(seq: 6, rows: [1])
        grid.apply(plain(6, false))
        grid.apply(plain(7, true))
        XCTAssertTrue(grid.prompts.isEmpty)
    }

    func testHistoryPagesStackAboveTheScreenAndScrollingStaysInsideThem() {
        var grid = RunGrid(snapshot: snapshot(history: [row(0, "h3"), row(0, "h4")], historyCursor: HistoryCursor(3),
                                              historyTotal: 5))
        XCTAssertEqual(grid.visibleRow(0).first?.text, "first")
        XCTAssertTrue(grid.scroll(by: 1))
        XCTAssertEqual(grid.visibleRow(0).first?.text, "h4")
        XCTAssertFalse(grid.scroll(by: 10) && grid.scrollOffset > 2, "scrolling stops at the fetched top")
        XCTAssertEqual(grid.scrollOffset, 2)
        XCTAssertTrue(grid.needsOlderHistory(margin: 0))
        grid.fetchOlder(HistoryPage(prompts: [0], rows: [row(0, "h0"), row(0, "h1"), row(0, "h2")], next: nil,
                                    totalRows: 5))
        XCTAssertEqual(grid.history.map { $0.runs.first?.text }, ["h0", "h1", "h2", "h3", "h4"])
        XCTAssertNil(grid.historyCursor)
        XCTAssertFalse(grid.needsOlderHistory(margin: 100))
        XCTAssertEqual(grid.contentRow(5)?.first?.text, "first")
        XCTAssertEqual(grid.searchContentRow(4, totalRows: 5), 4)
        XCTAssertNil(grid.searchContentRow(4, totalRows: 6), "a match from another history total is stale")
        grid.scroll(by: 3)
        XCTAssertEqual(grid.visibleRow(0).first?.text, "h0")
        grid.scrollToBottom()
        XCTAssertEqual(grid.scrollOffset, 0)
    }

    func testNewOutputKeepsAScrolledViewInPlace() {
        var grid = RunGrid(snapshot: snapshot(history: [row(0, "a"), row(0, "b"), row(0, "c")], historyTotal: 3))
        grid.scroll(by: 1)
        let changes = grid.apply(frame(1, reset: false, [row(0, "new")], historyRows: 4))
        XCTAssertTrue(changes.full)
        XCTAssertEqual(grid.historyTotal, 4)
        XCTAssertEqual(grid.scrollOffset, 2, "one more row of history above keeps the same rows in view")
        var live = RunGrid(snapshot: snapshot(historyTotal: 3))
        live.apply(frame(1, reset: false, [], historyRows: 4))
        XCTAssertEqual(live.scrollOffset, 0, "a view at the bottom follows live output")
    }

    func testSavedScreensHideTheCursorAndReadAsText() {
        let saved = SavedScreen(size: Size(cols: 10, rows: 2), rows: [row(0, "done   "), row(1, "$")],
                                cursor: Cursor(row: 1, col: 1), reason: .exited(0))
        let grid = RunGrid(saved: saved)
        XCTAssertFalse(grid.cursor.visible)
        XCTAssertEqual(grid.screenText(lines: 50), "done\n$")
        XCTAssertEqual(grid.screenText(lines: 1), "$")
    }

    func testLinksForAFrameNotDrawnYetStayHidden() {
        var grid = RunGrid(snapshot: snapshot())
        grid.links.replace(seq: 2, rows: [LinkRow(row: 0, spans: [LinkSpan(start: 0, end: 5, uri: "https://a.test")])])
        XCTAssertTrue(grid.links.row(0, size: grid.size).isEmpty)
        grid.apply(frame(2, reset: false, []))
        XCTAssertEqual(grid.links.row(0, size: grid.size).first?.uri, "https://a.test")
        grid.links.replace(seq: 1, rows: [])
        XCTAssertEqual(grid.links.row(0, size: grid.size).count, 1, "older links never replace newer ones")
    }
}
