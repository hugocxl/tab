import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentInteractionTests: XCTestCase {
    func testDraftRoundTripRetainsCitationAttachmentAndSubmissionIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentDraftStore(url: root.appendingPathComponent("draft.json"))
        let text = NSMutableAttributedString(string: "Discuss this quote")
        text.addAttribute(.agentAssistantCitation, value: "citation-payload", range: NSRange(location: 8, length: 10))
        let attachment = AgentDraftAttachment(name: "note.txt", mimeType: "text/plain", data: Data("original".utf8))
        let submission = AgentPrompt(text: text.string, model: nil, effort: nil, provider: .codex, planMode: false)
        let draft = AgentSavedDraft(text: text, attachments: [attachment], submission: submission, answers: ["form": ["q": ["answer"]]])
        try await store.write(draft, revision: 2)
        let older = AgentSavedDraft(text: NSAttributedString(string: "stale"), attachments: [], submission: nil, answers: [:])
        try await store.write(older, revision: 1)
        let loaded = try await store.read()
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.text, text.string)
        XCTAssertEqual(restored.submission?.id, submission.id)
        XCTAssertEqual(restored.attachments.first?.id, attachment.id)
        XCTAssertEqual(restored.attachments.first?.data, attachment.data)
        XCTAssertEqual(restored.answers, draft.answers)
        XCTAssertEqual(restored.attributed(theme: AppTheme.shared).attribute(.agentAssistantCitation, at: 9, effectiveRange: nil) as? String, "citation-payload")
    }

    func testCorruptDraftIsPreservedBeforeAnyNewSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.json")
        let original = Data("broken JSON with original draft bytes".utf8)
        try original.write(to: url)
        let store = AgentDraftStore(url: url)
        do { _ = try await store.read(); XCTFail("Corruption must be reported") } catch {}
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testQuestionFormPreservesEditsAndDoesNotSaveSecrets() throws {
        let form = AgentQuestionnaire(questions: [
            .init(id: "choice", title: "Pick", options: [.init(label: "One"), .init(label: "Two")]),
            .init(id: "secret", title: "Secret", secret: true)
        ])
        let item = AgentChatItem(id: "form", kind: .approval, text: "Questions", isComplete: false, questionnaire: form)
        let view = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
        view.update(item, enabled: true)
        view.restore(["form": ["choice": ["Two"], "secret": ["memory-only"]]])
        view.update(item, enabled: false)
        XCTAssertEqual(view.answers["secret"], ["memory-only"])
        XCTAssertEqual(view.savedAnswers, ["form": ["choice": ["Two"]]])
        XCTAssertEqual(view.answers["choice"], ["Two"])
        let fields = descendants(view).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        XCTAssertTrue(fields.allSatisfy { !$0.isEnabled })
        var sent: [String: [String]]?
        view.onAnswer = { _, answers, _ in sent = answers }
        view.update(item, enabled: true)
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? PillButton }.first { $0.title == "Submit answers" })
        button.onPress?()
        XCTAssertEqual(sent?["choice"], ["Two"])
        XCTAssertEqual(sent?["secret"], ["memory-only"])
    }

    func testQueueAndFormFitNarrowPanelAndRenderFixtures() throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 360, height: 820))
        let window = NSWindow(contentRect: surface.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.contentView = nil; window.close() }
        let prompt = AgentPrompt(text: "Can you improve the subscribe button and preserve all of these attachments?", model: nil, effort: nil, provider: .codex, planMode: false)
        let form = AgentQuestionnaire(questions: [
            .init(id: "design", title: "Which design should we use for the subscription button?", options: [.init(label: "Compact (Recommended)", description: "Keep the existing layout and reduce visual weight."), .init(label: "Prominent", description: "Make the action stand out.")], header: "Button"),
            .init(id: "extras", title: "Which extras should ship with it?", options: [.init(label: "Price hint"), .init(label: "Trial badge")], multiple: true, required: false),
        ])
        let item = AgentChatItem(id: "q", kind: .approval, text: "Questions for you", isComplete: false, questionnaire: form)
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex)
        snapshot.items = [item]; snapshot.planMode = true; snapshot.status = .waiting
        snapshot.queuedPrompts = [.init(prompt: prompt)]
        surface.render(snapshot)
        surface.promptQueue.update(snapshot.queuedPrompts ?? [], paused: false, enabled: true)
        surface.questions.update(item, enabled: true)
        surface.plan.isHidden = false
        surface.setActivity(status: .waiting, submitting: false)
        surface.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(surface.questions.frame.height, 180)
        XCTAssertGreaterThan(surface.promptQueue.frame.height, 40)
        XCTAssertLessThanOrEqual(surface.promptQueue.frame.maxY, surface.questions.frame.minY)
        XCTAssertLessThanOrEqual(surface.questions.convert(surface.questions.bounds, to: surface).maxY, surface.composerScroll.superview?.frame.minY ?? 0)
        XCTAssertFalse(surface.plan.frame.intersects(surface.modelPicker.frame))
        // Send, Stop and Dictate share one slot; exactly one of them shows.
        XCTAssertEqual([surface.send, surface.stop, surface.microphone].filter { !$0.isHidden }.count, 1)
        if let path = ProcessInfo.processInfo.environment["TAB_AGENT_AUDIT_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent("questions-and-queue.png"))
        }
    }

    /// L6: a single choice is an option or a written answer, never both, as it is edited.
    func testSingleChoiceOptionAndWrittenAnswerStayExclusiveWhileEditing() throws {
        let form = AgentQuestionnaire(questions: [
            .init(id: "choice", title: "Pick", options: [.init(label: "One"), .init(label: "Two")]),
            .init(id: "many", title: "Also", options: [.init(label: "A"), .init(label: "B")], multiple: true, required: false),
            .init(id: "note", title: "Note", required: false),
            .init(id: "secret", title: "Token", secret: true, required: false)
        ])
        let item = AgentChatItem(id: "form", kind: .approval, text: "Questions", isComplete: false, questionnaire: form)
        let view = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
        view.update(item, enabled: true)
        let buttons = descendants(view).compactMap { $0 as? NSButton }.filter { !($0 is PillButton) }
        let one = try XCTUnwrap(buttons.first { $0.title == "One" }), two = try XCTUnwrap(buttons.first { $0.title == "Two" })
        let a = try XCTUnwrap(buttons.first { $0.title == "A" })
        let fields = descendants(view).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let choiceField = fields[0], manyField = fields[1], secretField = try XCTUnwrap(fields.first { $0 is NSSecureTextField })
        func type(_ text: String, in field: NSTextField) {
            field.stringValue = text
            view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        one.performClick(nil)
        XCTAssertEqual(view.answers["choice"], ["One"])
        type("Something else", in: choiceField)
        XCTAssertEqual(one.state, .off, "Writing an answer clears the chosen option")
        XCTAssertEqual(view.answers["choice"], ["Something else"])
        type("", in: choiceField)
        XCTAssertEqual(view.answers["choice"], [], "Nothing shows, so nothing is sent")
        two.performClick(nil)
        XCTAssertEqual(two.state, .on)
        XCTAssertEqual(choiceField.stringValue, "")
        a.performClick(nil)
        type("C", in: manyField)
        XCTAssertEqual(a.state, .on, "Multiple choice keeps options beside a written answer")
        XCTAssertEqual(view.answers["many"], ["A", "C"])
        type("hunter2", in: secretField)
        // An older draft never replaces what was edited since.
        view.restore(["form": ["choice": ["One"]]])
        XCTAssertEqual(two.state, .on)
        XCTAssertEqual(one.state, .off)
        XCTAssertNil(view.savedAnswers["form"]?["secret"], "Secret text stays out of drafts")
        var sent: [String: [String]]?
        view.onAnswer = { _, answers, _ in sent = answers }
        XCTAssertTrue(view.submitAnswers())
        XCTAssertEqual(sent?["choice"], ["Two"])
        XCTAssertEqual(sent?["secret"], ["hunter2"])
    }

    func testRestoredWrittenAnswerLeavesOptionsClear() throws {
        let form = AgentQuestionnaire(questions: [.init(id: "choice", title: "Pick", options: [.init(label: "One")])])
        let item = AgentChatItem(id: "form", kind: .approval, text: "Questions", isComplete: false, questionnaire: form)
        let view = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
        view.update(item, enabled: true)
        view.restore(["form": ["choice": ["Mine"]]])
        let one = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "One" })
        XCTAssertEqual(one.state, .off)
        XCTAssertEqual(view.answers["choice"], ["Mine"])
    }

    /// L2: an MCP form shows the server's own Submit, Decline and Dismiss.
    func testElicitationFormOffersTheProvidersDecisions() throws {
        let form = AgentQuestionnaire(questions: [.init(id: "plan", title: "Plan", options: [.init(label: "Pro")])])
        let offered = AgentApprovalRequest(kind: "elicitation", decisions: [
            .init(id: "accept", kind: .submit, title: "Submit"), .init(id: "decline", kind: .decline, title: "Decline"),
            .init(id: "cancel", kind: .cancel, title: "Dismiss"),
        ])
        let item = AgentChatItem(id: "elic", kind: .approval, text: "Pick a plan", isComplete: false, questionnaire: form, approval: offered)
        let view = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
        view.update(item, enabled: true)
        let pills = descendants(view).compactMap { $0 as? PillButton }.filter { !$0.isHidden }
        XCTAssertEqual(Set(pills.map(\.title)), ["Submit", "Decline", "Dismiss"])
        var decided: (String, String)?
        view.onDecision = { decided = ($0, $1) }
        pills.first { $0.title == "Decline" }?.onPress?()
        XCTAssertEqual(decided?.0, "elic")
        XCTAssertEqual(decided?.1, "decline")
    }

    func testApprovalDetailsNameTheChildAgentAndWhatWasAsked() {
        let request = AgentApprovalRequest(kind: "permissions", summary: "Needs the network",
            requested: [.init(label: "Network", value: "Internet access")],
            decisions: [.init(id: "turn", kind: .allowOnce, title: "Allow for this turn")],
            origin: .init(providerRequestID: "22", threadID: "child-b", childAgentID: "child-b", childToolUseID: "spawn-b", childTitle: "Run the tests"))
        let text = AgentApprovalPresentation.details(request)
        XCTAssertTrue(text.contains("Asked by agent: Run the tests"))
        XCTAssertTrue(text.contains("Network: Internet access"))
        XCTAssertEqual(AgentApprovalPresentation.pendingTitle(request), "Approval needed · agent “Run the tests”")
        XCTAssertNil(AgentApprovalPresentation.shortcutDecision(request, allow: false))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
