import TabProtocol
import XCTest
@testable import TabTerminal

final class EventTests: XCTestCase {
    func testBellTitleAndDirectoryAreCoalesced() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        terminal.feed("\u{07}\u{07}")
        XCTAssertEqual(terminal.takeEvents(), [.bell])
        XCTAssertEqual(terminal.takeEvents(), [])
        terminal.feed("\u{1b}]2;first\u{07}\u{1b}]2;hello\u{07}\u{1b}]7;file://host/tmp\u{1b}\\")
        XCTAssertEqual(terminal.takeEvents(), [.title("hello"), .directory("file://host/tmp")])
    }

    func testClipboardWritesAcceptTextWithinTheLimit() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        terminal.feed("\u{1b}]52;c;Zmlyc3Q=\u{07}")
        terminal.feed("\u{1b}]52;c;56ys5LiA6KGMCnNlY29uZCBsaW5l\u{1b}\\")
        XCTAssertEqual(terminal.takeEvents(), [.clipboardWrite("第一行\nsecond line")])
        for chunk in ["\u{1b}]52;c;ZnJh", "Z21lbnRlZA==\u{07}"] {
            terminal.feed(chunk)
        }
        XCTAssertEqual(terminal.takeEvents(), [.clipboardWrite("fragmented")])
    }

    func testClipboardWritesIgnoreReadsInvalidDataAndOtherClipboards() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        for sequence in [
            "\u{1b}]52;c;?\u{07}", "\u{1b}]52;c;not-base64!\u{07}", "\u{1b}]52;c;/w==\u{07}",
            "\u{1b}]52;p;cHJpbWFyeQ==\u{07}", "\u{1b}]52;s;c2VsZWN0aW9u\u{07}", "\u{1b}]52;c;\u{07}",
        ] {
            terminal.feed(sequence)
        }
        XCTAssertEqual(terminal.takeEvents(), [])
    }

    func testProgressReportsAcrossEveryReadBoundary() throws {
        for sequence in ["\u{1b}]9;4;1;42\u{07}", "\u{1b}]9;4;1;42\u{1b}\\"] {
            let bytes = Array(sequence.utf8)
            for split in 0..<bytes.count {
                let terminal = try makeTerminal()
                terminal.feed(Array(bytes[..<split]))
                XCTAssertEqual(terminal.takeEvents(), [])
                terminal.feed(Array(bytes[split...]))
                XCTAssertEqual(
                    terminal.takeEvents(),
                    [.progress(ProgressUpdate(report: ProgressReport(state: .running, percent: 42), completed: 0))])
            }
        }
    }

    func testProgressStatesKeepPercentAndCountCompletions() throws {
        let terminal = try makeTerminal()
        terminal.feed("\u{1b}]9;4;1;50\u{07}\u{1b}]9;4;3\u{07}")
        XCTAssertEqual(
            terminal.takeEvents(),
            [.progress(ProgressUpdate(report: ProgressReport(state: .indeterminate, percent: 50), completed: 0))])
        terminal.feed("\u{1b}]9;4;2\u{07}")
        XCTAssertEqual(
            terminal.takeEvents(),
            [.progress(ProgressUpdate(report: ProgressReport(state: .error, percent: 50), completed: 0))])
        terminal.feed("\u{1b}]9;4;1;250\u{07}\u{1b}]9;4;0\u{07}")
        XCTAssertEqual(terminal.takeEvents(), [.progress(ProgressUpdate(report: nil, completed: 1))])
    }

    func testMalformedOrForeignSequencesReportNoProgress() throws {
        let terminal = try makeTerminal()
        for sequence in [
            "\u{1b}]9;4;5;20\u{07}", "\u{1b}]9;4;1;-2\u{07}", "\u{1b}]9;4;1;bad\u{07}", "\u{1b}]9;4;1;5;9\u{07}",
            "\u{1b}]9;notification\u{07}", "\u{1b}]9;4;1;20\u{18}\u{1b}\\", "\u{1b}]9;4;1;20\u{1b}[0m",
            "\u{1b}]9;4;1;" + String(repeating: "9", count: 40) + "\u{07}",
            "\u{1b}Ppayload ]9;4;3\u{1b}\\", "\u{1b}_payload ]9;4;3\u{1b}\\", "\u{041d}9;4;3\u{041c}",
        ] {
            terminal.feed(sequence)
            XCTAssertFalse(
                terminal.takeEvents().contains { if case .progress = $0 { true } else { false } }, sequence)
        }
    }

    func testProgressExpiresWithoutRefresh() {
        var parser = ProgressParser()
        let report = Array("\u{1b}]9;4;3\u{07}".utf8)
        report.withUnsafeBufferPointer { parser.feed($0, now: 100) }
        XCTAssertNotNil(parser.take(now: 100)?.report)
        report.withUnsafeBufferPointer { parser.feed($0, now: 110) }
        XCTAssertNil(parser.take(now: 124))
        XCTAssertEqual(parser.take(now: 125), ProgressUpdate(report: nil, completed: 1))
        XCTAssertNil(parser.take(now: 200))
    }
}
