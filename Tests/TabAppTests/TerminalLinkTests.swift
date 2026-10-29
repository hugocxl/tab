import XCTest
import TabProtocol
@testable import TabApp

final class TerminalLinkTests: XCTestCase {
    func testDetectionTrimsPunctuationAndKeepsBalancedBrackets() throws {
        for (text, expected) in [
            ("https://example.com/a?b=1.", "https://example.com/a?b=1"),
            ("(https://example.com/a_(b)).", "https://example.com/a_(b)"),
            ("'https://example.com',", "https://example.com"),
            ("url=https://example.com/a,", "https://example.com/a"),
            ("/etc/hosts", "/etc/hosts"),
            ("src/main.rs:12:3", "src/main.rs:12:3"),
            ("\"/tmp/my file.rs\"", "/tmp/my file.rs"),
        ] {
            let start = try XCTUnwrap(text.range(of: expected)).lowerBound
            let offset = text.distance(from: text.startIndex, to: start)
            let candidate = try XCTUnwrap(TerminalLinkDetector.detect(
                runs: [TerminalFixtures.run(text)], row: -1, column: UInt16(offset + 2)), text)
            XCTAssertEqual(candidate.text, expected, text)
            XCTAssertEqual(candidate.columns, UInt16(offset)..<UInt16(offset + expected.count), text)
            XCTAssertEqual(candidate.row, -1)
        }
    }

    func testDetectionUsesServerCellWidthsAndPrefersHyperlinks() throws {
        let runs = [TerminalFixtures.run("界", width: 2), TerminalFixtures.run("e\u{301}", width: 1),
                    TerminalFixtures.run(" https://example.com")]
        XCTAssertEqual(TerminalLinkDetector.detect(runs: runs, row: 0, column: 5)?.columns, 4..<23)
        let osc = [LinkSpan(start: 0, end: 10, uri: "https://osc.test")]
        XCTAssertEqual(TerminalLinkDetector.detect(runs: runs, row: 0, column: 5, links: osc)?.text, "https://osc.test")
        XCTAssertNil(TerminalLinkDetector.detect(runs: runs, row: 0, column: 3))
    }

    func testTargetsResolveLineAndColumnAgainstTheTerminalFolder() {
        XCTAssertEqual(TerminalLinkDetector.target(for: "src/main.rs:12:3", directory: "/repo"),
                       .file(path: "/repo/src/main.rs", line: 12, column: 3))
        XCTAssertEqual(TerminalLinkDetector.target(for: "/etc/hosts:7", directory: nil),
                       .file(path: "/etc/hosts", line: 7, column: nil))
        XCTAssertEqual(TerminalLinkDetector.target(for: "Sources/App.swift(40,2)", directory: "/r"),
                       .file(path: "/r/Sources/App.swift", line: 40, column: 2))
        XCTAssertEqual(TerminalLinkDetector.target(for: "~/notes.md", directory: nil, home: "/Users/me"),
                       .file(path: "/Users/me/notes.md", line: nil, column: nil))
        XCTAssertEqual(TerminalLinkDetector.target(for: "file:///tmp/my%20file.rs", directory: nil),
                       .file(path: "/tmp/my file.rs", line: nil, column: nil))
        XCTAssertEqual(TerminalLinkDetector.target(for: "https://example.com/x", directory: nil),
                       .url(URL(string: "https://example.com/x")!))
        XCTAssertNil(TerminalLinkDetector.target(for: "missing.rs:3", directory: "/r", exists: { _ in false }))
    }

    func testDroppedPathsAreQuotedForTheShell() {
        XCTAssertEqual(TerminalPaste.quotedPaths(["/tmp/a b", "/tmp/it's"]), "'/tmp/a b' '/tmp/it'\\''s'")
        XCTAssertEqual(TerminalPaste.quotedPaths(["/tmp/new\nline"]), "$'/tmp/new\\x0aline'")
        XCTAssertEqual(TerminalPaste.quotedPaths(["/tmp/a\tb'c"]), "$'/tmp/a\\x09b\\'c'")
        XCTAssertNil(TerminalPaste.quotedPaths(["relative/path"]))
    }

    func testPasteChunksKeepUTF8AndCRLFTogether() {
        for suffix in ["界tail", "\r\ntail"] {
            let text = String(repeating: "a", count: 9) + suffix
            let chunks = TerminalPaste.chunks(text, limit: 10)
            XCTAssertEqual(chunks.joined(), text)
            XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 10 })
            XCTAssertFalse(chunks[0].hasSuffix("\r"))
        }
    }
}
