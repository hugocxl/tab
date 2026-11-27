import TabProtocol
import XCTest
@testable import TabTerminal

final class SearchTests: XCTestCase {
    func testSearchFindsMatchesAcrossHistoryNewestFirst() throws {
        let terminal = try makeTerminal(cols: 40, rows: 10)
        for line in 1...100 {
            terminal.feed(line % 10 == 0 ? "line \(line) Needle\r\n" : "line \(line)\r\n")
        }
        let history = try terminal.historyCount()
        let page = try terminal.search("needle")
        XCTAssertEqual(page.candidates, 10)
        XCTAssertEqual(page.matches.count, 10)
        XCTAssertNil(page.next)
        XCTAssertEqual(page.matches.map(\.start.row), stride(from: 99, through: 9, by: -10).map { $0 })
        XCTAssertLessThan(page.matches.last!.start.row, history)
        XCTAssertEqual(try terminal.selectionText(page.matches[0]), "Needle")
        XCTAssertEqual(try terminal.selectionText(from: GridPoint(row: 9, column: 0), to: GridPoint(row: 9, column: 39)),
                       "line 10 Needle")
    }

    func testSearchPagesContinueWithOlderMatches() throws {
        let terminal = try makeTerminal(cols: 40, rows: 10)
        for line in 1...100 {
            terminal.feed("row \(line) hit\r\n")
        }
        var rows: [Int] = []
        var page = try terminal.search("hit", maxResults: 30)
        rows += page.matches.map(\.start.row)
        while let next = page.next {
            terminal.feed("more output\r\n")
            page = try terminal.search("hit", before: next, maxResults: 30)
            rows += page.matches.map(\.start.row)
        }
        XCTAssertEqual(rows, Array((0..<100).reversed()))

        let fresh = try terminal.search("hit", maxResults: 5)
        XCTAssertEqual(fresh.matches.map(\.start.row), [99, 98, 97, 96, 95])
        XCTAssertThrowsError(try terminal.search("other", before: fresh.next, maxResults: 5))
    }

    func testCaseSensitiveSearchSkipsOtherCases() throws {
        let terminal = try makeTerminal(cols: 40, rows: 5)
        terminal.feed("Make make MAKE make\r\n")
        XCTAssertEqual(try terminal.search("make").matches.count, 4)
        let exact = try terminal.search("make", caseSensitive: true)
        XCTAssertEqual(exact.matches.map(\.start.column), [15, 5])
        XCTAssertEqual(try terminal.search("absent").matches, [])
    }

    func testStaleSearchCursorIsRejected() throws {
        let terminal = try makeTerminal(cols: 20, rows: 5)
        for _ in 0..<30 {
            terminal.feed("hit\r\n")
        }
        let page = try terminal.search("hit", maxResults: 3)
        let cursor = try XCTUnwrap(page.next)
        try terminal.resize(Size(cols: 30, rows: 5))
        XCTAssertThrowsError(try terminal.search("hit", before: cursor)) {
            XCTAssertEqual(($0 as? TerminalError)?.reason, .staleCursor)
        }
    }

    func testCommandOutputUsesSemanticPromptMarks() throws {
        let terminal = try makeTerminal(cols: 30, rows: 10)
        terminal.feed("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}one\r\ntwo\r\n\u{1b}]133;D;0\u{07}")
        terminal.feed("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}")
        let output = try XCTUnwrap(try terminal.selectCommandOutput(at: GridPoint(row: 1, column: 1)))
        XCTAssertEqual(try terminal.selectionText(output), "one\ntwo")
        XCTAssertNil(try terminal.selectCommandOutput(at: GridPoint(row: 0, column: 0)))
    }
}
