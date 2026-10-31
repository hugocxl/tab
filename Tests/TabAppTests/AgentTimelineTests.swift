import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentTimelineTests: XCTestCase {
    func testExpandedHistoryUsesMainTimelineAndRetainsStateAcrossFolding() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        var items = [AgentChatItem(id: "user", kind: .user, text: "Review the project")]
        for index in 0..<200 {
            items.append(AgentChatItem(id: "progress-\(index)", kind: .assistant, text: "Reviewing section \(index)"))
            items.append(AgentChatItem(id: "tool-\(index)", kind: .tool, text: "Read file \(index)", detail: "Contents"))
        }
        items.append(AgentChatItem(id: "answer", kind: .assistant, text: "Review complete."))
        let turn = AgentChatTurn(userItemID: "user", startedAt: .distantPast, completedAt: Date(), status: .idle)
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        let foldedHeight = document.frame.height
        let fold = try XCTUnwrap(document.subviews.compactMap { $0 as? AgentCompletedWorkRow }.first)
        XCTAssertFalse(fold.subviews.contains { $0 is NSScrollView })
        let button = try XCTUnwrap(fold.subviews.compactMap { $0 as? PillButton }.first)
        button.perform()
        XCTAssertEqual(document.entryCount, 403)
        XCTAssertGreaterThan(document.frame.height, foldedHeight + 4_000)
        XCTAssertNotNil(document.frameForEntry("progress-199"))
        XCTAssertLessThan(document.mountedRowCount, 60)
        var states = document.rowStates
        states["progress-199"] = AgentTimelineRowState(expanded: true)
        document.rowStates = states
        button.perform()
        XCTAssertEqual(document.entryCount, 3)
        XCTAssertNil(document.frameForEntry("progress-199"))
        XCTAssertEqual(document.rowStates["progress-199"]?.expanded, true)
        button.perform()
        XCTAssertEqual(document.entryCount, 403)
        document.update(items, omittedCount: 0, turns: [turn])
        XCTAssertEqual(document.entryCount, 403, "A server refresh must preserve the expanded projection")
        let end = try XCTUnwrap(document.frameForEntry("progress-199"))
        document.updateViewport(NSRect(x: 0, y: end.minY, width: 700, height: 600), followingEnd: false)
        XCTAssertLessThan(document.mountedRowCount, 60)
        XCTAssertTrue(textViews(document).contains { $0.string == "Reviewing section 199" })
    }

    func testGroupedToolProjectionRemeasuresReusedRowsAndKeepsTightSpacing() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "user", kind: .user, text: "Inspect"),
                     .init(id: "first", kind: .tool, text: "Read one", detail: "One"),
                     .init(id: "second", kind: .tool, text: "Read two", detail: "Two"),
                     .init(id: "answer", kind: .assistant, text: "Done")]
        document.update(items, omittedCount: 0)
        document.reflow(viewportWidth: 700)
        XCTAssertEqual(try XCTUnwrap(document.frameForEntry("activity:first")).height, 28)
        let turn = AgentChatTurn(userItemID: "user", startedAt: .distantPast, completedAt: Date(), status: .idle)
        document.update(items, omittedCount: 0, turns: [turn])
        var states = document.rowStates
        states["work:user"] = AgentTimelineRowState(expanded: true)
        document.rowStates = states
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        let first = try XCTUnwrap(document.frameForEntry("activity:first"))
        let second = try XCTUnwrap(document.frameForEntry("activity:second"))
        XCTAssertEqual(first.height, 24)
        XCTAssertEqual(second.height, 24)
        XCTAssertEqual(second.minY, first.maxY)
        document.update(items, omittedCount: 0)
        document.reflow(viewportWidth: 700)
        XCTAssertEqual(try XCTUnwrap(document.frameForEntry("activity:first")).height, 28)
    }

    func testCompletedWorkDisclosureSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render work disclosure")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let root = ThemedView(frame: NSRect(x: 0, y: 0, width: 500, height: 70))
        let row = AgentCompletedWorkRow(frame: NSRect(x: 16, y: 16, width: 468, height: 37))
        row.turn = AgentChatTurn(userItemID: "user", startedAt: Date(timeIntervalSince1970: 0),
                                completedAt: Date(timeIntervalSince1970: 123), status: .idle)
        root.addSubview(row)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            root.layer?.backgroundColor = theme.bg.cgColor
            row.theme = theme
            row.update([])
            row.layoutRow(width: 468)
            let button = try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first)
            XCTAssertLessThan(button.frame.width, 180, "The disclosure must not capture the whole conversation lane")
            XCTAssertFalse(button.title.contains("›"))
            root.displayIfNeeded()
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: output).appendingPathComponent("work-disclosure-\(dark ? "dark" : "light").png"))
        }
    }

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
        XCTAssertEqual(group.frame.height, 37)
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
        surface.disposeConversation() // This fixture exercises the native fallback.
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

    func testWorkingTimerPrecedesCommentaryAndDisappearsOnCompletion() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "user", kind: .user, text: "Help"),
                     AgentChatItem(id: "reply", kind: .assistant, text: "Checking", isComplete: false)]
        var turn = AgentChatTurn(userItemID: "user", startedAt: Date().addingTimeInterval(-14))
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        let working = try XCTUnwrap(document.frameForEntry("working:user"))
        let reply = try XCTUnwrap(document.frameForEntry("reply"))
        XCTAssertLessThan(working.maxY, reply.minY)
        turn.completedAt = Date()
        turn.status = .idle
        document.update(items, omittedCount: 0, turns: [turn])
        XCTAssertNil(document.frameForEntry("working:user"))
    }

    func testCollapsedUserMessageRetainsFullMarkdownAndCopySource() throws {
        let row = AgentMessageRow(frame: .zero)
        let text = String(repeating: "A paragraph with **emphasis**. ", count: 40)
        row.update([AgentChatItem(id: "user", kind: .user, text: text)])
        row.frame = NSRect(x: 0, y: 0, width: 700, height: row.preferredHeight(for: 700))
        row.layoutRow(width: 700)
        let response = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentResponseView }.first)
        let body = try XCTUnwrap(response.subviews.flatMap(\.subviews).compactMap { $0 as? AgentRichTextView }.first)
        XCTAssertEqual(body.string.components(separatedBy: "emphasis").count - 1, 40)
        XCTAssertLessThanOrEqual(response.frame.height, 176)
        XCTAssertNotNil(response.layer?.mask, "Collapsed text fades without truncating Markdown")
        let expand = try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first { $0.title == "Show full message" })
        expand.onPress?()
        let expandedHeight = row.preferredHeight(for: 700)
        XCTAssertGreaterThan(expandedHeight, row.frame.height)
    }

    func testKeyboardFocusRevealsResponseActionsWithoutMouseHover() throws {
        _ = NSApplication.shared
        let row = AgentMessageRow(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        row.update([AgentChatItem(id: "reply", kind: .assistant, text: "Finished.")])
        _ = row.preferredHeight(for: 600)
        row.layoutRow(width: 600)
        let copy = try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first { $0.toolTip == "Copy response as Markdown" })
        let window = NSWindow(contentRect: row.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = row
        defer { window.contentView = nil; window.orderOut(nil) }
        XCTAssertEqual(copy.alphaValue, 0)
        XCTAssertTrue(window.makeFirstResponder(copy))
        XCTAssertEqual(copy.alphaValue, 1)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(copy.alphaValue, 0)
    }

    private func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
}
