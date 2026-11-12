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
}
