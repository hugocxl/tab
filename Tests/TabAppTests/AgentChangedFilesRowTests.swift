import AppKit
import TabProtocol
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentChangedFilesRowTests: XCTestCase {
    private func checkpoint() -> AgentTurnCheckpoint {
        .init(id: UUID().uuidString, files: [.init(path: "Sources/TabApp/Sidebar/SidebarRows.swift", additions: 2, deletions: 2)],
              totalFiles: 1, additions: 2, deletions: 2)
    }
    func testDirectoryExpansionSurvivesRecreationAndFileOpensHistoricalDiff() throws {
        _ = NSApplication.shared
        let row = AgentChangedFilesRow(frame: .zero)
        let checkpoint = checkpoint()
        row.checkpoint = checkpoint
        let folder = try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first { $0.toolTip == "Sources/TabApp/Sidebar" })
        let collapsed = row.preferredHeight(for: 700)
        folder.perform()
        XCTAssertGreaterThan(row.preferredHeight(for: 700), collapsed)
        let restored = AgentChangedFilesRow(frame: .zero)
        restored.checkpoint = checkpoint
        restored.restoreState(row.captureState())
        XCTAssertEqual(restored.preferredHeight(for: 700), row.preferredHeight(for: 700))
        var opened: (String, String?)?
        restored.onOpenCheckpoint = { opened = ($0, $1) }
        let file = try XCTUnwrap(restored.subviews.compactMap { $0 as? PillButton }.first { $0.toolTip == checkpoint.files[0].path })
        file.perform()
        XCTAssertEqual(opened?.0, checkpoint.id)
        XCTAssertEqual(opened?.1, checkpoint.files[0].path)
    }

    func testCardFollowsFinalAnswerOutsideCompletedWorkAndRendersReferenceFixture() throws {
        _ = NSApplication.shared
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 720))
        surface.disposeConversation() // This fixture exercises the native fallback.
        let items = [
            AgentChatItem(id: "user", kind: .user, text: "Reduce the spacing between the server name and icon."),
            AgentChatItem(id: "progress", kind: .assistant, text: "I’ll find the multi-server header and tighten the spacing."),
            AgentChatItem(id: "tool", kind: .tool, text: "Read SidebarRows.swift"),
            AgentChatItem(id: "answer", kind: .assistant, text: "Reduced the spacing between the server icon and name.\n\nValidation completed successfully.")
        ]
        let turn = AgentChatTurn(userItemID: "user", startedAt: Date(timeIntervalSince1970: 100),
                                completedAt: Date(timeIntervalSince1970: 223), status: .idle, checkpoint: checkpoint())
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex, turns: [turn], items: items))
        surface.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(surface.transcriptScroll.documentView as? AgentTranscriptDocument)
        let answer = try XCTUnwrap(document.subviews.compactMap { $0 as? AgentMessageRow }.first { row in
            row.subviews.contains { $0 is AgentChangedFilesRow && !$0.isHidden }
        })
        let card = try XCTUnwrap(answer.subviews.compactMap { $0 as? AgentChangedFilesRow }.first)
        let response = try XCTUnwrap(answer.subviews.compactMap { $0 as? AgentResponseView }.first)
        XCTAssertEqual(card.frame.minY - response.frame.maxY, 16)
        XCTAssertTrue(document.subviews.compactMap { $0 as? AgentChangedFilesRow }.isEmpty,
                      "The card belongs inside the answer before its footer")
        if let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            for dark in [false, true] {
                surface.theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
                surface.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                surface.themeDidChange()
                for width in [900, 360] {
                    surface.frame.size.width = CGFloat(width)
                    surface.needsLayout = true
                    surface.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                    surface.cacheDisplay(in: surface.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "/agent-turn-changes-\(dark ? "dark" : "light")-\(width).png"))
                }
            }
        }
    }
}
