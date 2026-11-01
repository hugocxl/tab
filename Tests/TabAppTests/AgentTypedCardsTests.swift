import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentTypedCardsTests: XCTestCase {
    // MARK: Fixtures

    private let turn = AgentChatTurn(userItemID: "user", startedAt: Date(timeIntervalSince1970: 100),
                                     completedAt: Date(timeIntervalSince1970: 130), status: .idle)

    private func plan(_ markdown: String, id: String = "plan", complete: Bool = true, status: String? = "active",
                      source: String = "completed") -> AgentChatItem {
        AgentChatItem(id: id, kind: .tool, text: "Proposed plan", detail: markdown, isComplete: complete,
                      workContext: .init(itemType: "proposed_plan", sourceStatus: source, planStatus: status))
    }

    private func todo(_ steps: [[String: Any]], explanation: String? = nil, id: String = "todo") -> AgentChatItem {
        var object: [String: Any] = ["steps": steps]
        if let explanation { object["explanation"] = explanation }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return AgentChatItem(id: id, kind: .tool, text: "Updated plan", detail: String(decoding: data, as: UTF8.self),
                             workContext: .init(itemType: "todo_list", sourceStatus: "completed", planStatus: "active"))
    }

    private func step(_ id: String, _ text: String, _ status: String) -> [String: Any] { ["id": id, "text": text, "status": status] }

    private func compaction(before: Int? = nil, after: Int? = nil, summary: String? = nil) -> AgentChatItem {
        AgentChatItem(id: "compact", kind: .tool, text: "Context compacted", detail: summary,
                      workContext: .init(itemType: "compaction", sourceStatus: "completed", beforeTokenCount: before, afterTokenCount: after))
    }

    private func failure(_ text: String) -> AgentChatItem {
        AgentChatItem(id: "failure", kind: .notice, text: text, workContext: .init(itemType: "error", sourceStatus: "failed"))
    }

    private func mounted<T: NSView>(_ type: T.Type, in document: AgentTranscriptDocument) -> [T] {
        document.subviews.compactMap { $0 as? T }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func place(_ row: AgentTimelineRow, width: CGFloat = 600) {
        row.frame = NSRect(x: 0, y: 0, width: width, height: row.preferredHeight(for: width))
        row.layoutRow(width: width)
    }

    private func fixedDate() throws -> Date {
        try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 14, minute: 5)))
    }

    private func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("tab-typed-cards-" + UUID().uuidString))
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        return pasteboard
    }

    // MARK: Classification and todo validation

    func testClassificationFollowsTheWebProjectionOrder() {
        XCTAssertEqual(AgentTypedCardKind.classify(failure("Boom")), .error)
        XCTAssertEqual(AgentTypedCardKind.classify(plan("# Plan")), .plan)
        XCTAssertEqual(AgentTypedCardKind.classify(todo([step("1", "Do it", "pending")])), .todo)
        XCTAssertEqual(AgentTypedCardKind.classify(compaction()), .compaction)
        XCTAssertEqual(AgentTypedCardKind.classify(AgentChatItem(kind: .notice, text: "Agent interrupted.")), .notice)
        XCTAssertNil(AgentTypedCardKind.classify(AgentChatItem(kind: .tool, text: "Thinking", detail: "Hmm",
                                                               workContext: .init(itemType: "reasoning"))))
        XCTAssertNil(AgentTypedCardKind.classify(AgentChatItem(kind: .assistant, text: "x", workContext: .init(itemType: "error"))))
        XCTAssertNil(AgentTypedCardKind.classify(AgentChatItem(kind: .approval, text: "Allow?", isComplete: false,
                                                               workContext: .init(itemType: "proposed_plan"))),
                     "A pending approval must keep its Allow/Deny row")
        XCTAssertFalse(AgentTypedCardKind.error.folds)
        XCTAssertTrue([AgentTypedCardKind.plan, .todo, .compaction, .notice].allSatisfy(\.folds))
    }

    func testTodoListDecodesStepsExplanationAndProgress() throws {
        let item = todo([step("a", "Inspect", "completed"), step("b", "Fix", "running"), step("c", "Verify", "pending")],
                        explanation: "  Three steps.  ")
        let list = try XCTUnwrap(AgentTodoList(detail: item.detail))
        XCTAssertEqual(list.steps.map(\.status), [.completed, .running, .pending])
        XCTAssertEqual(list.steps.map(\.text), ["Inspect", "Fix", "Verify"])
        XCTAssertEqual(list.explanation, "Three steps.")
        XCTAssertEqual(list.progress, "1 of 3 done")
        XCTAssertEqual(AgentTodoList(detail: #"{"steps":[]}"#)?.progress, "0 of 0 done", "An empty array is valid, as on the web")
        XCTAssertNil(AgentTodoList(detail: #"{"steps":[],"explanation":"   "}"#)?.explanation)
    }

    func testTodoValidationRejectsEveryMalformedStep() {
        let invalid: [String?] = [
            nil, "", "not json", "[]", #"{"steps":"no"}"#, #"{}"#,
            #"{"steps":[{"id":"","text":"Do","status":"pending"}]}"#,
            #"{"steps":[{"id":"  ","text":"Do","status":"pending"}]}"#,
            #"{"steps":[{"id":"1","text":" ","status":"pending"}]}"#,
            #"{"steps":[{"id":1,"text":"Do","status":"pending"}]}"#,
            #"{"steps":[{"id":"1","text":"Do","status":"inProgress"}]}"#,
            #"{"steps":[{"id":"1","text":"Do"}]}"#,
            #"{"steps":[{"id":"1","text":"Do","status":"pending"},"oops"]}"#,
        ]
        for detail in invalid { XCTAssertNil(AgentTodoList(detail: detail), detail ?? "nil") }
    }

    func testTodoDetailIsParsedOncePerChangedItemAcrossUpdates() {
        let document = AgentTranscriptDocument(frame: .zero)
        var parsed: [String?] = []
        document.classifier.parseTodo = { detail in parsed.append(detail); return AgentTodoList(detail: detail) != nil }
        let first = todo([step("1", "Write", "pending")], id: "a")
        let second = todo([step("1", "Test", "pending")], id: "b")
        document.update([first, second], omittedCount: 0)
        document.update([first, second], omittedCount: 0)
        document.update([first, second], omittedCount: 0)
        XCTAssertEqual(parsed.count, 2, "Two items, one parse each, however many snapshots")
        let changed = todo([step("1", "Test", "completed")], id: "b")
        document.update([first, changed], omittedCount: 0)
        document.update([first, changed], omittedCount: 0)
        XCTAssertEqual(parsed.count, 3, "Only the changed item is parsed again")
    }

    func testInvalidTodoFallsBackToGenericToolOutput() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let broken = AgentChatItem(id: "todo", kind: .tool, text: "Updated plan", detail: #"{"steps":[{"id":"1","status":"pending"}]}"#,
                                   workContext: .init(itemType: "todo_list"))
        document.update([broken], omittedCount: 0)
        document.reflow(viewportWidth: 700)
        XCTAssertTrue(mounted(AgentTodoCardRow.self, in: document).isEmpty)
        let row = try XCTUnwrap(mounted(AgentActivityRow.self, in: document).first)
        row.restoreState(AgentTimelineRowState(toolExpandedIDs: ["todo"]))
        XCTAssertTrue(descendants(row).compactMap { $0 as? NSTextView }.contains { $0.string.contains(#""status":"pending""#) },
                      "The raw detail is shown as tool output")
    }

    // MARK: Plans

    func testPlanStatusMapping() {
        XCTAssertEqual(AgentPlanStatus(nil), .proposed)
        XCTAssertEqual(AgentPlanStatus("bogus"), .proposed)
        XCTAssertEqual(AgentPlanStatus("active"), .active)
        XCTAssertEqual(AgentPlanStatus("completed"), .completed)
        XCTAssertEqual(AgentPlanStatus("superseded"), .superseded)
        XCTAssertEqual([AgentPlanStatus.proposed, .active, .completed, .superseded].map(\.title),
                       ["Proposed", "Active", "Completed", "Superseded"])
    }

    func testPlanCardShowsStatusPillAndReadOnlyMarkdown() throws {
        for (raw, title) in [(nil, "Proposed"), ("active", "Active"), ("completed", "Completed"), ("superseded", "Superseded")] as [(String?, String)] {
            let row = AgentPlanCardRow(frame: .zero)
            row.update([plan("# Ship it\n\nShip **today**.", status: raw)])
            place(row)
            let pill = try XCTUnwrap(descendants(row).compactMap { $0 as? AgentStatusPill }.first)
            XCTAssertEqual(pill.text, title)
            XCTAssertGreaterThan(pill.frame.width, 20)
        }
        let row = AgentPlanCardRow(frame: .zero)
        row.update([plan("# Ship it\n\nShip **today**.")])
        place(row)
        let texts = descendants(row).compactMap { $0 as? NSTextView }
        XCTAssertTrue(texts.contains { $0.string.contains("Ship today.") })
        XCTAssertFalse(texts.contains { $0.isEditable }, "Plans are read-only")
        XCTAssertTrue(descendants(row).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Plan" })
    }

    func testPlanExportNamesFilesFromTheFirstHeading() throws {
        let date = try fixedDate()
        XCTAssertEqual(AgentPlanExport.title("Intro\n\n## Migrate the Café API!\n# Later"), "Migrate the Café API!")
        XCTAssertEqual(AgentPlanExport.slug("Migrate the Café API!"), "migrate-the-cafe-api")
        XCTAssertEqual(AgentPlanExport.fileName("# Migrate the Café API!\n", date: date), "migrate-the-cafe-api-20261031-1405.md")
        XCTAssertEqual(AgentPlanExport.workspacePath("No heading here", date: date), "plans/plan-20261031-1405.md")
        XCTAssertEqual(AgentPlanExport.slug("#hashtag"), "hashtag")
        XCTAssertNil(AgentPlanExport.title("#notaheading\ntext"))
        XCTAssertEqual(AgentPlanExport.slug("🚀 !!"), "plan")
        XCTAssertLessThanOrEqual(AgentPlanExport.slug(String(repeating: "word ", count: 40)).count, 60)
        XCTAssertEqual(AgentPlanExport.markdown("\n\n# A\n\nB\n\n\n"), "# A\n\nB\n")
    }

    func testPlanCopyWritesCanonicalMarkdown() throws {
        let pasteboard = privatePasteboard()
        let row = AgentPlanCardRow(frame: .zero)
        row.services.pasteboard = pasteboard
        row.update([plan("\n# Plan A\n\n1. One\n")])
        place(row)
        row.copyButton.perform()
        XCTAssertEqual(pasteboard.string(forType: .string), "# Plan A\n\n1. One\n")
        XCTAssertNil(row.feedbackText)
    }

    func testPlanDownloadWritesTheChosenFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = AgentPlanCardRow(frame: .zero)
        let date = try fixedDate()
        var suggested: String?
        row.services.now = { date }
        row.services.chooseDownloadURL = { name in suggested = name; return directory.appendingPathComponent(name) }
        row.update([plan("# Release notes\n\nBody")])
        place(row)
        await row.downloadPlan()
        XCTAssertEqual(suggested, "release-notes-20261031-1405.md")
        let written = try String(contentsOf: directory.appendingPathComponent("release-notes-20261031-1405.md"), encoding: .utf8)
        XCTAssertEqual(written, "# Release notes\n\nBody\n")
        XCTAssertEqual(row.feedbackIsFailure, false)
    }

    func testPlanDownloadCancelAndWriteFailure() async throws {
        let row = AgentPlanCardRow(frame: .zero)
        row.services.chooseDownloadURL = { _ in nil }
        row.update([plan("# P")])
        place(row)
        await row.downloadPlan()
        XCTAssertNil(row.feedbackText, "Cancelling the save panel is silent")
        row.services.chooseDownloadURL = { _ in URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/plan.md") }
        await row.downloadPlan()
        XCTAssertEqual(row.feedbackIsFailure, true)
        XCTAssertTrue(row.feedbackText?.hasPrefix("The plan could not be downloaded") == true)
    }

    func testPlanSaveWritesToWorkspacePlansFolder() async throws {
        let row = AgentPlanCardRow(frame: .zero)
        let date = try fixedDate()
        var writes: [(String, String, String?)] = []
        row.services.now = { date }
        row.services.cwd = "/workspace"
        row.services.writeProjectFile = { path, contents, cwd in
            writes.append((path, contents, cwd))
            return path
        }
        row.update([plan("# Observed migration\n\nConcrete text.")])
        place(row)
        let before = row.preferredHeight(for: 600)
        var disclosures = 0
        row.onDisclosure = { disclosures += 1 }
        await row.savePlan()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "plans/observed-migration-20261031-1405.md")
        XCTAssertEqual(writes.first?.1, "# Observed migration\n\nConcrete text.\n")
        XCTAssertEqual(writes.first?.2, "/workspace")
        XCTAssertEqual(row.feedbackText, "Saved to plans/observed-migration-20261031-1405.md")
        XCTAssertEqual(disclosures, 1, "Feedback asks the transcript to remeasure")
        XCTAssertGreaterThan(row.preferredHeight(for: 600), before)
    }

    func testPlanSaveFailureAndMissingCapabilityAreVisible() async throws {
        let row = AgentPlanCardRow(frame: .zero)
        row.update([plan("# P")])
        place(row)
        await row.savePlan()
        XCTAssertEqual(row.feedbackText, "Saving to the workspace is unavailable.")
        XCTAssertEqual(row.feedbackIsFailure, true)
        row.services.writeProjectFile = { _, _, _ in throw ModelError("Workspace write refused.") }
        await row.savePlan()
        XCTAssertEqual(row.feedbackText, "The plan could not be saved: Workspace write refused.")
        place(row)
        let label = try XCTUnwrap(descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == row.feedbackText })
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.textColor, row.theme.danger)
        XCTAssertGreaterThan(label.frame.width, 100)
    }

    func testDocumentWiresPlanSaveThroughProjectWriter() async throws {
        let document = AgentTranscriptDocument(frame: .zero)
        var received: (String, String, String?)?
        document.workspaceRoot = "/workspace"
        document.writeProjectFile = { path, contents, cwd in received = (path, contents, cwd); return path }
        document.update([plan("# Doc plan")], omittedCount: 0)
        document.reflow(viewportWidth: 700)
        let row = try XCTUnwrap(mounted(AgentPlanCardRow.self, in: document).first)
        await row.savePlan()
        XCTAssertEqual(received?.1, "# Doc plan\n")
        XCTAssertEqual(received?.2, "/workspace")
        XCTAssertTrue(received?.0.hasPrefix("plans/doc-plan-") == true)
    }

    func testPlanActionsWaitForTheStreamToFinish() {
        let row = AgentPlanCardRow(frame: .zero)
        row.update([plan("# Draft", complete: false, source: "running")])
        XCTAssertTrue(row.isStreaming)
        XCTAssertFalse(row.copyButton.isEnabled || row.downloadButton.isEnabled || row.saveButton.isEnabled)
        row.update([plan("# Draft", complete: true, source: "running")])
        XCTAssertTrue(row.isStreaming, "A running source status still streams")
        row.update([plan("# Draft\n\nDone.")])
        XCTAssertFalse(row.isStreaming)
        XCTAssertTrue(row.copyButton.isEnabled && row.downloadButton.isEnabled && row.saveButton.isEnabled)
    }

    func testStreamingPlanReusesItsRowAndRemeasuresInPlace() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        var markdown = "# Plan"
        document.update([plan(markdown, complete: false, source: "running")], omittedCount: 0)
        document.reflow(viewportWidth: 700)
        let row = try XCTUnwrap(mounted(AgentPlanCardRow.self, in: document).first)
        let initial = try XCTUnwrap(document.frameForEntry("activity:plan")).height
        for index in 0..<6 {
            markdown += "\n\n\(index + 1). Step with enough words to wrap the line at some widths"
            document.update([plan(markdown, complete: false, source: "running")], omittedCount: 0)
            document.reflow(viewportWidth: 700)
            XCTAssertTrue(mounted(AgentPlanCardRow.self, in: document).first === row, "Streaming deltas update the same row")
        }
        XCTAssertGreaterThan(try XCTUnwrap(document.frameForEntry("activity:plan")).height, initial + 60)
        XCTAssertTrue(descendants(row).compactMap { $0 as? NSTextView }.contains { $0.string.contains("6. Step") || $0.string.contains("Step with") })
        XCTAssertEqual(mounted(AgentPlanCardRow.self, in: document).count, 1)
    }

    // MARK: Todos

    func testTodoCardRendersGlyphsStrikethroughAndExplanation() throws {
        let row = AgentTodoCardRow(frame: .zero)
        row.update([todo([step("a", "Inspect", "completed"), step("b", "Fix", "running"), step("c", "Verify", "pending")],
                         explanation: "Short plan.")])
        place(row)
        XCTAssertEqual(row.progressText, "1 of 3 done")
        let text = row.stepsText
        let ns = text.string as NSString
        XCTAssertEqual(text.string.components(separatedBy: "\n").count, 3)
        var attachments: [String] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let image = (value as? NSTextAttachment)?.image { attachments.append(image.accessibilityDescription ?? "") }
        }
        XCTAssertEqual(attachments, ["Completed", "In progress", "Pending"])
        let done = ns.range(of: "Inspect"), fix = ns.range(of: "Fix")
        XCTAssertNotNil(text.attribute(.strikethroughStyle, at: done.location, effectiveRange: nil))
        XCTAssertNil(text.attribute(.strikethroughStyle, at: fix.location, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.foregroundColor, at: done.location, effectiveRange: nil) as? NSColor, row.theme.fgDim)
        XCTAssertTrue(descendants(row).compactMap { $0 as? NSTextView }.contains { $0.string == "Short plan." && !$0.isHidden })
    }

    func testTodoUpdatesInPlaceAsStepsComplete() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items: ([String]) -> [AgentChatItem] = { statuses in
            [self.todo(statuses.enumerated().map { self.step("s\($0.offset)", "Step \($0.offset)", $0.element) })]
        }
        document.update(items(["running", "pending", "pending"]), omittedCount: 0)
        document.reflow(viewportWidth: 700)
        let row = try XCTUnwrap(mounted(AgentTodoCardRow.self, in: document).first)
        XCTAssertEqual(row.progressText, "0 of 3 done")
        document.update(items(["completed", "running", "pending"]), omittedCount: 0)
        document.reflow(viewportWidth: 700)
        XCTAssertTrue(mounted(AgentTodoCardRow.self, in: document).first === row)
        XCTAssertEqual(row.progressText, "1 of 3 done")
        document.update(items(["completed", "completed", "completed", "pending"]), omittedCount: 0)
        document.reflow(viewportWidth: 700)
        XCTAssertTrue(mounted(AgentTodoCardRow.self, in: document).first === row)
        XCTAssertEqual(row.progressText, "3 of 4 done")
        XCTAssertGreaterThan(row.frame.height, 100)
    }

    // MARK: Compaction

    func testCompactionTokenFormatting() {
        XCTAssertEqual(AgentCompactionPresentation.tokens(950), "950")
        XCTAssertEqual(AgentCompactionPresentation.tokens(1_000), "1k")
        XCTAssertEqual(AgentCompactionPresentation.tokens(5_801), "5.8k")
        XCTAssertEqual(AgentCompactionPresentation.tokens(148_213), "148k")
        XCTAssertEqual(AgentCompactionPresentation.tokens(32_000), "32k")
        XCTAssertEqual(AgentCompactionPresentation.tokens(999_999), "1M")
        XCTAssertEqual(AgentCompactionPresentation.tokens(1_260_000), "1.3M")
        XCTAssertEqual(AgentCompactionPresentation.tokens(-5), "0")
    }

    func testCompactionLabelForEachProviderWithAndWithoutCounts() {
        let counted = compaction(before: 148_000, after: 32_000)
        XCTAssertEqual(AgentCompactionPresentation.label(counted, provider: .claude), "Context compacted · Claude Agent · 148k → 32k tokens")
        XCTAssertEqual(AgentCompactionPresentation.label(counted, provider: .codex), "Context compacted · Codex · 148k → 32k tokens")
        XCTAssertEqual(AgentCompactionPresentation.label(counted, provider: nil), "Context compacted · 148k → 32k tokens")
        XCTAssertEqual(AgentCompactionPresentation.label(compaction(), provider: .codex), "Context compacted · Codex")
        XCTAssertEqual(AgentCompactionPresentation.label(compaction(before: 12_000), provider: .claude), "Context compacted · Claude Agent · 12k tokens before")
        XCTAssertEqual(AgentCompactionPresentation.label(compaction(after: 5_801), provider: .claude), "Context compacted · Claude Agent · 5.8k tokens after")
        var running = compaction()
        running.text = "Compacting context"
        XCTAssertEqual(AgentCompactionPresentation.label(running, provider: .claude), "Compacting context · Claude Agent")
    }

    func testCompactionDisclosureRevealsMarkdownSummary() throws {
        let row = AgentCompactionRow(frame: .zero)
        row.provider = .claude
        row.update([compaction(before: 148_000, after: 32_000, summary: "## Summary\n\n- Kept **decisions**")])
        place(row)
        XCTAssertEqual(row.header.title, "Context compacted · Claude Agent · 148k → 32k tokens")
        XCTAssertTrue(row.header.isEnabled)
        XCTAssertEqual(row.preferredHeight(for: 600), 28)
        var disclosures = 0
        row.onDisclosure = { disclosures += 1 }
        row.header.performClick(nil)
        XCTAssertEqual(disclosures, 1)
        place(row)
        XCTAssertGreaterThan(row.frame.height, 50)
        XCTAssertTrue(descendants(row).compactMap { $0 as? NSTextView }.contains { $0.string.contains("Kept decisions") && !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(row.captureState().expanded, true)
        let quiet = AgentCompactionRow(frame: .zero)
        quiet.update([compaction()])
        XCTAssertFalse(quiet.header.isEnabled, "No summary, no disclosure")
    }

    func testDocumentPassesProviderToCompactionRows() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        document.provider = .codex
        document.update([compaction(before: 2_000, after: 1_000)], omittedCount: 0)
        document.reflow(viewportWidth: 700)
        let row = try XCTUnwrap(mounted(AgentCompactionRow.self, in: document).first)
        XCTAssertEqual(row.header.title, "Context compacted · Codex · 2k → 1k tokens")
        document.provider = .claude
        document.reflow(viewportWidth: 700)
        XCTAssertEqual(try XCTUnwrap(mounted(AgentCompactionRow.self, in: document).first).header.title,
                       "Context compacted · Claude Agent · 2k → 1k tokens")
    }

    // MARK: Errors and notices

    func testErrorMessageIsTrimmedClippedAndNeverEmpty() {
        XCTAssertEqual(AgentErrorPresentation.message("  \n boom \n"), "boom")
        XCTAssertEqual(AgentErrorPresentation.message("   "), "Agent failed")
        let long = String(repeating: "x", count: 5_000)
        XCTAssertEqual(AgentErrorPresentation.message(long).count, 4_096)
        let row = AgentErrorCardRow(frame: .zero)
        row.update([failure(" " + long)])
        place(row)
        XCTAssertEqual(row.bodyText.count, 4_096)
    }

    func testErrorCardIsDangerTintedAndMonospacesStackTraces() throws {
        let row = AgentErrorCardRow(frame: .zero)
        row.update([failure("The selected model is unavailable.")])
        place(row)
        let title = try XCTUnwrap(descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Agent failed" })
        XCTAssertEqual(title.textColor, row.theme.danger)
        XCTAssertFalse(row.isMonospaced)
        XCTAssertFalse(row.bodyFont?.isFixedPitch ?? true)
        row.update([failure("TypeError: x is undefined\n    at run (main.js:10:3)\n    at start (main.js:2:1)")])
        place(row)
        XCTAssertTrue(row.isMonospaced)
        XCTAssertTrue(row.bodyFont?.isFixedPitch ?? false)
        XCTAssertTrue(AgentErrorPresentation.looksLikeStackTrace("Traceback (most recent call last):\n  File \"a.py\", line 1"))
        XCTAssertTrue(AgentErrorPresentation.looksLikeStackTrace("Fatal error\nSources/A.swift:12: crash\nSources/B.swift:40: caller"))
        XCTAssertFalse(AgentErrorPresentation.looksLikeStackTrace("Rate limited at 12:00. Try again later."))
    }

    func testNoticesUseTheQuietInfoRow() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        document.update([AgentChatItem(id: "n", kind: .notice, text: "Agent interrupted.")], omittedCount: 0)
        document.reflow(viewportWidth: 700)
        let row = try XCTUnwrap(mounted(AgentNoticeRow.self, in: document).first)
        XCTAssertTrue(descendants(row).compactMap { $0 as? NSTextView }.contains { $0.string == "Agent interrupted." })
        XCTAssertEqual(try XCTUnwrap(document.frameForEntry("n")).height, 24)
        XCTAssertTrue(descendants(row).contains { ($0 as? NSImageView)?.image != nil })
    }

    // MARK: Folding

    func testPlansTodosAndCompactionFoldIntoCompletedWork() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let items = [AgentChatItem(id: "user", kind: .user, text: "Plan it"),
                     plan("# Plan"), todo([step("1", "Do", "completed")]), compaction(),
                     AgentChatItem(id: "answer", kind: .assistant, text: "Done.")]
        document.update(items, omittedCount: 0, turns: [turn])
        document.reflow(viewportWidth: 700)
        XCTAssertEqual(document.entryCount, 3, "user, Worked for, answer")
        XCTAssertNil(document.frameForEntry("activity:plan"))
        XCTAssertTrue(mounted(AgentPlanCardRow.self, in: document).isEmpty)
        var states = document.rowStates
        states["work:user"] = AgentTimelineRowState(expanded: true)
        document.rowStates = states
        document.reflow(viewportWidth: 700)
        XCTAssertNotNil(document.frameForEntry("activity:plan"))
        XCTAssertNotNil(document.frameForEntry("activity:todo"))
        XCTAssertNotNil(document.frameForEntry("activity:compact"))
        XCTAssertEqual(mounted(AgentPlanCardRow.self, in: document).count, 1)
        XCTAssertEqual(mounted(AgentTodoCardRow.self, in: document).count, 1)
        XCTAssertEqual(mounted(AgentCompactionRow.self, in: document).count, 1)
    }

    func testAPlanAloneMakesATurnFoldable() {
        let document = AgentTranscriptDocument(frame: .zero)
        document.update([AgentChatItem(id: "user", kind: .user, text: "Plan"), plan("# Only a plan"),
                         AgentChatItem(id: "answer", kind: .assistant, text: "Here it is.")], omittedCount: 0, turns: [turn])
        XCTAssertNotNil(document.frameForEntry("work:user"))
        XCTAssertNil(document.frameForEntry("activity:plan"))
    }

    func testErrorCardsStayVisibleBelowAFoldedTurn() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let failed = AgentChatTurn(userItemID: "user", startedAt: Date(timeIntervalSince1970: 100),
                                   completedAt: Date(timeIntervalSince1970: 110), status: .failed)
        let items = [AgentChatItem(id: "user", kind: .user, text: "Run"),
                     AgentChatItem(id: "tool", kind: .tool, text: "Read file", detail: "x"),
                     failure("Provider crashed")]
        document.update(items, omittedCount: 0, turns: [failed])
        document.reflow(viewportWidth: 700)
        let work = try XCTUnwrap(document.frameForEntry("work:user"))
        let error = try XCTUnwrap(document.frameForEntry("failure"))
        XCTAssertGreaterThan(error.minY, work.maxY)
        XCTAssertNil(document.frameForEntry("activity:tool"))
        XCTAssertEqual(mounted(AgentErrorCardRow.self, in: document).count, 1)
        var states = document.rowStates
        states["work:user"] = AgentTimelineRowState(expanded: true)
        document.rowStates = states
        XCTAssertEqual(document.entryCount, 4, "user, Worked for, the tool, and the error once")
    }

    // MARK: Measurement

    func testCardsMeasureOncePerWidthAndGrowWhenNarrow() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        let long = String(repeating: "This sentence wraps across the card. ", count: 12)
        let items = [plan("# Plan\n\n" + long), todo([step("1", long, "pending"), step("2", "Short", "completed")]),
                     failure(long), compaction(before: 10, after: 5)]
        document.update(items, omittedCount: 0)
        document.reflow(viewportWidth: 800)
        let wide = try ["activity:plan", "activity:todo", "failure"].map { try XCTUnwrap(document.frameForEntry($0)).height }
        let count = document.measurementCount
        document.reflow(viewportWidth: 800)
        XCTAssertEqual(document.measurementCount, count, "An unchanged width does not remeasure")
        document.reflow(viewportWidth: 360)
        let narrow = try ["activity:plan", "activity:todo", "failure"].map { try XCTUnwrap(document.frameForEntry($0)).height }
        for (wideHeight, narrowHeight) in zip(wide, narrow) { XCTAssertGreaterThan(narrowHeight, wideHeight) }
        XCTAssertEqual(try XCTUnwrap(document.frameForEntry("activity:compact")).height, 28)
        let afterNarrow = document.measurementCount
        document.reflow(viewportWidth: 360)
        XCTAssertEqual(document.measurementCount, afterNarrow)
    }

    // MARK: Tool rows

    func testDeclinedToolShowsItsNonExecutionKind() throws {
        XCTAssertEqual(AgentToolNonExecution.label("permission-rule"), "Blocked by permission rule")
        XCTAssertEqual(AgentToolNonExecution.label("cancelled"), "Cancelled")
        XCTAssertEqual(AgentToolNonExecution.label("user_declined"), "User declined")
        XCTAssertNil(AgentToolNonExecution.label(" "))
        let row = AgentActivityRow(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        row.update([AgentChatItem(id: "t", kind: .tool, text: "Bash", tool: .init(category: .command, status: .denied),
                                  workContext: .init(toolNonExecutionKind: "permission-rule"))])
        let header = try XCTUnwrap(descendants(row).compactMap { $0 as? AgentToolHeader }.first)
        XCTAssertEqual(header.suffix, "Blocked by permission rule")
        XCTAssertTrue(header.accessibilityLabel()?.contains("Blocked by permission rule") == true)
    }

    func testReasoningStreamsAsProseInOneRow() throws {
        let document = AgentTranscriptDocument(frame: .zero)
        func thinking(_ text: String, done: Bool) -> AgentChatItem {
            AgentChatItem(id: "r", kind: .tool, text: "Thinking", detail: text, isComplete: done,
                          workContext: .init(itemType: "reasoning", sourceStatus: done ? "completed" : "running"))
        }
        document.update([thinking("Considering", done: false)], omittedCount: 0)
        var states = document.rowStates
        states["activity:r"] = AgentTimelineRowState(toolExpandedIDs: ["r"])
        document.rowStates = states
        document.reflow(viewportWidth: 700)
        let row = try XCTUnwrap(mounted(AgentActivityRow.self, in: document).first)
        document.update([thinking("Considering the options", done: true)], omittedCount: 0)
        document.reflow(viewportWidth: 700)
        XCTAssertTrue(mounted(AgentActivityRow.self, in: document).first === row)
        let text = try XCTUnwrap(descendants(row).compactMap { $0 as? NSTextView }.first { $0.string.contains("Considering") })
        XCTAssertEqual(text.string, "Considering the options", "Reasoning is prose, without an Output heading")
        XCTAssertFalse((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch ?? true)
    }
}
