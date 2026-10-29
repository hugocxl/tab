import TabProtocol
import XCTest
@testable import TabTerminal

final class ScreenTests: XCTestCase {
    func testTextLandsInRunsAndTrailingBlanksAreTrimmed() throws {
        let terminal = try makeTerminal()
        terminal.feed("hello world\r\nsecond")
        let rows = try terminal.fullRender()
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0].runs, [Run(text: "hello world", width: 11)])
        XCTAssertEqual(rows[1].runs, [Run(text: "second", width: 6)])
        XCTAssertEqual(rows[2].runs, [])
        XCTAssertEqual(try terminal.cursor(), Cursor(shape: .block, row: 1, col: 6, visible: true))
    }

    func testStylesSplitRuns() throws {
        let terminal = try makeTerminal(cols: 40)
        terminal.feed("a\u{1b}[1;31mbold\u{1b}[0m \u{1b}[4:3;38;2;1;2;3;48;5;200mcurly\u{1b}[0m\u{1b}[7;9;53mx")
        let runs = try terminal.fullRender()[0].runs
        XCTAssertEqual(runs.map(\.text), ["a", "bold", " ", "curly", "x"])
        var bold = Style()
        bold.bold = true
        bold.fg = .indexed(1)
        XCTAssertEqual(runs[1].style, bold)
        XCTAssertEqual(runs[3].style.underline, .curly)
        XCTAssertEqual(runs[3].style.fg, .rgb(1, 2, 3))
        XCTAssertEqual(runs[3].style.bg, .indexed(200))
        XCTAssertTrue(runs[4].style.inverse)
        XCTAssertTrue(runs[4].style.strikethrough)
        XCTAssertTrue(runs[4].style.overline)
    }

    func testBackgroundOnlyCellsKeepTheirColor() throws {
        let terminal = try makeTerminal()
        terminal.feed("\u{1b}[44m\u{1b}[2K\u{1b}[0mx")
        let runs = try terminal.fullRender()[0].runs
        XCTAssertEqual(runs.first?.text, "x")
        XCTAssertEqual(runs.dropFirst().first?.style.bg, .indexed(4))
        XCTAssertEqual(runs.reduce(0) { $0 + Int($1.width) }, 20)
    }

    func testWideCharactersAndGraphemeClustersKeepCellWidths() throws {
        for (input, expected) in [
            ("界x", [("界", 2), ("x", 1)]),
            ("👩‍💻x", [("👩‍💻", 2), ("x", 1)]),
            ("❤️x", [("❤️", 2), ("x", 1)]),
            ("🇦🇧x", [("🇦🇧", 2), ("x", 1)]),
            ("abce\u{301}xyz", [("abc", 3), ("e\u{301}", 1), ("xyz", 3)]),
            ("\u{1b}[?2027l👩‍💻x", [("👩‍", 2), ("💻", 2), ("x", 1)]),
        ] {
            let terminal = try makeTerminal()
            for byte in Array(input.utf8) {
                terminal.feed([byte])
            }
            let runs = try terminal.fullRender()[0].runs
            XCTAssertEqual(runs.map { $0.text }, expected.map(\.0), input)
            XCTAssertEqual(runs.map { Int($0.width) }, expected.map(\.1), input)
            XCTAssertEqual(Int(try terminal.cursor().col), expected.reduce(0) { $0 + $1.1 }, input)
        }
    }

    func testRenderReportsOnlyChangedRowsThenNothing() throws {
        let terminal = try makeTerminal()
        terminal.feed("first")
        XCTAssertEqual(try terminal.render().count, 6)
        terminal.feed("\r\nsecond")
        let changed = try terminal.render()
        XCTAssertEqual(changed.map(\.index), [1])
        XCTAssertEqual(changed.first?.runs, [Run(text: "second", width: 6)])
        XCTAssertEqual(try terminal.render(), [])
        terminal.feed("\r\u{1b}[1Asame\u{1b}[2;1Hsecond")
        XCTAssertEqual(try terminal.render().map(\.index), [0])
    }

    func testFullRenderDoesNotConsumeChanges() throws {
        let terminal = try makeTerminal()
        _ = try terminal.render()
        terminal.feed("x")
        _ = try terminal.fullRender()
        XCTAssertEqual(try terminal.render().map(\.index), [0])
    }

    func testResizeKeepsContentAndRedrawsEveryRow() throws {
        let terminal = try makeTerminal()
        terminal.feed("one\r\ntwo\r\nthree\r\nfour")
        _ = try terminal.render()
        try terminal.resize(Size(cols: 30, rows: 4))
        let rows = try terminal.render()
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(lines(rows).prefix(4), ["one", "two", "three", "four"])
        try terminal.resize(Size(cols: 3, rows: 2))
        let cursor = try terminal.cursor()
        XCTAssertLessThan(cursor.row, 2)
        XCTAssertLessThan(cursor.col, 3)
        XCTAssertEqual(try terminal.render().count, 2)
        XCTAssertEqual(try terminal.render(), [])
    }

    func testCursorPositionRequestIsAnsweredOnThePty() throws {
        let terminal = try makeTerminal()
        XCTAssertTrue(terminal.takePtyOutput().isEmpty)
        terminal.feed("\u{1b}[2;5H\u{1b}[6n")
        XCTAssertEqual(terminal.takePtyOutput(), Data("\u{1b}[2;5R".utf8))
        XCTAssertTrue(terminal.takePtyOutput().isEmpty)
    }

    func testModesFollowTheProgram() throws {
        let terminal = try makeTerminal()
        XCTAssertEqual(try terminal.modes(), Modes())
        terminal.feed("\u{1b}[?1h\u{1b}[?2004h")
        let modes = try terminal.modes()
        XCTAssertTrue(modes.applicationCursorKeys)
        XCTAssertTrue(modes.bracketedPaste)
        terminal.feed("\u{1b}[?2026h")
        XCTAssertTrue(try terminal.synchronizedOutput())
        try terminal.endSynchronizedOutput()
        XCTAssertFalse(try terminal.synchronizedOutput())
        terminal.feed("\u{1b}[5 q\u{1b}[?25l")
        let cursor = try terminal.cursor()
        XCTAssertEqual(cursor.shape, .bar)
        XCTAssertFalse(cursor.visible)
    }

    func testColorSchemeReportFollowsTheThemeWhenRequested() throws {
        let terminal = try makeTerminal()
        let dark = TerminalTheme(
            foreground: ThemeColor(230, 230, 230), background: ThemeColor(10, 10, 10),
            cursor: ThemeColor(255, 255, 255),
            ansi: Array(repeating: ThemeColor(1, 1, 1), count: 16), palette: [200: ThemeColor(9, 9, 9)])
        try terminal.setDefaults(dark)
        XCTAssertTrue(terminal.takePtyOutput().isEmpty)
        terminal.feed("\u{1b}[?996n")
        XCTAssertEqual(terminal.takePtyOutput(), Data("\u{1b}[?997;1n".utf8))
        terminal.feed("\u{1b}[?2031h")
        var light = dark
        light.background = ThemeColor(250, 250, 250)
        try terminal.setDefaults(light)
        XCTAssertEqual(terminal.takePtyOutput(), Data("\u{1b}[?997;2n".utf8))
        try terminal.setDefaults(light)
        XCTAssertTrue(terminal.takePtyOutput().isEmpty)
    }
}
