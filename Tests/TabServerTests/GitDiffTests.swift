import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class GitDiffTests: XCTestCase {
    private func diff(_ repo: GitTestRepo, _ request: GitDiffRequest) throws -> GitDiff {
        guard case .diff(let diff) = try repo.git(.diff(request)) else { throw GitTestError.failed("diff") }
        return diff
    }

    func testDiffsAndStatusSeparateStagedWorktreeUntrackedAndBinaryChanges() throws {
        let repo = try GitTestRepo(commit: false)
        let relative = ServerPath("file [*] \n.txt")
        try repo.write(relative.rawValue, "one\ntwo\n")
        try repo.commit("initial")
        try repo.write(relative.rawValue, "one\nstaged\n")
        _ = try repo.git(.stage([relative]))
        try repo.write(relative.rawValue, "one\nworking\nextra\n")
        for (staged, expected, additions) in [(true, "+staged", UInt64(1)), (false, "+working", 2)] {
            let diff = try diff(repo, GitDiffRequest(path: relative, staged: staged))
            XCTAssertEqual(diff.additions, additions)
            XCTAssertEqual(diff.deletions, 1)
            XCTAssertTrue(diff.rows.contains { $0.text == expected && $0.kind == .addition })
            XCTAssertTrue(diff.rows.contains { $0.newLineNumber == 2 && $0.kind == .addition })
            XCTAssertEqual(diff.rows.first?.kind, .hunk)
        }
        guard case .status(let status) = try repo.git(.status(local: true)) else { return XCTFail("status") }
        XCTAssertEqual(status.files[0].staged.additions, 1)
        XCTAssertEqual(status.files[0].unstaged.additions, 2)

        guard case .rawDiff(let raw) = try repo.git(.rawDiff(GitDiffRequest(lineLimit: 2))) else {
            return XCTFail("raw")
        }
        XCTAssertTrue(raw.truncated)
        XCTAssertEqual(raw.diff.split(separator: "\n").count, 2)

        try repo.write("untracked", "new\nlast")
        let untracked = try diff(repo, GitDiffRequest(path: "untracked"))
        XCTAssertEqual(untracked.additions, 2)
        XCTAssertFalse(untracked.binary)

        try Data([0x61, 0, 0x62]).write(to: URL(fileURLWithPath: repo.path + "/binary"))
        _ = try repo.git(.stage(["binary"]))
        guard case .status(let binaryStatus) = try repo.git(.status(local: true)) else { return XCTFail("status") }
        XCTAssertTrue(try XCTUnwrap(binaryStatus.files.first { $0.file.path == "binary" }).staged.binary)
        try Data([0, 1]).write(to: URL(fileURLWithPath: repo.path + "/untracked binary"))
        for (name, staged) in [("binary", true), ("untracked binary", false)] {
            let diff = try diff(repo, GitDiffRequest(path: ServerPath(name), staged: staged))
            XCTAssertTrue(diff.binary && diff.rows.isEmpty, name)
        }
        for bad in ["../outside", ".git/config", "/etc/passwd"] {
            XCTAssertThrowsError(try repo.git(.diff(GitDiffRequest(path: ServerPath(bad)))), bad)
        }
    }

    func testFullContextDiffKeepsEveryLineAndReportsTruncation() throws {
        let repo = try GitTestRepo(commit: false)
        let original = (1 ... 100).map { "line \($0)\n" }.joined()
        let modified = original.replacingOccurrences(of: "line 50\n", with: "changed\n")
        try repo.write("file", original)
        try repo.commit("initial")
        try repo.write("file", modified)
        for staged in [false, true] {
            if staged { _ = try repo.git(.stage(["file"])) }
            for lineLimit in [nil, UInt32(20)] {
                let diff = try diff(repo, GitDiffRequest(path: "file", staged: staged, lineLimit: lineLimit,
                                                         context: 1_000_000))
                XCTAssertEqual(diff.truncated, lineLimit != nil)
                if lineLimit != nil { continue }
                XCTAssertEqual(diff.rows.compactMap(\.oldText), original.split(separator: "\n").map(String.init))
                XCTAssertEqual(diff.rows.compactMap(\.newText), modified.split(separator: "\n").map(String.init))
                XCTAssertEqual(diff.additions, 1)
                XCTAssertEqual(diff.deletions, 1)
                XCTAssertEqual(diff.rows.last?.newLineNumber, 100)
            }
        }
        try repo.write("untracked", original)
        let untracked = try diff(repo, GitDiffRequest(path: "untracked", context: 1_000_000))
        XCTAssertEqual(untracked.additions, 100)
        XCTAssertFalse(untracked.truncated)
    }

    func testLargeDiffIsBoundedAndReportsTruncation() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("large", String(repeating: "a", count: 2 * 1024 * 1024))
        let diff = try diff(repo, GitDiffRequest(path: "large"))
        XCTAssertTrue(diff.truncated)
        XCTAssertLessThan(try JSONEncoder().encode(GitReply.diff(diff)).count, 16 * 1024 * 1024)
    }

    func testDiffParserNumbersLinesPerHunk() {
        let raw = GitRawDiff(diff: """
        diff --git a/file b/file
        index 1..2 100644
        --- a/file
        +++ b/file
        @@ -3,2 +3,3 @@ context
         keep
        -old
        +new
        +more
        @@ -10 +11 @@
        -x
        +y
        \\ No newline at end of file

        """)
        let diff = GitParsing.diff(raw)
        XCTAssertEqual(diff.rows.map(\.kind), [.hunk, .context, .deletion, .addition, .addition, .hunk, .deletion, .addition])
        XCTAssertEqual(diff.rows[1].oldLineNumber, 3)
        XCTAssertEqual(diff.rows[2].oldLineNumber, 4)
        XCTAssertNil(diff.rows[2].newLineNumber)
        XCTAssertEqual(diff.rows[4].newLineNumber, 5)
        XCTAssertEqual(diff.rows[7].newLineNumber, 11)
        XCTAssertEqual(diff.rows[6].oldText, "x")
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertEqual([diff.additions, diff.deletions], [3, 2])
        XCTAssertEqual(GitParsing.bounded(Data("a\nb\nc\n".utf8), truncated: false, lineLimit: 3),
                       GitRawDiff(diff: "a\nb\nc\n", truncated: false))
        XCTAssertEqual(GitParsing.bounded(Data("a\nb\nc\n".utf8), truncated: false, lineLimit: 2),
                       GitRawDiff(diff: "a\nb\n", truncated: true))
    }

    func testBranchDiffIncludesCommittedBranchChanges() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.addRemote()
        try repo.run("push", "-u", "origin", "main")
        _ = try repo.git(.createBranch("feature"))
        try repo.write("committed", "earlier branch work\n")
        try repo.commit("earlier work")
        guard case .rawDiff(let diff) = try repo.git(.branchDiff(base: "main", lineLimit: 800)) else {
            return XCTFail("diff")
        }
        XCTAssertTrue(diff.diff.contains("earlier branch work"))
    }
}
