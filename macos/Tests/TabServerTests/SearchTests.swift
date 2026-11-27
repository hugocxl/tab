import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class SearchTests: XCTestCase {
    private let withoutRipgrep = ExecutableLookup { name in
        name == "rg" ? nil : ExecutableLookup.system(name)
    }

    func testFileListFallsBackToGitWhenRipgrepIsMissing() async throws {
        let workspace = try FilesWorkspace(lookup: withoutRipgrep)
        try workspace.git("init", "-q")
        try await workspace.write(".gitignore", "build/\n")
        try await workspace.write("tracked.swift", "x")
        try await workspace.write("untracked.md", "x")
        _ = try await workspace.files(.mkdir("build"))
        try await workspace.write("build/output", "x")
        try workspace.git("add", "tracked.swift")
        let reply = try await workspace.files(.searchFiles(limit: 100))
        XCTAssertEqual(reply, .fileList(FileList(paths: [".gitignore", "tracked.swift", "untracked.md"])))
        let limited = try await workspace.files(.searchFiles(limit: 2))
        XCTAssertEqual(limited, .fileList(FileList(paths: [".gitignore", "tracked.swift"], truncated: true)))
    }

    func testFileListWithoutRipgrepOrRepositoryIsEmpty() async throws {
        let workspace = try FilesWorkspace(lookup: withoutRipgrep)
        try await workspace.write("file", "x")
        let reply = try await workspace.files(.searchFiles(limit: 100))
        XCTAssertEqual(reply, .fileList(FileList(paths: [])))
    }

    func testContentSearchWithoutRipgrepExplainsWhatToInstall() async throws {
        let workspace = try FilesWorkspace(lookup: withoutRipgrep)
        do {
            _ = try await workspace.files(.searchContent(ContentSearchQuery(query: "x")))
            XCTFail("searched without rg")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("ripgrep"), error.message)
        }
    }

    func testRipgrepFilesAndContentSearch() async throws {
        guard ExecutableLookup.system("rg") != nil else { throw XCTSkip("rg is not installed") }
        let workspace = try FilesWorkspace()
        _ = try await workspace.files(.mkdir("src"))
        try await workspace.write("src/a.swift", "let héllo = Foo.bar\nfoo foo\n")
        try await workspace.write(".hidden", "FOO\n")
        guard case .fileList(let list) = try await workspace.files(.searchFiles(limit: 10)) else { return XCTFail() }
        XCTAssertEqual(list.paths, [".hidden", "src/a.swift"])

        let insensitive = try await workspace.files(.searchContent(ContentSearchQuery(query: "foo")))
        guard case .searchResults(let results) = insensitive else { return XCTFail() }
        let byPath = Dictionary(uniqueKeysWithValues: results.files.map { ($0.path, $0.matches) })
        XCTAssertEqual(byPath[".hidden"]?.first?.line, 1)
        let swift = try XCTUnwrap(byPath["src/a.swift"])
        XCTAssertEqual(swift.map(\.line), [1, 2])
        XCTAssertEqual(swift[0].column, 13)
        XCTAssertEqual(swift[0].ranges, [MatchRange(start: 12, end: 15)])
        XCTAssertEqual(swift[1].ranges, [MatchRange(start: 0, end: 3), MatchRange(start: 4, end: 7)])

        let sensitive = try await workspace.files(.searchContent(ContentSearchQuery(query: "FOO", caseSensitive: true)))
        guard case .searchResults(let exact) = sensitive else { return XCTFail() }
        XCTAssertEqual(exact.files.map(\.path), [".hidden"])

        let literal = try await workspace.files(.searchContent(ContentSearchQuery(query: "Foo.bar")))
        guard case .searchResults(let literalResults) = literal else { return XCTFail() }
        XCTAssertEqual(literalResults.files.count, 1)
        let regex = try await workspace.files(.searchContent(ContentSearchQuery(query: "F.o\\.b", regex: true)))
        guard case .searchResults(let regexResults) = regex else { return XCTFail() }
        XCTAssertEqual(regexResults.files.map(\.path), ["src/a.swift"])
        await assertFilesThrows(try await workspace.files(.searchContent(ContentSearchQuery(query: "(", regex: true))))
    }

    func testParsesMultipleSubmatchesMultilineBlocksAndBinaryFields() {
        let output = """
        {"type":"begin"}
        garbage
        {"type":"match","data":{"path":{"text":"src/a.rs"},"lines":{"text":"foo foo\\nbar foo\\r\\n"},"line_number":7,"submatches":[{"start":0,"end":3},{"start":4,"end":7},{"start":12,"end":15},{"start":900,"end":903}]}}
        {"type":"match","data":{"path":{"bytes":"Yf8="},"lines":{"bytes":"/2ZvbyA="},"line_number":1,"submatches":[{"start":1,"end":4}]}}
        {"type":"match","data":{}}
        {"type":"summary"}
        """
        let result = ProjectSearch.parse(Data(output.utf8))
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.files[0].path, "src/a.rs")
        XCTAssertEqual(result.files[0].matches, [
            ContentMatch(line: 7, column: 1, preview: "foo foo",
                         ranges: [MatchRange(start: 0, end: 3), MatchRange(start: 4, end: 7)]),
            ContentMatch(line: 8, column: 5, preview: "bar foo", ranges: [MatchRange(start: 4, end: 7)]),
        ])
        XCTAssertEqual(result.files[1].path, "a\u{FFFD}")
        XCTAssertEqual(result.files[1].matches.first?.preview, "\u{FFFD}foo ")
        XCTAssertEqual(result.files[1].matches.first?.column, 2)
    }

    func testParsingCapsMatchesPerFileAndInTotal() {
        var output = ""
        for line in 1 ... 5 {
            for file in ["a", "b"] {
                output += #"{"type":"match","data":{"path":{"text":"\#(file)"},"lines":{"text":"x\n"},"#
                    + #""line_number":\#(line),"submatches":[{"start":0,"end":1}]}}"# + "\n"
            }
        }
        let perFile = ProjectSearch.parse(Data(output.utf8), maxMatchesPerFile: 3)
        XCTAssertEqual(perFile.files.map(\.matches.count), [3, 3])
        XCTAssertTrue(perFile.truncated)
        let total = ProjectSearch.parse(Data(output.utf8), maxTotal: 4)
        XCTAssertEqual(total.files.map(\.matches.count), [2, 2])
        XCTAssertTrue(total.truncated)
    }
}
