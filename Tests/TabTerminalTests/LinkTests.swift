import TabProtocol
import XCTest
@testable import TabTerminal

final class LinkTests: XCTestCase {
    private func osc(_ uri: String, _ text: String) -> String {
        "\u{1b}]8;;\(uri)\u{1b}\\\(text)\u{1b}]8;;\u{1b}\\"
    }

    func testHyperlinksBecomeSpansAndStyleIds() throws {
        let terminal = try makeTerminal(cols: 40, rows: 3)
        terminal.feed("see " + osc("https://example.com", "link") + " " + osc("https://example.com", "界"))
        let rows = try terminal.render()
        XCTAssertEqual(
            terminal.hyperlinkRows(),
            [HyperlinkRow(row: 0, spans: [
                HyperlinkSpan(start: 4, end: 8, uri: "https://example.com"),
                HyperlinkSpan(start: 9, end: 11, uri: "https://example.com"),
            ])])
        let linked = rows[0].runs.filter { $0.style.hyperlink != 0 }
        XCTAssertEqual(linked.map(\.text), ["link", "界"])
        XCTAssertEqual(terminal.hyperlinkURI(linked[0].style.hyperlink), "https://example.com")

        terminal.feed("\r" + osc("https://other.test", "link"))
        XCTAssertEqual(try terminal.render().count, 1)
        XCTAssertEqual(terminal.hyperlinkRows()[0].spans[0].uri, "https://other.test")
        terminal.feed("\u{1b}[2J\u{1b}[H")
        _ = try terminal.render()
        XCTAssertEqual(terminal.hyperlinkRows(), [])
    }

    func testHyperlinkBudgetsAreBoundedAndRecover() throws {
        let terminal = try makeTerminal(cols: 2048, rows: 2)
        terminal.feed(osc("https://example.com/" + String(repeating: "x", count: maxHyperlinkURI), "ignored"))
        _ = try terminal.render()
        XCTAssertEqual(terminal.hyperlinkRows(), [])
        terminal.feed("\u{1b}[2J\u{1b}[H")
        for index in 0..<(maxHyperlinkSpans + 10) {
            terminal.feed(osc("https://test/\(index)", "x"))
        }
        _ = try terminal.render()
        XCTAssertEqual(terminal.hyperlinkRows().reduce(0) { $0 + $1.spans.count }, maxHyperlinkSpans)
        terminal.feed("\u{1b}[H\u{1b}[2K\u{1b}[2;1H" + osc("https://recovered.test", "yes"))
        _ = try terminal.render()
        XCTAssertEqual(terminal.hyperlinkRows().map(\.row), [1])
        XCTAssertEqual(terminal.hyperlinkRows().first?.spans.first?.uri, "https://recovered.test")
    }

    func testDetectionTrimsPunctuationAndKeepsBalancedURLsAndFileLocations() {
        for (line, expected, kind) in [
            ("https://example.com/a?b=1.", "https://example.com/a?b=1", LinkCandidate.Kind.url),
            ("(https://example.com/a_(b)).", "https://example.com/a_(b)", .url),
            ("'https://example.com',", "https://example.com", .url),
            ("url=https://example.com/a,", "https://example.com/a", .url),
            ("/etc/hosts", "/etc/hosts", .path),
            ("src/main.rs:12:3", "src/main.rs:12:3", .path),
            ("\"/tmp/my file.rs\"", "/tmp/my file.rs", .path),
            ("file:///tmp/my%20file.rs", "file:///tmp/my%20file.rs", .url),
        ] {
            let offset = line.range(of: expected)!.lowerBound.utf16Offset(in: line)
            let runs = [Run(text: line, width: UInt16(line.count))]
            let candidate = LinkDetector.candidate(in: runs, at: UInt16(offset + 2))
            XCTAssertEqual(candidate?.text, expected, line)
            XCTAssertEqual(candidate?.kind, kind, line)
            XCTAssertEqual(candidate?.columns, UInt16(offset)..<UInt16(offset + expected.count), line)
        }
    }

    func testDetectionUsesCellWidthsAndPrefersHyperlinks() {
        let runs = [Run(text: "界", width: 2), Run(text: "e\u{301}", width: 1), Run(text: " https://example.com", width: 20)]
        XCTAssertEqual(LinkDetector.candidate(in: runs, at: 5)?.columns, 4..<23)
        let explicit = [HyperlinkSpan(start: 0, end: 10, uri: "https://osc.test")]
        XCTAssertEqual(LinkDetector.candidate(in: runs, at: 5, hyperlinks: explicit)?.text, "https://osc.test")
        XCTAssertEqual(LinkDetector.candidates(in: runs).map(\.text), ["https://example.com"])
        let mixed = [Run(text: "error in Sources/App/main.swift:10 see https://x.dev and words", width: 62)]
        XCTAssertEqual(
            LinkDetector.candidates(in: mixed).map(\.text), ["Sources/App/main.swift:10", "https://x.dev"])
    }
}
