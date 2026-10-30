import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentTimelineTests: XCTestCase {
    func testCompletedWorkFoldsCommentaryAndToolsButKeepsAnswerVisible() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [
            AgentChatItem(id: "user", kind: .user, text: "Find the bug"),
            AgentChatItem(id: "progress", kind: .assistant, text: "Inspecting the source"),
            AgentChatItem(id: "tool", kind: .tool, text: "Read file", detail: "source.swift"),
            AgentChatItem(id: "answer", kind: .assistant, text: "The bug is fixed.")
        ]
        let turn = AgentChatTurn(userItemID: "user", startedAt: Date(timeIntervalSince1970: 100),
                                 completedAt: Date(timeIntervalSince1970: 165), status: .idle)
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        let group = try XCTUnwrap(document.subviews.first { $0 is AgentCompletedWorkRow })
        let disclosure = try XCTUnwrap(group.subviews.compactMap { $0 as? PillButton }.first)
        XCTAssertTrue(disclosure.title.contains("1m 5s"))
        XCTAssertEqual(group.frame.height, 24)
        XCTAssertTrue(textViews(document).contains { $0.string == "The bug is fixed." && !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertFalse(textViews(document).contains { $0.string == "Inspecting the source" && !$0.isHiddenOrHasHiddenAncestor })
        disclosure.onPress?()
        document.reflow(viewportWidth: 700)
        XCTAssertGreaterThan(group.frame.height, 24)
        XCTAssertTrue(textViews(document).contains { $0.string == "Inspecting the source" && !$0.isHiddenOrHasHiddenAncestor })
        document.update(items, omittedCount: 0, turns: [turn])
        XCTAssertTrue(document.subviews.contains { $0 === group })
        XCTAssertGreaterThan(group.frame.height, 24, "Snapshot refresh preserves disclosure state")
    }

    func testPendingApprovalCannotDisappearInsideCompletedWork() {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [
            AgentChatItem(id: "user", kind: .user, text: "Run a command"),
            AgentChatItem(id: "tool", kind: .tool, text: "Command"),
            AgentChatItem(id: "approval", kind: .approval, text: "Allow command?", isComplete: false),
            AgentChatItem(id: "answer", kind: .assistant, text: "Waiting")
        ]
        document.update(items, omittedCount: 0, turns: [
            AgentChatTurn(userItemID: "user", startedAt: Date(timeIntervalSince1970: 100),
                          completedAt: Date(timeIntervalSince1970: 101), status: .idle)
        ])
        document.reflow(viewportWidth: 700)
        document.updateViewport(NSRect(x: 0, y: 0, width: 700, height: 700), followingEnd: false)
        XCTAssertFalse(document.subviews.contains { $0 is AgentCompletedWorkRow })
        XCTAssertTrue(textViews(document).contains { $0.string == "Allow command?" && !$0.isHiddenOrHasHiddenAncestor })
    }

    func testPendingApprovalSurvivesVisibleTranscriptWindow() throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        let approval = AgentChatItem(id: "pending", kind: .approval, text: "Allow pending command?", isComplete: false)
        let later = (0..<250).map { AgentChatItem(id: "tool-\($0)", kind: .tool, text: "Read source \($0)") }
        surface.render(AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude,
                                        status: .waiting, items: [approval] + later))
        let document = try XCTUnwrap(surface.transcriptScroll.documentView as? AgentTranscriptDocument)
        let frame = try XCTUnwrap(document.frameForEntry(approval.id))
        document.updateViewport(NSRect(x: 0, y: frame.minY, width: 700, height: 600), followingEnd: false)
        XCTAssertTrue(textViews(surface).contains { $0.string == approval.text && !$0.isHiddenOrHasHiddenAncestor })
    }

    func testResolvedApprovalsDoNotBecomeConversationMessages() {
        let document = AgentTranscriptDocument(frame: .zero)
        document.update([
            AgentChatItem(id: "search", kind: .tool, text: "WebSearch"),
            AgentChatItem(id: "auto", kind: .approval, text: "Automatically approved", isComplete: true),
            AgentChatItem(id: "approved", kind: .approval, text: "Approved", isComplete: true),
            AgentChatItem(id: "pending", kind: .approval, text: "Allow this command?", isComplete: false),
            AgentChatItem(id: "answer", kind: .assistant, text: "The search result.")
        ], omittedCount: 0)
        document.reflow(viewportWidth: 700)
        document.updateViewport(NSRect(x: 0, y: 0, width: 700, height: 700), followingEnd: false)
        XCTAssertNil(document.frameForEntry("auto"))
        XCTAssertNil(document.frameForEntry("approved"))
        XCTAssertNotNil(document.frameForEntry("pending"))
        XCTAssertTrue(textViews(document).contains { $0.string == "The search result." })
        XCTAssertFalse(textViews(document).contains { $0.string == "Automatically approved" || $0.string == "Approved" })
    }

    private func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
}
