import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentTimelineTests: XCTestCase {
    func testAllRevealedRowsShareAssistantWidthWhenResizing() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "user", kind: .user, text: "Inspect"),
                     .init(id: "progress", kind: .assistant, text: "Checking"),
                     .init(id: "tool", kind: .tool, text: "Read file", detail: String(repeating: "output ", count: 200)),
                     .init(id: "answer", kind: .assistant, text: "Done"),
                     .init(id: "approval", kind: .approval, text: "Allow command?", isComplete: false)]
        let turn = AgentChatTurn(userItemID: "user", startedAt: .distantPast, completedAt: Date(), status: .idle)
        document.update(items, omittedCount: 0, turns: [turn])
        var states = document.rowStates
        states["work:user"] = AgentTimelineRowState(expanded: true)
        states["activity:tool"] = AgentTimelineRowState(expanded: true)
        document.rowStates = states
        document.update(items, omittedCount: 0, turns: [turn])
        for viewport in [CGFloat(900), 360, 700] {
            document.reflow(viewportWidth: viewport)
            document.updateViewport(NSRect(x: 0, y: 0, width: viewport, height: 10_000), followingEnd: false)
            let user = try XCTUnwrap(document.frameForEntry("user"))
            let expected = AgentMessageRow.responseWidth(user.width)
            for id in ["progress", "activity:tool", "approval", "answer", "work:user"] {
                let frame = try XCTUnwrap(document.frameForEntry(id), id)
                XCTAssertEqual(frame.width, expected, id)
                XCTAssertEqual(frame.minX, user.minX, id)
            }
        }
    }

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
        XCTAssertEqual(try XCTUnwrap(document.frameForEntry("activity:first")).height, 30)
        let turn = AgentChatTurn(userItemID: "user", startedAt: .distantPast, completedAt: Date(), status: .idle)
        document.update(items, omittedCount: 0, turns: [turn])
        var states = document.rowStates
        states["work:user"] = AgentTimelineRowState(expanded: true)
        document.rowStates = states
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        let first = try XCTUnwrap(document.frameForEntry("activity:first"))
        let second = try XCTUnwrap(document.frameForEntry("activity:second"))
        XCTAssertEqual(first.height, 30)
        XCTAssertEqual(second.height, 30)
        XCTAssertEqual(second.minY, first.maxY + 4)
        document.update(items, omittedCount: 0)
        document.reflow(viewportWidth: 700)
        XCTAssertEqual(try XCTUnwrap(document.frameForEntry("activity:first")).height, 30)
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
        XCTAssertTrue(disclosure.title.contains("1 tool call, 1 message"))
        XCTAssertEqual(group.frame.height, 30)
        let answer = try XCTUnwrap(document.subviews.compactMap { $0 as? AgentMessageRow }.first { $0.assistantItem?.id == "answer" })
        XCTAssertTrue(answer.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("1m, 5s · ") },
                      "The answer's footer says how long the turn took")
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

    func testWorkingTimerFollowsTheTurnAndDisappearsOnCompletion() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "user", kind: .user, text: "Help"),
                     AgentChatItem(id: "reply", kind: .assistant, text: "Checking", isComplete: false)]
        var turn = AgentChatTurn(userItemID: "user", startedAt: Date().addingTimeInterval(-14))
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        let working = try XCTUnwrap(document.frameForEntry("working:user"))
        let reply = try XCTUnwrap(document.frameForEntry("reply"))
        XCTAssertGreaterThan(working.minY, reply.maxY)
        turn.completedAt = Date()
        turn.status = .idle
        document.update(items, omittedCount: 0, turns: [turn])
        XCTAssertNil(document.frameForEntry("working:user"))
    }

    func testWorkingTimerStaysBelowMessagesSentDuringTheTurn() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "user", kind: .user, text: "Fix the strip"),
                     AgentChatItem(id: "tool", kind: .tool, text: "Bash"),
                     AgentChatItem(id: "steer", kind: .user, text: "in history too."),
                     AgentChatItem(id: "reply", kind: .assistant, text: "Checking", isComplete: false),
                     AgentChatItem(id: "read", kind: .tool, text: "Read")]
        let turn = AgentChatTurn(userItemID: "user", startedAt: Date().addingTimeInterval(-33))
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        let working = try XCTUnwrap(document.frameForEntry("working:user"))
        for id in ["steer", "reply", "activity:read"] {
            XCTAssertGreaterThan(working.minY, try XCTUnwrap(document.frameForEntry(id)).maxY, id)
        }
    }

    func testWorkingLineSaysWhatTheAgentIsDoingInWholeSeconds() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        document.workspaceRoot = "/repo"
        var items = [AgentChatItem(id: "user", kind: .user, text: "Build it"),
                     AgentChatItem(id: "read", kind: .tool, text: "Read", isComplete: true,
                                   tool: .init(name: "Read", category: .read, input: #"{"file_path":"/repo/a.swift"}"#, status: .completed)),
                     AgentChatItem(id: "bash", kind: .tool, text: "Bash", isComplete: false,
                                   tool: .init(name: "Bash", category: .command, input: #"{"command":"swift build"}"#, status: .running))]
        let turn = AgentChatTurn(userItemID: "user", startedAt: Date().addingTimeInterval(-48.7))
        func line() throws -> String {
            document.update(items, omittedCount: 0, turns: [turn])
            document.reflow(viewportWidth: 700)
            let row = try XCTUnwrap(document.subviews.first { $0 is AgentWorkingRow })
            return try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextField }.first).stringValue
        }
        XCTAssertTrue(try line().hasPrefix("4"), "Whole seconds, no tenths")
        XCTAssertFalse(try line().contains("."))
        func activity() throws -> String? {
            let text = try line()
            return text.range(of: " · ").map { String(text[$0.upperBound...]) }
        }
        XCTAssertEqual(try activity(), "Bash · swift build")
        items.append(.init(id: "think", kind: .tool, text: "Thinking", detail: "…", isComplete: false,
                           workContext: .init(itemType: "reasoning")))
        XCTAssertEqual(try activity(), "Thinking")
        items.append(.init(id: "agent", kind: .tool, text: "Task", isComplete: false,
                           tool: .init(name: "Task", category: .subagent, input: #"{"description":"Audit fixtures","prompt":"…"}"#, status: .running)))
        XCTAssertEqual(try activity(), "Agent · Audit fixtures")
        items = items.map { var item = $0; item.isComplete = true; return item }
        XCTAssertNil(try activity(), "Streaming prose or nothing running shows only the time")
        XCTAssertEqual(AgentTurnTime.seconds(185.9), "3m 05s")
        XCTAssertEqual(AgentTurnTime.seconds(3785), "1h 03m 05s")
    }

    /// Finishing a turn folded the rows being read; an open tool row now keeps its group open.
    func testFinishingATurnKeepsWorkInUseOpen() throws {
        func fold(expandTool: Bool) throws -> AgentTranscriptDocument {
            let document = AgentTranscriptDocument(frame: .zero)
            let items = [AgentChatItem(id: "user", kind: .user, text: "Fix it"),
                         AgentChatItem(id: "tool", kind: .tool, text: "Bash", detail: "output",
                                       tool: .init(name: "Bash", category: .command, input: "ls", output: "a\nb", status: .completed)),
                         AgentChatItem(id: "answer", kind: .assistant, text: "Done.")]
            var turn = AgentChatTurn(userItemID: "user", startedAt: Date(timeIntervalSince1970: 100))
            document.update(items, omittedCount: 0, turns: [turn])
            document.reflow(viewportWidth: 700)
            if expandTool { document.rowStates = ["activity:tool": AgentTimelineRowState(toolExpandedIDs: ["tool"])] }
            turn.completedAt = Date(timeIntervalSince1970: 160)
            turn.status = .idle
            document.update(items, omittedCount: 0, turns: [turn])
            document.reflow(viewportWidth: 700)
            return document
        }
        let open = try fold(expandTool: true)
        XCTAssertNotNil(open.frameForEntry("work:user"))
        XCTAssertNotNil(open.frameForEntry("activity:tool"), "The open tool row stays visible under its summary")
        let folded = try fold(expandTool: false)
        XCTAssertNotNil(folded.frameForEntry("work:user"))
        XCTAssertNil(folded.frameForEntry("activity:tool"), "Untouched work folds as before")
    }

    /// Each TodoWrite added a full card and a raw row; a list updated nine times showed nine cards.
    func testATurnShowsItsNewestTodoCardAndOneLinePerEarlierUpdate() {
        let document = AgentTranscriptDocument(frame: .zero)
        func todo(_ n: Int) -> [AgentChatItem] {
            [AgentChatItem(id: "toolu_\(n)", kind: .tool, text: "TodoWrite", tool: .init(name: "TodoWrite", status: .completed)),
             AgentChatItem(id: "todo_list:toolu_\(n)", kind: .tool, text: "Updated plan",
                           detail: #"{"steps":[{"id":"a","text":"Step","status":"running"}]}"#, workContext: .init(itemType: "todo_list"))]
        }
        let items = [AgentChatItem(id: "u", kind: .user, text: "Plan it")] + todo(1) + todo(2) + todo(3)
        document.update(items, omittedCount: 0, turns: [AgentChatTurn(userItemID: "u", startedAt: Date())])
        document.reflow(viewportWidth: 700)
        XCTAssertTrue(document.mountedRow("activity:todo_list:toolu_3") is AgentCardRow, "The newest list is a card")
        for n in 1...2 {
            XCTAssertTrue(document.mountedRow("activity:todo_list:toolu_\(n)") is AgentActivityRow, "Earlier updates are one line")
        }
        for n in 1...3 { XCTAssertNil(document.frameForEntry("activity:toolu_\(n)"), "The raw TodoWrite row is hidden") }
    }

    func testANewestProposedPlanStaysVisibleBelowItsFoldedWork() {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "u", kind: .user, text: "Plan"),
                     AgentChatItem(id: "read", kind: .tool, text: "Read", tool: .init(name: "Read", category: .read, status: .completed)),
                     AgentChatItem(id: "proposed_plan:p", kind: .tool, text: "Proposed plan", detail: "1. Do it",
                                   workContext: .init(itemType: "proposed_plan")),
                     AgentChatItem(id: "a", kind: .assistant, text: "Here is the plan.")]
        document.update(items, omittedCount: 0, turns: [AgentChatTurn(userItemID: "u", startedAt: Date(timeIntervalSince1970: 1),
                                                                     completedAt: Date(timeIntervalSince1970: 9), status: .idle)])
        document.reflow(viewportWidth: 700)
        XCTAssertNotNil(document.frameForEntry("work:u"))
        XCTAssertNil(document.frameForEntry("activity:read"), "Other work folds")
        XCTAssertNotNil(document.frameForEntry("activity:proposed_plan:p"), "The plan stays visible")
    }

    func testDroppedItemsAreNamedHonestlyWithoutALoadButton() {
        let document = AgentTranscriptDocument(frame: .zero)
        document.update([AgentChatItem(id: "u", kind: .user, text: "Hi")], omittedCount: 3)
        document.reflow(viewportWidth: 700)
        let labels = document.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        XCTAssertTrue(labels.contains("3 earlier items aren't shown, to keep this conversation within its size limit"), "\(labels)")
        XCTAssertFalse(labels.contains { $0.contains("saved") })
        XCTAssertFalse(document.subviews.contains { ($0 as? NSButton)?.title == "Show earlier messages" && !$0.isHidden },
                       "Nothing can load them, so no button offers to")
    }

    func testWorkingLineNamesRetriesAndRateLimitsFirst() {
        let soon = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? Date()
        XCTAssertEqual(AgentWorkingRow.describe(.init(kind: .retrying, attempt: 2, message: "Overloaded"), otherwise: "Bash · ls"),
                       "Retrying (attempt 2) · Overloaded")
        XCTAssertTrue(AgentWorkingRow.describe(.init(kind: .rateLimited, resumesAt: soon), otherwise: nil)?.hasPrefix("Rate limited · resumes at ") == true)
        XCTAssertEqual(AgentWorkingRow.describe(.init(kind: .rateLimitWarning, message: "98% of the usage limit used"), otherwise: "Bash · ls"),
                       "Bash · ls", "A warning gives way to what is running")
        XCTAssertEqual(AgentWorkingRow.describe(nil, otherwise: "Thinking"), "Thinking")
        XCTAssertEqual(AgentWorkingRow.describe(.init(kind: .init(rawValue: "future")), otherwise: "Thinking"), "Thinking")
    }

    func testSecondTickerRunsOnlyWhileSomethingSubscribes() {
        let ticker = AgentSecondTicker()
        let owner = NSObject()
        XCTAssertFalse(ticker.isRunning)
        ticker.subscribe(owner) {}
        XCTAssertTrue(ticker.isRunning)
        ticker.unsubscribe(owner)
        XCTAssertFalse(ticker.isRunning)
    }

    func testOnlyTheNewestRunningTurnShowsATimer() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "old", kind: .user, text: "First"),
                     AgentChatItem(id: "new", kind: .user, text: "Second")]
        document.update(items, omittedCount: 0, turns: [AgentChatTurn(userItemID: "old", startedAt: Date()),
                                                         AgentChatTurn(userItemID: "new", startedAt: Date())])
        document.reflow(viewportWidth: 700)
        XCTAssertNil(document.frameForEntry("working:old"))
        XCTAssertNotNil(document.frameForEntry("working:new"))
    }

    func testCopyActionWaitsForTurnCompletionAfterProgressMessageEnds() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "user", kind: .user, text: "Review this"),
                     AgentChatItem(id: "progress", kind: .assistant, text: "Checking the files.", isComplete: true),
                     AgentChatItem(id: "tool", kind: .tool, text: "Read file")]
        var turn = AgentChatTurn(userItemID: "user", startedAt: Date())
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        document.updateViewport(NSRect(x: 0, y: 0, width: 700, height: 700), followingEnd: false)
        let progress = try XCTUnwrap(document.subviews.compactMap { $0 as? AgentMessageRow }.first {
            $0.subviews.compactMap { $0 as? PillButton }.contains { $0.toolTip == "Copy response as Markdown" }
        })
        let copy = try XCTUnwrap(progress.subviews.compactMap { $0 as? PillButton }.first {
            $0.toolTip == "Copy response as Markdown"
        })
        XCTAssertTrue(copy.isHidden)
        turn.completedAt = Date()
        turn.status = .idle
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        document.updateViewport(NSRect(x: 0, y: 0, width: 700, height: 700), followingEnd: false)
        XCTAssertFalse(copy.isHidden)
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

    func testAnswerActionsShowAndKeyboardFocusRevealsMessageActions() throws {
        _ = NSApplication.shared
        let answer = AgentMessageRow(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        answer.update([AgentChatItem(id: "reply", kind: .assistant, text: "Finished.")])
        let answerCopy = try XCTUnwrap(answer.subviews.compactMap { $0 as? PillButton }.first { $0.toolTip == "Copy response as Markdown" })
        XCTAssertEqual(answerCopy.alphaValue, 1, "An answer's footer shows without hover")
        let row = AgentMessageRow(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        row.update([AgentChatItem(id: "request", kind: .user, text: "Please finish.")])
        _ = row.preferredHeight(for: 600)
        row.layoutRow(width: 600)
        let copy = try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first { $0.toolTip == "Copy message" })
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
