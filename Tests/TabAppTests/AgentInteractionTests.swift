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
        let form = AgentQuestionnaire(questions: [.init(id: "design", title: "Which design should we use for the subscription button?", options: [.init(label: "Compact", description: "Keep the existing layout and reduce visual weight."), .init(label: "Prominent", description: "Make the action stand out.")])])
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

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
