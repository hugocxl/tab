import Foundation
import XCTest
@testable import TabServer

/// The archive of a conversation's dropped items grows without limit, so its pages are
/// read from an index rather than by splitting the whole file.
final class AgentEarlierArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func strings(_ lines: AgentEarlierArchive.Lines?) -> [String] {
        guard let lines else { return [] }
        return (0..<lines.count).map { String(decoding: lines[$0], as: UTF8.self) }
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testLinesMatchSplittingTheFileAsItGrows() throws {
        let archive = AgentEarlierArchive()
        let file = directory.appendingPathComponent("a.jsonl")
        XCTAssertNil(archive.lines(of: file), "No archive yet")
        try Data("one\n\ntwo\nthr".utf8).write(to: file)
        XCTAssertEqual(strings(archive.lines(of: file)), ["one", "two", "thr"], "Empty lines are skipped; an unfinished one counts")
        try append("ee\nfour\n", to: file)
        XCTAssertEqual(strings(archive.lines(of: file)), ["one", "two", "three", "four"], "Only the new bytes are indexed")
        let data = try Data(contentsOf: file)
        XCTAssertEqual(strings(archive.lines(of: file)),
                       data.split(separator: 0x0A, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) })
    }

    func testAReplacedOrShortenedFileIsIndexedAgain() throws {
        let archive = AgentEarlierArchive()
        let file = directory.appendingPathComponent("b.jsonl")
        try Data("first\nsecond\nthird\n".utf8).write(to: file)
        XCTAssertEqual(archive.lines(of: file)?.count, 3)
        // A reset moves the archive away and starts another at the same path.
        try FileManager.default.removeItem(at: file)
        try Data("new\n".utf8).write(to: file)
        XCTAssertEqual(strings(archive.lines(of: file)), ["new"])
        try Data("x\n".utf8).write(to: file, options: .atomic)
        XCTAssertEqual(strings(archive.lines(of: file)), ["x"])
    }

    func testIndexesStayBounded() throws {
        let archive = AgentEarlierArchive(indexLimit: 2)
        for name in ["c", "d", "e"] {
            let file = directory.appendingPathComponent(name + ".jsonl")
            try Data("\(name)\n".utf8).write(to: file)
            XCTAssertEqual(strings(archive.lines(of: file)), [name])
        }
        XCTAssertEqual(strings(archive.lines(of: directory.appendingPathComponent("c.jsonl"))), ["c"], "An evicted index is built again")
    }
}
