import AppKit
import TabProtocol
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentRefinementTests: XCTestCase {
    func testHistorySearchIncludesEntriesBeyondFormerProviderLimit() {
        let entries = (0..<200).map { AgentSearchPicker.Entry(id: "\($0)", title: "Conversation \($0)", detail: $0 % 2 == 0 ? "Codex" : "Claude Code") }
        XCTAssertEqual(AgentSearchPicker.matches(entries, query: "conversation 198 codex").map(\.id), ["198"])
        XCTAssertTrue(AgentSearchPicker.matches(entries, query: "missing").isEmpty)
        XCTAssertEqual(AgentSearchPicker.matches(entries, query: "").count, 200)
    }

    func testPromptNavigationUsesStableIdentitiesAndStopsAtBoundaries() {
        XCTAssertEqual(AgentPromptNavigation.destination(ids: ["a", "b", "c"], current: "b", previous: true), "a")
        XCTAssertEqual(AgentPromptNavigation.destination(ids: ["a", "b", "c"], current: "b", previous: false), "c")
        XCTAssertNil(AgentPromptNavigation.destination(ids: ["a", "b"], current: "a", previous: true))
        XCTAssertNil(AgentPromptNavigation.destination(ids: ["a", "b"], current: "b", previous: false))
        XCTAssertEqual(AgentPromptNavigation.destination(ids: ["a", "b"], current: "evicted", previous: true), "b")
    }

    func testPreviousPromptFromAnAnswerDoesNotSkipItsUserMessage() {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))
        var items: [AgentChatItem] = []
        for index in 0..<5 {
            items.append(.init(id: "user-\(index)", kind: .user, text: String(repeating: "Prompt line\n", count: 30)))
            items.append(.init(id: "answer-\(index)", kind: .assistant, text: String(repeating: "Answer paragraph\n\n", count: 30)))
        }
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex, items: items))
        surface.layoutSubtreeIfNeeded()
        surface.scrollToEnd()
        surface.navigatePrompt(previous: true)
        XCTAssertEqual(surface.navigationPromptID, "user-4")
        XCTAssertTrue(surface.transcript.rowStates["user-4"]?.expanded == true)
        surface.navigatePrompt(previous: true)
        XCTAssertEqual(surface.navigationPromptID, "user-3")
        surface.navigatePrompt(previous: false)
        XCTAssertEqual(surface.navigationPromptID, "user-4")
    }

    func testTaskProgressFollowsLatestReportedListAndClearsForAnotherConversation() {
        var model = AgentTaskProgress()
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, status: .working)
        snapshot.items = [.init(id: "todo", kind: .tool, text: "Todo", detail: #"{"steps":[{"id":"1","text":"Test changes","status":"running"}]}"#,
                                workContext: .init(itemType: "todo_list"))]
        model.update(snapshot)
        XCTAssertEqual(model.target, "todo")
        XCTAssertEqual(model.title, "0 of 1 done · Test changes")
        snapshot.status = .failed
        model.update(snapshot)
        XCTAssertTrue(model.title.hasPrefix("Paused"))
        snapshot.items[0].detail = #"{"steps":[{"id":"1","text":"Test changes","status":"completed"}]}"#
        model.update(snapshot)
        XCTAssertNil(model.target)
        snapshot.items = []
        model.update(snapshot)
        XCTAssertEqual(model.title, "")
    }

    func testCrowdedPanelsRemainScrollableAfterResizeAndHiddenFramesReset() throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 360, height: 820))
        let form = AgentQuestionnaire(questions: (0..<5).map { .init(id: "q\($0)", title: "Required question \($0)", options: [.init(label: "Yes"), .init(label: "No")]) })
        let question = AgentChatItem(id: "question", kind: .approval, text: "Questions", isComplete: false, questionnaire: form)
        let prompt = AgentPrompt(text: "Queued", model: nil, effort: nil, provider: .codex, planMode: false)
        surface.render(.init(session: SessionId(), project: ProjectId(), provider: .codex, status: .waiting, items: [question]))
        surface.questions.update(question, enabled: true)
        surface.promptQueue.update((0..<4).map { _ in .init(prompt: prompt) }, paused: true, enabled: true)
        surface.subagents.update([.init(id: "child", toolUseID: "tool", description: "Background work")])
        surface.layoutSubtreeIfNeeded()
        surface.frame.size.height = 400
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(surface.panelScroll.frame.height, 0)
        XCTAssertGreaterThan(try XCTUnwrap(surface.panelScroll.documentView).frame.height, surface.panelScroll.frame.height)
        for panel in [surface.questions, surface.promptQueue, surface.subagents] as [NSView] {
            XCTAssertGreaterThan(panel.frame.height, 0)
            XCTAssertTrue(try XCTUnwrap(surface.panelScroll.documentView).bounds.contains(panel.frame))
        }
        surface.questions.update(nil, enabled: true)
        surface.promptQueue.update([], paused: false, enabled: true)
        surface.subagents.update([])
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.questions.frame, .zero)
        XCTAssertEqual(surface.promptQueue.frame, .zero)
        XCTAssertEqual(surface.subagents.frame, .zero)
        XCTAssertTrue(surface.panelScroll.isHidden)
    }

    func testQueueUpdatesKeepFocusedActionAndDispatchLatestRevision() throws {
        let queue = AgentQueueView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        var prompt = AgentQueuedPrompt(prompt: .init(text: "First", model: nil, effort: nil, provider: .codex, planMode: false))
        queue.update([prompt], paused: false, enabled: true)
        let button = try XCTUnwrap(descendants(queue).compactMap { $0 as? AgentIconButton }.first)
        var edited: AgentQueuedPrompt?
        queue.onEdit = { edited = $0 }
        prompt.text = "Edited elsewhere"
        prompt.revision += 1
        queue.update([prompt], paused: true, enabled: true)
        XCTAssertTrue(descendants(queue).contains { $0 === button })
        button.performClick(nil)
        XCTAssertEqual(edited?.revision, prompt.revision)
        XCTAssertEqual(edited?.text, prompt.text)
    }

    func testQuestionValidationFocusesFirstMissingRequiredAnswerWithoutSubmitting() throws {
        _ = NSApplication.shared
        let form = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
        let window = NSWindow(contentRect: form.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = form
        defer { window.contentView = nil; window.close() }
        form.update(.init(id: "form", kind: .approval, text: "Questions", isComplete: false,
                          questionnaire: .init(questions: [
                            .init(id: "optional", title: "Optional details", required: false),
                            .init(id: "required", title: "Required decision", options: [.init(label: "Required choice")])
                          ])), enabled: true)
        var submitted = false
        form.onAnswer = { _, _, _ in submitted = true }
        form.layoutSubtreeIfNeeded()
        let buttons = descendants(form).compactMap { $0 as? NSButton }
        try XCTUnwrap(buttons.first { $0.title == "Submit answers" }).performClick(nil)
        XCTAssertFalse(submitted)
        XCTAssertTrue(window.firstResponder === buttons.first { $0.title == "Required choice" })
    }

    func testSubagentKeyboardActivationRevealsItsTool() {
        let row = AgentSubagentRow()
        row.show(.init(id: "child", toolUseID: "tool", description: "Testing"))
        var revealed: String?
        row.onPress = { revealed = $0 }
        XCTAssertTrue(row.acceptsFirstResponder)
        row.insertNewline(nil)
        XCTAssertEqual(revealed, "tool")
    }

    /// A label sized from `intrinsicContentSize` came out a few points narrower than its cell
    /// draws, truncating "18k tokens" and "Needs review" beside empty space.
    func testRowLabelsWithRoomAreWideEnoughForTheirCells() throws {
        let row = AgentSubagentRow()
        row.frame = NSRect(x: 0, y: 0, width: 1000, height: 30)
        row.show(.init(id: "child", toolUseID: "tool", description: "Check provider replay fixtures",
                       activity: "Reading fixtures", toolUses: 7, tokens: 18_000))
        row.layoutSubtreeIfNeeded()
        let labels = descendants(row).compactMap { $0 as? NSTextField }.filter { !$0.stringValue.isEmpty }
        XCTAssertEqual(labels.count, 3)
        for label in labels {
            XCTAssertGreaterThanOrEqual(label.frame.width, try XCTUnwrap(label.cell).cellSize.width, label.stringValue)
        }
        let queue = AgentQueueView(frame: NSRect(x: 0, y: 0, width: 900, height: 160))
        let prompt = AgentQueuedPrompt(prompt: .init(text: "Retry", model: nil, effort: nil, provider: .codex, planMode: false,
                                                     attachments: [.init(id: "a", name: "a.txt", mimeType: "text/plain", data: Data("a".utf8))]),
                                       state: .uncertain)
        queue.update([prompt], paused: false, enabled: true)
        queue.layoutSubtreeIfNeeded()
        for text in ["Needs review", "1 attachment"] {
            let label = try XCTUnwrap(descendants(queue).compactMap { $0 as? NSTextField }.first { $0.stringValue == text })
            XCTAssertGreaterThanOrEqual(label.frame.width, try XCTUnwrap(label.cell).cellSize.width, text)
        }
    }

    func testReviewSelectionSeparatesOldAndNewLinesAndRejectsHunkGaps() throws {
        let document = DiffDocument(.init(rows: [
            .init(kind: .deletion, oldLineNumber: 4, text: "-old"),
            .init(kind: .addition, newLineNumber: 4, text: "+new"),
            .init(kind: .hunk, text: "@@"),
            .init(kind: .context, oldLineNumber: 90, newLineNumber: 90, text: " later"),
            .init(kind: .hunk, text: "@@")
        ]))
        let old = try XCTUnwrap(DiffReviewSelection(rows: 0...1, old: true).lines(in: document))
        let new = try XCTUnwrap(DiffReviewSelection(rows: 0...1, old: false).lines(in: document))
        XCTAssertEqual(old.source, "old")
        XCTAssertEqual(new.source, "new")
        XCTAssertEqual(old.first, 4)
        XCTAssertNil(DiffReviewSelection(rows: 0...3, old: false).lines(in: document))
        XCTAssertNil(DiffReviewSelection(rows: 10...12, old: false).lines(in: document))
    }

    func testReviewCommentsSurviveDraftRoundTripAndLegacyDraftsStillLoad() throws {
        let comment = AgentReviewComment(checkpoint: "turn-1", path: "Sources/A.swift", old: true,
                                        firstLine: 5, lastLine: 7, source: "original source", text: "Keep this behavior")
        let draft = AgentSavedDraft(text: NSAttributedString(string: "Existing draft"), attachments: [], submission: nil,
                                   answers: [:], reviewComments: [comment])
        let data = try JSONEncoder().encode(draft)
        let restored = try JSONDecoder().decode(AgentSavedDraft.self, from: data)
        XCTAssertEqual(restored.reviewComments, [comment])
        let prompt = AgentReviewComment.prompt(try XCTUnwrap(restored.reviewComments))
        for part in ["turn-1", "Sources/A.swift", "Side: old", "Lines: 5–7", "original source", "Keep this behavior"] {
            XCTAssertTrue(prompt.contains(part))
        }
        let legacy = Data(#"{"text":"old draft","spans":[],"attachments":[],"answers":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentSavedDraft.self, from: legacy).reviewComments)
    }

    func testDiffHitTestingMapsUnifiedAndSplitToTheCorrectSide() throws {
        let rows = DiffRowsView()
        rows.document = DiffDocument(.init(rows: [
            .init(kind: .deletion, oldLineNumber: 10, text: "-old"),
            .init(kind: .addition, newLineNumber: 12, text: "+new")
        ]))
        rows.fitWidth(600)
        XCTAssertEqual(rows.reviewRow(at: NSPoint(x: 100, y: 1))?.old, true)
        XCTAssertEqual(rows.reviewRow(at: NSPoint(x: 100, y: rows.cell.height + 1))?.old, false)
        rows.split = true
        rows.fitWidth(600)
        XCTAssertEqual(rows.reviewRow(at: NSPoint(x: 10, y: 1))?.index, 0)
        XCTAssertEqual(rows.reviewRow(at: NSPoint(x: rows.bounds.width - 10, y: 1))?.index, 1)
        XCTAssertNil(rows.reviewRow(at: NSPoint(x: 10, y: 1000)))
        rows.reviewSelection = .init(rows: 1...1, old: false)
        rows.moveLeft(nil)
        XCTAssertEqual(rows.reviewSelection, .init(rows: 0...0, old: true))
        rows.moveRight(nil)
        XCTAssertEqual(rows.reviewSelection, .init(rows: 1...1, old: false))
    }

    func testDiffKeyboardRangeCanShrinkAndResetsForAnotherFile() {
        let rows = DiffRowsView()
        rows.reviewEnabled = true
        rows.document = DiffDocument(.init(rows: (1...3).map { .init(kind: .addition, newLineNumber: UInt64($0), text: "+line \($0)") }))
        rows.moveDown(nil)
        rows.moveDown(nil)
        rows.moveDownAndModifySelection(nil)
        XCTAssertEqual(rows.reviewSelection?.rows, 1...2)
        rows.moveUpAndModifySelection(nil)
        XCTAssertEqual(rows.reviewSelection?.rows, 1...1)
        rows.document = DiffDocument(.init(rows: [.init(kind: .addition, newLineNumber: 9, text: "+another file")]))
        rows.moveDown(nil)
        XCTAssertEqual(rows.reviewSelection?.rows, 0...0)
    }

    func testMultilineQueueEditorCancelsWithoutChangingItsSource() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = String(repeating: "A long prompt line\n", count: 50)
        let editor = AgentTextEditorSheet(title: "Edit queued prompt", detail: "Attachments stay with this prompt.", text: text, theme: .shared, showsSettings: true)
        var response: NSApplication.ModalResponse?
        editor.present(in: window) { result, _, _ in response = result }
        XCTAssertTrue(editor.editor.enclosingScrollView?.hasVerticalScroller == true)
        XCTAssertEqual(editor.editor.string, text)
        editor.editor.string += "Unsaved changes"
        editor.close()
        for _ in 0..<100 where response == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(response, .alertSecondButtonReturn)
    }

    func testRenderRefinementPanels() async throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR to render refinements") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        func capture(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let suffix = dark ? "dark" : "light"
            let picker = AgentSearchPicker(title: "Continue conversation", placeholder: "Search titles or providers…", theme: theme)
            picker.update((0..<60).map { .init(id: "\($0)", title: "Review native agent pane interactions \($0)", detail: "Codex · 2 hours ago") }, note: "Showing the newest 200 conversations. Older results were omitted by the server.")
            try capture(try XCTUnwrap(picker.window?.contentView), "history-" + suffix)
            picker.close()
            let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
            let window = NSWindow(contentRect: surface.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = surface
            defer { window.contentView = nil; window.close() }
            surface.theme = theme; surface.themeDidChange()
            var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex, status: .working)
            snapshot.items = [.init(id: "todo", kind: .tool, text: "Todo", detail: #"{"steps":[{"id":"1","text":"Verify native keyboard interactions","status":"running"}]}"#,
                                    workContext: .init(itemType: "todo_list"))]
            surface.render(snapshot)
            surface.composer.string = "Keep this draft while stopping"
            surface.promptQueue.update((0..<4).map { _ in .init(prompt: .init(text: "Another queued request", model: nil, effort: nil, provider: .codex, planMode: false)) }, paused: true, enabled: true)
            surface.subagents.update([.init(id: "child", toolUseID: "tool", description: "Reviewing keyboard access", activity: "Running checks")])
            surface.refreshComposer()
            try capture(surface, "crowded-progress-" + suffix)
            let diff = AgentCheckpointDiffWindow(session: SessionId(), checkpoint: "recorded-turn", path: "Sources/Example.swift", theme: theme) { request in
                .init(checkpoint: request.checkpoint, files: [.init(path: "Sources/Example.swift", additions: 1, deletions: 1)], totalFiles: 1,
                      path: request.path, diff: request.path.map { _ in .init(rows: [
                        .init(kind: .deletion, oldLineNumber: 4, text: "-return oldValue"),
                        .init(kind: .addition, newLineNumber: 4, text: "+return newValue")], additions: 1, deletions: 1) })
            }
            diff.onReviewChange = { _ in }
            diff.reviewComments = [.init(checkpoint: "recorded-turn", path: "Sources/Example.swift", old: false, firstLine: 4, lastLine: 4, source: "return newValue", text: "Preserve empty input behavior")]
            let content = try XCTUnwrap(diff.window?.contentView)
            let rows = try XCTUnwrap(descendants(content).compactMap { $0 as? DiffRowsView }.first)
            for _ in 0..<100 where rows.document == nil { try await Task.sleep(for: .milliseconds(10)) }
            rows.reviewSelection = .init(rows: 1...1, old: false)
            diff.window?.setContentSize(NSSize(width: 680, height: 400))
            try capture(content, "diff-review-" + suffix)
            diff.close()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
