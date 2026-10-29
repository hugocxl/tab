import AppKit
import XCTest
import TabProtocol
@testable import TabApp

final class DiffDocumentTests: XCTestCase {
    private func rows(_ kinds: [GitDiffKind]) -> [GitDiffRow] {
        kinds.map { GitDiffRow(kind: $0, text: "") }
    }

    func testContextAndAdditionPaintSourceSegmentsInBothModes() {
        let cases: [(GitDiffKind, String, String?, String?)] = [
            (.context, " context", "context", "context"),
            (.addition, "+added", nil, "added"),
        ]
        for (kind, text, oldText, newText) in cases {
            let row = GitDiffRow(kind: kind, oldLineNumber: oldText.map { _ in 59 }, newLineNumber: 60,
                                 oldText: oldText, newText: newText, text: text)
            for unified in [true, false] {
                let source = DiffDocument.segments(row, old: false, unified: unified, numberColumns: 3).last!
                XCTAssertEqual(source.text, newText)
                XCTAssertEqual(source.column, unified ? 8 : 5)
            }
            var fallback = row
            fallback.oldText = nil
            fallback.newText = nil
            XCTAssertEqual(DiffDocument.segments(fallback, old: false, unified: true, numberColumns: 3).last?.text, newText)
        }
    }

    func testLineNumbersAreRightAlignedAndDim() {
        let row = GitDiffRow(kind: .deletion, oldLineNumber: 7, newLineNumber: nil, oldText: "gone", text: "-gone")
        let segments = DiffDocument.segments(row, old: true, unified: true, numberColumns: 3)
        XCTAssertEqual(segments[0], DiffDocument.Segment(column: 1, text: "7", dim: true))
        XCTAssertEqual(segments[1], DiffDocument.Segment(column: 5, text: "", dim: true))
        XCTAssertEqual(segments[2], DiffDocument.Segment(column: 6, text: "-", dim: false))
        XCTAssertEqual(segments[3].text, "gone")
    }

    func testOnlyVisibleColumnsAreDrawn() {
        let segment = DiffDocument.Segment(column: 10, text: "abcdefghij", dim: false)
        XCTAssertNil(DiffDocument.visible(segment, first: 0, last: 10))
        XCTAssertEqual(DiffDocument.visible(segment, first: 12, last: 15).map { "\($0.column):\($0.text)" }, "12:cde")
        XCTAssertNil(DiffDocument.visible(segment, first: 25, last: 30))
    }

    func testSplitPairsDeletionsWithAdditions() {
        let layout = DiffDocument.splitRows(rows([.hunk, .context, .deletion, .deletion, .addition, .context, .addition]))
        XCTAssertEqual(layout, [
            .init(left: 0, right: 0), .init(left: 1, right: 1),
            .init(left: 2, right: 4), .init(left: 3, right: nil),
            .init(left: 5, right: 5), .init(left: nil, right: 6),
        ])
    }

    func testSingleHunkHeaderIsHiddenButSeveralStay() {
        XCTAssertEqual(DiffDocument(GitDiff(rows: rows([.hunk, .context, .addition]))).rows.count, 2)
        XCTAssertEqual(DiffDocument(GitDiff(rows: rows([.hunk, .context, .hunk, .addition]))).rows.count, 4)
    }

    func testNumberColumnsFitTheLargestLineNumber() {
        let diff = GitDiff(rows: [
            GitDiffRow(kind: .context, oldLineNumber: 998, newLineNumber: 1002, oldText: "a\tb", newText: "a\tb", text: " a\tb"),
        ])
        let document = DiffDocument(diff)
        XCTAssertEqual(document.numberColumns, 5)
        XCTAssertEqual(document.maxColumns, 6)
        XCTAssertEqual(document.totalColumns(split: false), 6 + 10 + 2)
    }

    @MainActor
    func testPaneShowsTruncationAndRefreshesOnlyWhenVisible() async {
        let host = StubNativeHost()
        let transport = host.transport!
        transport.gitHandler = { _ in .diff(GitDiff(rows: [GitDiffRow(kind: .addition, newLineNumber: 1, newText: "x", text: "+x")], additions: 1, truncated: true)) }
        let pane = DiffPaneController(host: host, path: "a.swift", staged: true)
        pane.loadView()
        pane.refresh()
        await settle { pane.document != nil }
        XCTAssertEqual(pane.document?.diff.truncated, true)
        guard case .diff(let request) = transport.gitRequests.first else { return XCTFail("no diff request") }
        XCTAssertEqual(request, GitDiffRequest(path: "a.swift", staged: true, lineLimit: DiffPaneController.lineLimit, context: 1_000_000))
        pane.gitChanged()
        XCTAssertEqual(transport.gitRequests.count, 1, "a hidden diff waits until it is shown")
        XCTAssertTrue(DiffPaneController.existing(project: host.nativeProject.id, path: "a.swift", staged: true) === pane)
        XCTAssertNil(DiffPaneController.existing(project: host.nativeProject.id, path: "a.swift", staged: false))
    }
}
