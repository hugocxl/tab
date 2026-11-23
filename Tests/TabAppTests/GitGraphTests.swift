import XCTest
import TabProtocol
@testable import TabApp
@testable import TabGitGraphPlugin

final class GitGraphTests: XCTestCase {
    private func commit(_ hash: String, _ parents: [String] = [], refs: [GitRef] = []) -> GitCommit {
        GitCommit(hash: hash, shortHash: hash, subject: hash, authorName: "A", authorDate: "2026-11-23T10:00:00Z",
                  parentHashes: parents, refs: refs)
    }

    private func layout(_ commits: [GitCommit]) -> GitGraphLayout {
        var layout = GitGraphLayout()
        for commit in commits { layout.append(hash: commit.hash, parents: commit.parentHashes) }
        return layout
    }

    func testLinearHistoryStaysInOneLane() {
        let layout = layout([commit("c", ["b"]), commit("b", ["a"]), commit("a")])
        XCTAssertEqual(layout.rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(layout.maxWidth, 1)
        XCTAssertEqual(Array(layout.edges(of: 0)).map(\.kind), [.outgoing])
        XCTAssertEqual(Array(layout.edges(of: 1)).map(\.kind), [.incoming, .outgoing])
        XCTAssertEqual(Array(layout.edges(of: 2)).map(\.kind), [.incoming])
    }

    func testMergeOpensALaneThatClosesAtTheForkPoint() {
        // m merges f into main; f and b both come from a.
        let layout = layout([commit("m", ["b", "f"]), commit("f", ["a"]), commit("b", ["a"]), commit("a")])
        XCTAssertEqual(layout.rows.map(\.lane), [0, 1, 0, 0])
        XCTAssertEqual(layout.maxWidth, 2)
        let merge = Array(layout.edges(of: 0))
        XCTAssertEqual(merge.filter { $0.kind == .outgoing }.map(\.to), [0, 1])
        // At f, main's lane passes through.
        XCTAssertTrue(layout.edges(of: 1).contains(GraphEdge(.through, from: 0, to: 0, color: layout.rows[0].color)))
        // Both lanes wait for a, so they meet in its node and the right one ends.
        let root = Array(layout.edges(of: 3))
        XCTAssertEqual(Set(root.filter { $0.kind == .incoming }.map(\.from)), [0, 1])
        XCTAssertEqual(layout.rows[3].width, 2)
    }

    func testGraphWidthIgnoresRareWideStretches() {
        var layout = GitGraphLayout()
        // Twenty tips side by side, then a long single line.
        for tip in 0..<20 { layout.append(hash: "t\(tip)", parents: ["p\(tip)"]) }
        for tip in 0..<20 { layout.append(hash: "p\(tip)", parents: []) }
        for index in 0..<2000 { layout.append(hash: "l\(index)", parents: ["l\(index + 1)"]) }
        XCTAssertEqual(layout.maxWidth, 20)
        XCTAssertEqual(layout.width(covering: 0.95), 1)
        XCTAssertEqual(layout.width(covering: 1), 20)
    }

    func testSeparateTipsGetTheirOwnLanesAndColors() {
        let layout = layout([commit("x", ["a"]), commit("y", ["a"]), commit("a")])
        XCTAssertEqual(layout.rows.map(\.lane), [0, 1, 0])
        XCTAssertNotEqual(layout.rows[0].color, layout.rows[1].color)
        // A freed lane is reused by the next new tip.
        var reused = layout
        reused.append(hash: "z", parents: [])
        XCTAssertEqual(reused.rows.last?.lane, 0)
    }

    func testPagesLayOutLikeOneList() {
        let commits = [commit("m", ["b", "f"]), commit("f", ["e"]), commit("b", ["a"]), commit("e", ["a"]),
                       commit("a")]
        var model = GitGraphModel()
        model.reset(summary: nil, commits: Array(commits.prefix(2)), requested: 2)
        XCTAssertFalse(model.exhausted)
        model.append(Array(commits.dropFirst(2)), requested: 4)
        XCTAssertTrue(model.exhausted)
        let whole = layout(commits)
        XCTAssertEqual(model.layout.rows, whole.rows)
        XCTAssertEqual(model.layout.edges, whole.edges)
        // A page overlapping what is shown, after history moved, adds nothing twice.
        model.append([commit("a")], requested: 1)
        XCTAssertEqual(model.rowCount, 5)
    }

    func testWorkInProgressSitsAboveHead() {
        var summary = GitSummary(branch: "main", head: "b")
        summary.changed = 3
        var model = GitGraphModel()
        model.reset(summary: summary, commits: [commit("b", ["a"]), commit("a")], requested: 400)
        XCTAssertEqual(model.rowCount, 3)
        XCTAssertEqual(model.row(0), .workInProgress(changed: 3))
        XCTAssertEqual(model.row(of: "b"), 1)
        XCTAssertEqual(model.headRow, 0)
        XCTAssertEqual(model.layout.rows.map(\.lane), [0, 0, 0])
        // Another count of changed files keeps the rows.
        summary.changed = 5
        XCTAssertTrue(model.keep(summary: summary, firstPage: [commit("b", ["a"])]))
        XCTAssertEqual(model.row(0), .workInProgress(changed: 5))
        // A clean tree drops the row, and a new commit changes the history.
        summary.changed = 0
        XCTAssertFalse(model.keep(summary: summary, firstPage: [commit("b", ["a"])]))
        summary.changed = 5
        XCTAssertFalse(model.keep(summary: summary, firstPage: [commit("c", ["b"])]))
    }

    func testLabelsPutTheCurrentBranchFirstAndFoldRemoteTwins() {
        let refs = [GitRef(name: "origin/main", kind: .remoteBranch), GitRef(name: "origin/HEAD", kind: .remoteBranch),
                    GitRef(name: "v1", kind: .tag), GitRef(name: "topic", kind: .localBranch),
                    GitRef(name: "main", kind: .localBranch), GitRef(name: "origin/other", kind: .remoteBranch),
                    GitRef(name: "HEAD", kind: .head)]
        XCTAssertEqual(GraphRefLabel.labels(for: refs, currentBranch: "main"), [
            GraphRefLabel(name: "main", kind: .current),
            GraphRefLabel(name: "topic", kind: .local(synced: false)),
            GraphRefLabel(name: "origin/other", kind: .remote),
            GraphRefLabel(name: "v1", kind: .tag),
        ])
        XCTAssertEqual(GraphRefLabel.labels(for: [GitRef(name: "HEAD", kind: .head)], currentBranch: nil),
                       [GraphRefLabel(name: "HEAD", kind: .head)])
    }

    func testRelativeDates() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertEqual(GraphDate.relative(now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(GraphDate.relative(now.addingTimeInterval(-3 * 3600), now: now), "3h")
        XCTAssertEqual(GraphDate.relative(now.addingTimeInterval(-10 * 86_400), now: now), "1w")
        XCTAssertEqual(GraphDate.relative(now.addingTimeInterval(-800 * 86_400), now: now), "2y")
        XCTAssertNotNil(GraphDate.parse("2026-11-23T14:03:35+01:00"))
    }
}
