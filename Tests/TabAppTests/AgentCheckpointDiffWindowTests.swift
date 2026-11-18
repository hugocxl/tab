import AppKit
import TabProtocol
import TabCore
import XCTest
@testable import TabApp

private actor CheckpointDiffGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func fetch(_ request: AgentCheckpointRequest) async -> AgentCheckpointReply {
        let files: [AgentTurnCheckpoint.File] = [
            .init(path: "first.swift", additions: 1, deletions: 0),
            .init(path: "second.swift", additions: 1, deletions: 0)
        ]
        if request.path == "first.swift" {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .init(checkpoint: request.checkpoint, files: files, totalFiles: 2, path: request.path,
                     diff: request.path.map { .init(rows: [.init(kind: .addition, newLineNumber: 1, text: "+" + $0)], additions: 1) })
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class AgentCheckpointDiffWindowTests: XCTestCase {
    func testHistoricalDiffControlsUseTheConversationsLightAppearance() {
        _ = NSApplication.shared
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let controller = AgentCheckpointDiffWindow(session: SessionId(), checkpoint: "turn", path: nil, theme: theme) { request in
            .init(checkpoint: request.checkpoint, files: [], totalFiles: 0)
        }
        defer { controller.close() }
        XCTAssertEqual(controller.window?.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(controller.window?.contentView?.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    }

    func testSlowPreviousSelectionCannotReplaceTheSelectedFile() async throws {
        _ = NSApplication.shared
        let gate = CheckpointDiffGate()
        let controller = AgentCheckpointDiffWindow(session: SessionId(), checkpoint: UUID().uuidString,
            path: "first.swift", theme: AppTheme(systemIsDark: false), fetch: { await gate.fetch($0) })
        defer { controller.close() }
        for _ in 0..<100 {
            if await gate.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await gate.waiting
        XCTAssertTrue(waiting)
        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let diff = try XCTUnwrap(descendants(content).compactMap { $0 as? DiffRowsView }.first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for _ in 0..<100 where diff.document == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(diff.document?.rows.last?.text, "+second.swift")
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(diff.document?.rows.last?.text, "+second.swift")
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not met", file: file, line: line)
    }

    /// A 40-line file whose line 20 changed, and a deleted 8-line file, as a checkpoint recorded
    /// them; only the context asked for comes back. `honorsContext` false is an older server.
    private final class HistoricalCheckpoint {
        var requests: [AgentCheckpointRequest] = []
        var honorsContext = true
        let files: [AgentTurnCheckpoint.File] = [.init(path: "file.swift", additions: 1, deletions: 1),
                                                 .init(path: "gone.swift", additions: 0, deletions: 8)]

        func reply(_ request: AgentCheckpointRequest) -> AgentCheckpointReply {
            requests.append(request)
            guard let path = request.path else { return .init(checkpoint: request.checkpoint, files: files, totalFiles: 2) }
            let context = honorsContext ? request.context ?? 3 : 3
            var rows: [GitDiffRow] = [.init(kind: .hunk, text: "@@")]
            if path == "gone.swift" {
                rows += (UInt64(1)...8).map { (line: UInt64) in GitDiffRow(kind: .deletion, oldLineNumber: line, text: "-old \(line)") }
            } else {
                for line in UInt64(max(1, 20 - context))..<20 { rows.append(.init(kind: .context, oldLineNumber: line, newLineNumber: line, text: " line \(line)")) }
                rows.append(.init(kind: .deletion, oldLineNumber: 20, text: "-line 20"))
                rows.append(.init(kind: .addition, newLineNumber: 20, text: "+line 20 changed"))
                for line in UInt64(21)...UInt64(min(40, 20 + context)) { rows.append(.init(kind: .context, oldLineNumber: line, newLineNumber: line, text: " line \(line)")) }
            }
            return .init(checkpoint: request.checkpoint, files: files, totalFiles: 2, path: path,
                         diff: GitDiff(rows: rows, additions: 1, deletions: 1), context: honorsContext ? context : nil)
        }
    }

    private func window(_ checkpoint: HistoricalCheckpoint, comments: [AgentReviewComment] = []) async throws
        -> (AgentCheckpointDiffWindow, DiffRowsView, AgentCheckpointDiffWindowParts) {
        _ = NSApplication.shared
        let controller = AgentCheckpointDiffWindow(session: SessionId(), checkpoint: Self.checkpointID, path: "file.swift",
                                                   theme: AppTheme(systemIsDark: false)) { checkpoint.reply($0) }
        addTeardownBlock { controller.close() }
        controller.onReviewChange = { _ in }
        controller.reviewComments = comments
        let content = try XCTUnwrap(controller.window?.contentView)
        let rows = try XCTUnwrap(descendants(content).compactMap { $0 as? DiffRowsView }.first)
        try await wait { rows.document != nil }
        let buttons = descendants(content).compactMap { $0 as? PillButton }
        let parts = AgentCheckpointDiffWindowParts(
            moreContext: try XCTUnwrap(buttons.first { $0.title == "More context" }),
            addComment: try XCTUnwrap(buttons.first { $0.title == "Add comment" }),
            table: try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first),
            mode: try XCTUnwrap(descendants(content).compactMap { $0 as? SegmentedPill }.first),
            labels: { self.descendants(content).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue) })
        return (controller, rows, parts)
    }
    private static let checkpointID = UUID().uuidString

    private func comment(_ path: String, old: Bool, _ lines: ClosedRange<UInt64>, _ text: String) -> AgentReviewComment {
        AgentReviewComment(checkpoint: Self.checkpointID, path: path, old: old, firstLine: lines.lowerBound, lastLine: lines.upperBound,
                           source: "recorded", text: text)
    }

    func testMoreContextComesFromTheCheckpointAndAnOlderServerSaysItCant() async throws {
        let checkpoint = HistoricalCheckpoint()
        let (controller, rows, parts) = try await window(checkpoint)
        XCTAssertEqual(rows.document?.rows.filter { $0.kind == .context }.count, 6)
        XCTAssertFalse(parts.moreContext.isHidden)
        parts.moreContext.perform()
        try await wait { rows.document?.rows.filter { $0.kind == .context }.count == 39 }
        XCTAssertEqual(checkpoint.requests.compactMap { $0.path == nil ? nil : $0.context }, [25])
        XCTAssertEqual(controller.context, 25)
        parts.moreContext.perform()
        try await wait { checkpoint.requests.last?.context == AgentCheckpointRequest.wholeFile }
        try await wait { parts.moreContext.title == "Whole file" }
        XCTAssertFalse(parts.moreContext.isEnabled)
        XCTAssertEqual(rows.document?.rows.first?.text, " line 1", "Lines come from the recorded file, not the working copy")

        let older = HistoricalCheckpoint()
        older.honorsContext = false
        let (_, olderRows, olderParts) = try await window(older)
        olderParts.moreContext.perform()
        try await wait { olderParts.moreContext.isEnabled == false }
        XCTAssertEqual(olderParts.moreContext.toolTip, "This server can't show more context. Update Tab on it, then restart it.")
        XCTAssertEqual(olderRows.document?.rows.filter { $0.kind == .context }.count, 6)
    }

    func testSavedCommentsAreDrawnOnTheirSideAndRangeInUnifiedAndSplit() async throws {
        let comments = [comment("file.swift", old: true, 20...20, "Why remove this?"),
                        comment("file.swift", old: false, 21...22, "Rename"),
                        comment("gone.swift", old: true, 2...3, "Keep these")]
        let (_, rows, parts) = try await window(HistoricalCheckpoint(), comments: comments)
        let document = try XCTUnwrap(rows.document)
        let oldMarked = rows.markedOld.map { document.rows[$0] }
        let newMarked = rows.markedNew.map { document.rows[$0] }
        XCTAssertEqual(oldMarked.map(\.text), ["-line 20"], "Only the old side's line 20, not the added one")
        XCTAssertEqual(newMarked.map(\.newLineNumber), [21, 22])
        parts.mode.onChange?(1)
        XCTAssertTrue(rows.split)
        XCTAssertEqual(rows.markedOld.map { document.rows[$0].text }, ["-line 20"], "Split view keeps each comment on its side")
        rows.display()
        parts.mode.onChange?(0)
    }

    func testPickingACommentRevealsItsLinesLoadingContextAndOffersToEditIt() async throws {
        let checkpoint = HistoricalCheckpoint()
        let farAway = comment("file.swift", old: false, 30...31, "Outside the usual context")
        let deleted = comment("gone.swift", old: true, 2...3, "Keep these")
        let (controller, rows, parts) = try await window(checkpoint, comments: [farAway, deleted])

        controller.reveal(deleted)
        try await wait { rows.reviewSelection != nil && parts.table.selectedRow == 1 }
        let selection = try XCTUnwrap(rows.reviewSelection)
        XCTAssertTrue(selection.old)
        XCTAssertEqual(selection.lines(in: try XCTUnwrap(rows.document)).map { [$0.first, $0.last] }, [2, 3])
        XCTAssertEqual(parts.addComment.title, "Edit comment", "The revealed comment can be edited from here")

        controller.reveal(farAway)
        try await wait { parts.table.selectedRow == 0 && rows.reviewSelection?.old == false }
        XCTAssertEqual(checkpoint.requests.last?.context, AgentCheckpointRequest.wholeFile, "Lines outside the diff load with the whole file")
        let lines = try XCTUnwrap(rows.reviewSelection.flatMap { $0.lines(in: try XCTUnwrap(rows.document)) })
        XCTAssertEqual([lines.first, lines.last], [30, 31])
        XCTAssertEqual(parts.addComment.title, "Edit comment")
        XCTAssertEqual(lines.source, "line 30\nline 31")

        // A comment whose lines a truncated diff can't show says so.
        let older = HistoricalCheckpoint()
        older.honorsContext = false
        let (olderController, _, olderParts) = try await window(older, comments: [farAway])
        olderController.reveal(farAway)
        try await wait { olderParts.labels().contains("This comment's lines aren't in the diff preview.") }
    }
}

@MainActor
private struct AgentCheckpointDiffWindowParts {
    let moreContext: PillButton
    let addComment: PillButton
    let table: NSTableView
    let mode: SegmentedPill
    let labels: () -> [String]
}
