import TabProtocol
import XCTest
@testable import TabTerminal

final class HistoryTests: XCTestCase {
    func testPagingThroughHistoryAfterTwoHundredLines() throws {
        let terminal = try makeTerminal(cols: 20, rows: 24)
        numbered(terminal, 1...200)
        let screen = try terminal.render()
        let cursor = try terminal.cursor()
        XCTAssertEqual(try terminal.historyCount(), 201 - 24)

        var collected: [String] = []
        var page = try terminal.historyPage(maxRows: 50)
        XCTAssertEqual(page.totalRows, 177)
        XCTAssertEqual(page.start, 127)
        XCTAssertEqual(page.rows.map(\.index), Array(0..<50).map(UInt16.init))
        collected = lines(page.rows) + collected
        while let next = page.next {
            page = try terminal.historyPage(before: next, maxRows: 50)
            collected = lines(page.rows) + collected
        }
        XCTAssertEqual(collected, (1...177).map(String.init))

        XCTAssertEqual(try terminal.fullRender(), screen)
        XCTAssertEqual(try terminal.cursor(), cursor)
        XCTAssertEqual(try terminal.render(), [])
        terminal.feed("\u{1b}[2;1Hchanged")
        _ = try terminal.history(0..<100)
        XCTAssertEqual(try terminal.render().map(\.index), [1])
    }

    func testGenerationSurvivesAppendsButNotResizeClearOrScreenSwitch() throws {
        let terminal = try makeTerminal(cols: 20, rows: 24, budget: 16 << 20)
        numbered(terminal, 1...100)
        let generation = try terminal.historyGeneration()
        let cursor = try XCTUnwrap(try terminal.historyPage(maxRows: 10).next)
        numbered(terminal, 101...120)
        XCTAssertEqual(try terminal.historyGeneration(), generation)
        XCTAssertNoThrow(try terminal.historyPage(before: cursor, maxRows: 10))

        try terminal.resize(Size(cols: 10, rows: 24))
        let resized = try terminal.historyGeneration()
        XCTAssertNotEqual(resized, generation)
        XCTAssertThrowsError(try terminal.historyPage(before: cursor, maxRows: 10)) {
            XCTAssertEqual(($0 as? TerminalError)?.reason, .staleCursor)
        }
        terminal.feed("\u{1b}[3J")
        XCTAssertNotEqual(try terminal.historyGeneration(), resized)
        numbered(terminal, 1...100)
        let before = try terminal.historyGeneration()
        terminal.feed("\u{1b}[?1049h")
        XCTAssertNotEqual(try terminal.historyGeneration(), before)
    }

    func testPruningChangesTheGenerationEvenWhenTextRepeats() throws {
        let terminal = try makeTerminal(cols: 20, rows: 24, budget: 32 * 1024)
        terminal.feed(String(repeating: "same\r\n", count: 200))
        let generation = try terminal.historyGeneration()
        terminal.feed(String(repeating: "same\r\n", count: 10_000))
        XCTAssertNotEqual(try terminal.historyGeneration(), generation)
        XCTAssertLessThan(try terminal.historyCount(), 10_000)
    }

    func testAlternateScreenKeepsPrimaryHistoryAndRestoresIt() throws {
        for entry in ["\u{1b}[?1049h", "\u{1b}[?1;47h", "\u{1b}[?1047h", "\u{1b}[?1049\u{07}h"] {
            let terminal = try makeTerminal(cols: 20, rows: 4)
            terminal.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n")
            let primary = try terminal.archive()
            XCTAssertEqual(primary.history.map(text), ["one", "two"])
            for byte in Array(entry.utf8) {
                terminal.feed([byte])
            }
            terminal.feed("\u{1b}[2J\u{1b}[Halternate")
            let archive = try terminal.archive()
            XCTAssertEqual(text(archive.rows[0].runs), "alternate", entry)
            XCTAssertEqual(archive.history, primary.history, entry)
            XCTAssertEqual(try terminal.history(0..<10).rows, [], entry)
            terminal.feed("\u{1b}[?1049l\u{1b}[?1047l\u{1b}[?47l")
            XCTAssertEqual(try terminal.archive().history, primary.history, entry)
            XCTAssertEqual(try terminal.screenLines().prefix(3), ["three", "four", "five"], entry)
        }
    }

    func testOutputAndAlternateEntryInOneWriteSaveTheNewHistory() throws {
        let terminal = try makeTerminal(cols: 20, rows: 4)
        terminal.feed("first\r\nsecond\r\nthird\r\nfourth\r\nfifth\r\n\u{1b}[?1049h\u{1b}[Htop")
        let archive = try terminal.archive()
        XCTAssertEqual(archive.history.first.map(text), "first")
        XCTAssertEqual(text(archive.rows[0].runs), "top")
    }

    func testArchiveRoundTripKeepsHistoryStylesWideTextAndLinks() throws {
        let terminal = try makeTerminal(cols: 20, rows: 4)
        terminal.feed("\u{1b}[31mone\r\ntwo\r\nthree\r\nfour\r\nfive\r\n")
        terminal.feed("\u{1b}[32m界e\u{301} \u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\")
        let archive = try terminal.archive()
        XCTAssertEqual(archive.size, Size(cols: 20, rows: 4))
        XCTAssertEqual(archive.history.count, try terminal.historyCount())
        XCTAssertEqual(archive.history[0].first?.style.fg, .indexed(1))
        XCTAssertEqual(archive.hyperlinks.values.sorted(), ["https://example.com"])
        XCTAssertEqual(try terminal.render(), archive.rows)

        let restored = try makeTerminal(cols: 30, rows: 6)
        try restored.restore(archive)
        XCTAssertEqual(restored.size, Size(cols: 30, rows: 6))
        try restored.resize(archive.size)
        let copy = try restored.archive()
        XCTAssertEqual(copy.history, archive.history)
        XCTAssertEqual(lines(copy.rows), lines(archive.rows))
        XCTAssertEqual(copy.rows.map { $0.runs.map(\.width) }, archive.rows.map { $0.runs.map(\.width) })
        XCTAssertEqual(copy.cursor, archive.cursor)
        XCTAssertEqual(copy.hyperlinks.values.sorted(), ["https://example.com"])
        XCTAssertTrue(restored.takePtyOutput().isEmpty)
    }

    func testClearRemovesHistoryButKeepsTheCurrentLine() throws {
        let terminal = try makeTerminal(cols: 20, rows: 5)
        terminal.feed(String(repeating: "old output\r\n", count: 20) + "prompt> input")
        let generation = try terminal.historyGeneration()
        let column = try terminal.cursor().col
        XCTAssertTrue(try terminal.clearScreen())
        XCTAssertEqual(try terminal.historyCount(), 0)
        XCTAssertNotEqual(try terminal.historyGeneration(), generation)
        XCTAssertEqual(try terminal.screenLines(), ["prompt> input", "", "", "", ""])
        XCTAssertEqual(try terminal.cursor().col, column)
        XCTAssertTrue(terminal.takePtyOutput().isEmpty)
        XCTAssertEqual(try terminal.render().count, 5)
    }

    func testClearAtASemanticPromptAsksTheShellToRedraw() throws {
        let terminal = try makeTerminal(cols: 20, rows: 5)
        terminal.feed(String(repeating: "old output\r\n", count: 20))
        terminal.feed("\u{1b}]133;A\u{07}prompt\r\n> \u{1b}]133;B\u{07}multi-line input")
        XCTAssertTrue(try terminal.clearScreen())
        XCTAssertEqual(terminal.takePtyOutput(), Data([0x0c]))
        XCTAssertEqual(try terminal.historyCount(), 0)
        XCTAssertTrue(try terminal.screenLines().allSatisfy(\.isEmpty))
    }

    func testClearDoesNothingOnTheAlternateScreen() throws {
        let terminal = try makeTerminal(cols: 20, rows: 5)
        terminal.feed(String(repeating: "history\r\n", count: 20))
        terminal.feed("\u{1b}[?1049hfullscreen")
        let screen = try terminal.fullRender()
        XCTAssertFalse(try terminal.clearScreen())
        XCTAssertEqual(try terminal.fullRender(), screen)
        XCTAssertTrue(terminal.takePtyOutput().isEmpty)
    }

    func testPromptRowsComeFromSemanticMarks() throws {
        let terminal = try makeTerminal(cols: 40, rows: 4)
        for _ in 0..<10 {
            terminal.feed("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo hi\r\n\u{1b}]133;C\u{07}hi\r\n\u{1b}]133;D;0\u{07}")
        }
        terminal.feed("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}")
        XCTAssertEqual(try terminal.screenPrompts(), [1, 3])
        let count = try terminal.historyCount()
        let slice = try terminal.history(3..<count)
        XCTAssertEqual(slice.rows.count, count - 3)
        XCTAssertEqual(slice.prompts, stride(from: 1, to: count - 3, by: 2).map(UInt16.init))
        try terminal.compress()
        XCTAssertEqual(try terminal.history(3..<count), slice)
        terminal.feed("\u{1b}[?1049h")
        XCTAssertEqual(try terminal.screenPrompts(), [])
        terminal.feed("\u{1b}[?1049l")
        XCTAssertEqual(try terminal.screenPrompts(), [1, 3])
    }
}
