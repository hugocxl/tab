import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// Holds an import until the test lets it finish.
private actor ImportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

/// A server with a durable queue: prompts submitted while a turn runs wait, revision
/// checked, until delivered; delivery steers them into the turn.
@MainActor
private final class QueueBackend {
    let session = SessionId()
    let project = ProjectId()
    var requests: [AgentChatRequest] = []
    var payloads: [String: AgentPrompt] = [:]
    /// Applies the next request, then loses its reply.
    var dropNextReply = false
    /// Fails the next queue edit before applying it.
    var failNextEdit: Error?
    /// The turn ends, and the queue sends the prompt as a new turn, just before a delivery request arrives.
    var endTurnBeforeDelivery = false
    /// Completes deliveries at once, as a steer the provider accepted.
    var completeDeliveries = true
    var readGate: CheckedContinuation<Void, Never>?
    var gateNextRead = false
    lazy var snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, accessMode: .fullAccess)

    var submissions: [AgentPrompt] { requests.compactMap { if case .submit(_, let prompt) = $0 { return prompt }; return nil } }
    var deliveries: Int { requests.filter { if case .deliverQueued = $0 { return true }; return false }.count }
    var userTexts: [String] { snapshot.items.filter { $0.kind == .user }.map(\.text) }

    private func changed() -> Error { ModelError("This queued prompt changed. Refresh before trying again.") }

    private func index(_ id: String, _ revision: UInt64) throws -> Int {
        guard let index = snapshot.queuedPrompts?.firstIndex(where: { $0.id == id }),
              snapshot.queuedPrompts?[index].revision == revision, snapshot.queuedPrompts?[index].state != .delivering else { throw changed() }
        return index
    }

    func queue(_ prompt: AgentPrompt) {
        payloads[prompt.id] = prompt
        snapshot.queuedPrompts = (snapshot.queuedPrompts ?? []) + [AgentQueuedPrompt(prompt: prompt)]
    }

    func deliver(_ id: String) {
        snapshot.queuedPrompts?.removeAll { $0.id == id }
        snapshot.items.append(AgentChatItem(kind: .user, text: payloads[id]?.text ?? ""))
        snapshot.status = .working
        snapshot.revision += 1
    }

    /// Another client's edit.
    func editElsewhere(_ id: String, text: String) {
        guard let index = snapshot.queuedPrompts?.firstIndex(where: { $0.id == id }) else { return }
        snapshot.queuedPrompts?[index].text = text
        snapshot.queuedPrompts?[index].revision += 1
        payloads[id]?.text = text
        snapshot.revision += 1
    }

    func request(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
        requests.append(request)
        switch request {
        case .read:
            if gateNextRead {
                gateNextRead = false
                await withCheckedContinuation { readGate = $0 }
            }
        case .submit(_, let prompt):
            if snapshot.status == .working || snapshot.status == .waiting { queue(prompt) } else {
                payloads[prompt.id] = prompt
                snapshot.items.append(AgentChatItem(kind: .user, text: prompt.text))
                snapshot.status = .working
            }
        case .deliverQueued(_, let id, let revision):
            if endTurnBeforeDelivery {
                endTurnBeforeDelivery = false
                deliver(id)
                throw changed()
            }
            let index = try index(id, revision)
            guard snapshot.status == .working else { throw ModelError("Wait for the current interaction before delivering this prompt.") }
            snapshot.queuedPrompts?[index].state = .delivering
            snapshot.queuedPrompts?[index].revision += 1
            if completeDeliveries { deliver(id) }
        case .editQueued(_, let id, let text, let revision, _):
            if let failNextEdit { self.failNextEdit = nil; throw failNextEdit }
            let index = try index(id, revision)
            snapshot.queuedPrompts?[index].text = text
            snapshot.queuedPrompts?[index].revision += 1
            payloads[id]?.text = text
        case .editQueuedPrompt(_, let id, let revision, let edit):
            if let failNextEdit { self.failNextEdit = nil; throw failNextEdit }
            let index = try index(id, revision)
            guard var prompt = payloads[id] else { throw changed() }
            let kept = try edit.keptAttachments.map { kept in
                guard let attachment = prompt.attachments.first(where: { $0.id == kept }) else { throw changed() }
                return attachment
            }
            prompt.text = edit.text
            prompt.attachments = kept + edit.addedAttachments
            payloads[id] = prompt
            snapshot.queuedPrompts?[index].text = prompt.text
            snapshot.queuedPrompts?[index].attachments = prompt.attachments.map(\.descriptor)
            snapshot.queuedPrompts?[index].revision += 1
        case .clear(_, let archive, _):
            snapshot.items = []; snapshot.resetID = archive
        default: break
        }
        snapshot.revision += 1
        if dropNextReply {
            dropNextReply = false
            throw NSError(domain: "The connection was lost", code: 9)
        }
        return snapshot
    }

    func controller() -> AgentPaneController {
        AgentPaneController(session: session, project: project, provider: .claude) { [self] in try await request($0) }
    }
}

@MainActor
final class AgentComposerWorkTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The composer did not settle")
    }

    private func draftURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-work-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("agent-drafts/pane.json")
    }

    private func connected(_ backend: QueueBackend, draft: URL? = nil) async throws -> AgentPaneController {
        let pane = backend.controller()
        if let draft { pane.configureDraftStore(draft) }
        pane.refresh()
        try await wait { pane.snapshot != nil && !pane.restoringDraft }
        return pane
    }

    private func text(_ name: String, _ body: String = "body") -> AgentDraftAttachment {
        AgentDraftAttachment(name: name, mimeType: "text/plain", data: Data(body.utf8))
    }

    // MARK: C1

    func testLongPasteReportsWhatActuallyHappenedToTheDraft() async throws {
        let backend = QueueBackend()
        let pane = try await connected(backend)
        defer { pane.dispose() }
        // Multibyte text is attached byte for byte, and success is said only once it is there.
        let multibyte = String(repeating: "日本語🙂", count: 2_600)
        XCTAssertTrue(pane.attachLongPaste(multibyte))
        XCTAssertEqual(pane.draftAttachments.map(\.data), [Data(multibyte.utf8)])
        XCTAssertEqual(pane.notice?.text, "The long paste was attached as a text file.")
        XCTAssertTrue(pane.attachLongPaste(multibyte))
        XCTAssertEqual(pane.draftAttachments.count, 1)
        XCTAssertEqual(pane.notice?.text, "This text is already attached.")

        // At the slot limit, a paste the message can hold goes in as text.
        pane.draftAttachments += (1..<AgentChatAttachment.maxCount).map { text("File \($0).txt") }
        pane.updateAttachments()
        let fits = (1...300).map { "row \($0) — ü" }.joined(separator: "\n")
        pane.surface.composer.string = "Draft: "
        pane.surface.composer.setSelectedRange(NSRange(location: 7, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fits, forType: .string)
        pane.surface.composer.paste(nil)
        XCTAssertEqual(pane.surface.composer.string, "Draft: " + fits)
        XCTAssertEqual(pane.draftAttachments.count, AgentChatAttachment.maxCount)
        XCTAssertEqual(pane.notice?.kind, .info)
        XCTAssertTrue(pane.notice?.text.contains("went into the message as text") == true)

        // Too long for the message as well: nothing changes and the notice says why.
        let tooLong = String(repeating: "é", count: AgentPaneController.maximumPromptBytes / 2 + 10)
        XCTAssertTrue(pane.attachLongPaste(tooLong))
        XCTAssertEqual(pane.surface.composer.string, "Draft: " + fits)
        XCTAssertEqual(pane.notice?.kind, .warning)
        XCTAssertTrue(pane.notice?.text.contains("wasn't added") == true)

        // At the byte limit the same rules apply.
        pane.surface.composer.string = ""
        pane.draftAttachments = [AgentDraftAttachment(name: "Large.bin", mimeType: "application/octet-stream",
                                                      data: Data(count: AgentChatAttachment.maxTotalBytes - 100))]
        pane.updateAttachments()
        let medium = String(repeating: "x", count: 20_000)
        XCTAssertFalse(pane.attachLongPaste(medium), "The text view inserts it")
        XCTAssertEqual(pane.draftAttachments.count, 1)
        XCTAssertTrue(pane.notice?.text.contains("8 MB") == true)
    }

    // MARK: C2

    func testClearingTheDraftDropsImportsStillRunningButClearingTheConversationKeepsThem() async throws {
        let backend = QueueBackend()
        let url = draftURL()
        let pane = try await connected(backend, draft: url)
        defer { pane.dispose() }
        let gates = [ImportGate(), ImportGate()]
        for (index, gate) in gates.enumerated() {
            let old = text("Old \(index).txt", "old \(index)")
            pane.prepareAttachments { await gate.wait(); return AgentAttachmentIntake(attachments: [old]) }
        }
        XCTAssertEqual(pane.preparingAttachments, 2)
        pane.surface.composer.string = "/clear-draft"
        pane.send()
        XCTAssertEqual(pane.preparingAttachments, 0, "Cleared imports no longer hold Send")
        pane.surface.composer.string = "A new prompt"
        for gate in gates { await gate.release() }
        try await wait { pane.composerWork.imports.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(pane.draftAttachments.isEmpty)
        try await pane.flushDraft()
        let saved = try await AgentDraftStore(url: url).read()
        XCTAssertEqual(saved?.text, "A new prompt")
        XCTAssertEqual(saved?.attachments.count, 0)
        pane.send()
        try await wait { !backend.submissions.isEmpty }
        XCTAssertEqual(backend.submissions.map(\.text), ["A new prompt"])
        XCTAssertEqual(backend.submissions.first?.attachments, [])

        // /clear archives the conversation in place and leaves the draft's imports alone.
        backend.snapshot.status = .idle
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.status == .idle && pane.commandTask == nil }
        let gate = ImportGate()
        let kept = text("Kept.txt")
        pane.prepareAttachments { await gate.wait(); return AgentAttachmentIntake(attachments: [kept]) }
        pane.surface.composer.string = "/clear"
        pane.send()
        try await wait { pane.snapshot?.resetID != nil }
        await gate.release()
        try await wait { pane.draftAttachments.map(\.name) == ["Kept.txt"] }
    }

    // MARK: C3

    private func queuedPrompt(_ backend: QueueBackend, text: String, attachments: [AgentChatAttachment] = []) -> AgentQueuedPrompt {
        backend.snapshot.status = .working
        let prompt = AgentPrompt(text: text, model: nil, effort: nil, provider: .claude, planMode: false, attachments: attachments)
        backend.queue(prompt)
        backend.snapshot.revision += 1
        return AgentQueuedPrompt(prompt: prompt)
    }

    func testAStaleQueuedEditStaysRecoverableAndNeverResends() async throws {
        let backend = QueueBackend()
        let prompt = queuedPrompt(backend, text: "Original")
        let pane = try await connected(backend)
        defer { pane.dispose() }
        pane.surface.composer.string = "My composer draft"
        var presented: [AgentQueuedPromptEdit] = []
        pane.composerWork.presentQueuedEditor = { edit in
            presented.append(edit)
            // The other client saves while this one is still editing.
            if presented.count == 1 { backend.editElsewhere(prompt.id, text: "Other client") }
            var edited = edit
            edited.text = "My edit"
            return edited
        }
        var recoveries: [AgentQueuedEditRecovery] = []
        pane.composerWork.chooseQueueEditRecovery = { recovery in
            recoveries.append(recovery)
            return recoveries.count == 1 ? .copy : .editAgain
        }
        pane.editQueued(prompt)
        try await wait { recoveries.count == 1 && pane.composerWork.queueEdits.isEmpty }
        XCTAssertEqual(recoveries.first?.latest?.text, "Other client")
        XCTAssertTrue(recoveries.first?.reason.contains("changed elsewhere") == true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "My edit")
        XCTAssertEqual(pane.surface.composer.string, "My composer draft", "The composer's draft is untouched")
        XCTAssertEqual(backend.snapshot.queuedPrompts?.map(\.text), ["Other client"], "The latest version is kept")
        XCTAssertEqual(backend.deliveries, 0)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testEditAgainRebasesOntoTheLatestVersion() async throws {
        let backend = QueueBackend()
        let prompt = queuedPrompt(backend, text: "Original")
        let pane = try await connected(backend)
        defer { pane.dispose() }
        var presented: [AgentQueuedPromptEdit] = []
        pane.composerWork.presentQueuedEditor = { edit in
            presented.append(edit)
            if presented.count == 1 { backend.editElsewhere(prompt.id, text: "Other client") }
            var edited = edit
            if presented.count == 1 { edited.text = "My edit" }
            return edited
        }
        pane.composerWork.chooseQueueEditRecovery = { _ in .editAgain }
        pane.editQueued(prompt)
        try await wait { backend.snapshot.queuedPrompts?.first?.text == "My edit" && pane.composerWork.queueEdits.isEmpty }
        XCTAssertEqual(presented.count, 2)
        XCTAssertEqual(presented.last?.text, "My edit", "The reopened editor holds the user's edit")
        XCTAssertEqual(presented.last?.baseRevision, 1)
        XCTAssertEqual(backend.deliveries, 0)
    }

    func testASaveWhoseReplyWasLostIsRecognizedWithoutRetrying() async throws {
        let backend = QueueBackend()
        let prompt = queuedPrompt(backend, text: "Original")
        let pane = try await connected(backend)
        defer { pane.dispose() }
        pane.composerWork.presentQueuedEditor = { edit in
            var edited = edit
            edited.text = "Saved once"
            return edited
        }
        pane.composerWork.chooseQueueEditRecovery = { _ in XCTFail("A saved edit needs no recovery"); return .keep }
        backend.dropNextReply = true
        pane.editQueued(prompt)
        try await wait { pane.composerWork.queueEdits.isEmpty && pane.notice != nil }
        XCTAssertEqual(backend.snapshot.queuedPrompts?.map(\.text), ["Saved once"])
        XCTAssertEqual(backend.requests.filter { if case .editQueued = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(backend.deliveries, 0)
        XCTAssertEqual(pane.notice?.text, "The queued prompt's edit was saved.")
    }

    // MARK: C4

    func testReplacingAQueuedScreenshotKeepsTheOriginalUntilTheRetrySucceeds() async throws {
        let backend = QueueBackend()
        let first = AgentChatAttachment(name: "First.png", mimeType: "image/png", data: Data([1]))
        let second = AgentChatAttachment(name: "Second.png", mimeType: "image/png", data: Data([2]))
        let prompt = queuedPrompt(backend, text: "Compare", attachments: [first, second])
        let pane = try await connected(backend)
        defer { pane.dispose() }
        let replacement = AgentDraftAttachment(name: "Replacement.png", mimeType: "image/png", data: Data([3]))
        var presented: [AgentQueuedPromptEdit] = []
        pane.composerWork.presentQueuedEditor = { edit in
            presented.append(edit)
            var edited = edit
            if presented.count == 1 { XCTAssertNil(edited.add([replacement], replacing: second.id)) }
            return edited
        }
        var recovery: AgentQueuedEditRecovery?
        pane.composerWork.chooseQueueEditRecovery = { recovery = $0; return .keep }
        backend.failNextEdit = NSError(domain: "Offline", code: 1)
        pane.editQueued(prompt)
        try await wait { recovery != nil && pane.notice != nil }
        XCTAssertEqual(backend.snapshot.queuedPrompts?.first?.attachments.map(\.name), ["First.png", "Second.png"])
        XCTAssertEqual(pane.composerWork.queueEdits[prompt.id]?.attachments.map(\.id), [first.id, replacement.id])
        XCTAssertTrue(pane.surface.promptQueue.unsavedEdits.contains(prompt.id))
        guard case .editQueuedPrompt(_, _, _, let edit) = backend.requests.last(where: {
            if case .editQueuedPrompt = $0 { return true }; return false
        }) else { return XCTFail("Expected a whole-prompt edit") }
        XCTAssertEqual(edit.keptAttachments, [first.id])
        XCTAssertEqual(edit.addedAttachments.map(\.data), [replacement.data])

        // The retry resumes the kept edit and replaces the screenshot.
        let latest = try XCTUnwrap(pane.snapshot?.queuedPrompts?.first)
        pane.editQueued(latest)
        try await wait { pane.composerWork.queueEdits.isEmpty }
        XCTAssertEqual(presented.last?.attachments.map(\.id), [first.id, replacement.id])
        XCTAssertEqual(backend.snapshot.queuedPrompts?.first?.attachments.map(\.name), ["First.png", "Replacement.png"])
        XCTAssertEqual(backend.payloads[prompt.id]?.attachments.last?.data, replacement.data)
        XCTAssertEqual(backend.deliveries, 0)
    }

    func testAnAttachmentOnlyQueuedPromptCannotBeSavedEmpty() async throws {
        let backend = QueueBackend()
        let only = AgentChatAttachment(name: "Only.png", mimeType: "image/png", data: Data([9]))
        let prompt = queuedPrompt(backend, text: "", attachments: [only])
        let pane = try await connected(backend)
        defer { pane.dispose() }
        pane.composerWork.presentQueuedEditor = { edit in
            var edited = edit
            edited.remove(only.id)
            return edited
        }
        let before = backend.requests.count
        pane.editQueued(prompt)
        try await wait { pane.notice != nil }
        XCTAssertEqual(pane.notice?.text, AgentQueuedEdit.emptyPromptMessage)
        XCTAssertEqual(backend.requests.count, before, "Nothing is sent")
        XCTAssertNotNil(pane.composerWork.queueEdits[prompt.id], "The edit stays to finish")
        // Adding text to the attachment-only prompt is a whole-prompt edit.
        var described = AgentQueuedPromptEdit(prompt: prompt)
        described.text = "Describe it"
        guard case .editQueued = described.request(session: backend.session, settings: nil) else { return XCTFail("Text-only edits stay compatible") }
        var blank = AgentQueuedPromptEdit(prompt: prompt)
        blank.text = ""
        guard case .editQueuedPrompt = blank.request(session: backend.session, settings: nil) else { return XCTFail("An attachment-only prompt has no text to send") }
    }

    // MARK: C5

    func testSendNowSteersTheRunningTurnOnce() async throws {
        let backend = QueueBackend()
        backend.snapshot.status = .working
        let pane = try await connected(backend)
        defer { pane.dispose() }
        pane.surface.composer.string = "Change direction"
        pane.updateControls()
        XCTAssertTrue(pane.surface.offersSendNow)
        XCTAssertTrue(pane.surface.sendNow.isEnabled)
        pane.sendNow()
        try await wait { pane.notice?.text == "Sent." }
        XCTAssertEqual(backend.submissions.count, 1)
        XCTAssertEqual(backend.deliveries, 1)
        XCTAssertEqual(backend.userTexts, ["Change direction"])
        XCTAssertTrue(pane.surface.composer.string.isEmpty)
        // Return still queues.
        pane.surface.composer.string = "Later"
        pane.send()
        try await wait { backend.submissions.count == 2 }
        XCTAssertEqual(backend.deliveries, 1)
        XCTAssertEqual(backend.snapshot.queuedPrompts?.map(\.text), ["Later"])
    }

    func testSendNowWhileWaitingForApprovalQueues() async throws {
        let backend = QueueBackend()
        backend.snapshot.status = .waiting
        let pane = try await connected(backend)
        defer { pane.dispose() }
        pane.surface.composer.string = "After the approval"
        pane.updateControls()
        XCTAssertFalse(pane.surface.sendNow.isEnabled)
        XCTAssertTrue(pane.surface.sendNow.toolTip?.contains("waiting") == true)
        pane.sendNow()
        try await wait { backend.submissions.count == 1 && pane.commandTask == nil }
        XCTAssertEqual(backend.deliveries, 0)
        XCTAssertEqual(backend.snapshot.queuedPrompts?.map(\.text), ["After the approval"])
        XCTAssertTrue(pane.notice?.text.contains("waiting for an answer") == true)
    }

    func testSendNowIsOffWhileReconnecting() async throws {
        let backend = QueueBackend()
        backend.snapshot.status = .working
        let pane = try await connected(backend)
        defer { pane.dispose() }
        pane.surface.composer.string = "Not yet"
        backend.gateNextRead = true
        pane.connectionChanged()
        XCTAssertFalse(pane.surface.sendNow.isEnabled)
        pane.sendNow()
        XCTAssertTrue(backend.submissions.isEmpty)
        try await wait { backend.readGate != nil }
        backend.readGate?.resume()
        try await wait { !pane.needsAuthoritativeSnapshot }
        XCTAssertTrue(pane.surface.sendNow.isEnabled)
    }

    func testATurnEndingBetweenClickAndDispatchDeliversOnceAndSaysSo() async throws {
        let backend = QueueBackend()
        backend.snapshot.status = .working
        let pane = try await connected(backend)
        defer { pane.dispose() }
        backend.endTurnBeforeDelivery = true
        pane.surface.composer.string = "Just in time"
        pane.sendNow()
        try await wait { pane.notice?.text == "The turn had ended, so the prompt was sent as the next message." }
        XCTAssertEqual(backend.userTexts, ["Just in time"])
        XCTAssertEqual(backend.submissions.count, 1)
        XCTAssertNil(pane.composerWork.sendNow)

        // A refused steer leaves the prompt queued, and the notice says so.
        backend.completeDeliveries = false
        backend.snapshot.status = .working
        backend.snapshot.revision += 1
        pane.surface.composer.string = "Second"
        pane.sendNow()
        try await wait { backend.deliveries == 2 && pane.commandTask == nil }
        // The provider refused it: the prompt is back in the queue, held.
        if let index = backend.snapshot.queuedPrompts?.firstIndex(where: { $0.text == "Second" }) {
            backend.snapshot.queuedPrompts?[index].state = .queued
            backend.snapshot.queuedPrompts?[index].revision += 1
        }
        backend.snapshot.queuePaused = true
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.notice?.text.hasPrefix("Couldn't send it now") == true }
        XCTAssertEqual(backend.userTexts, ["Just in time"])
    }

    func testSendNowShortcutComesFromTheCatalog() throws {
        XCTAssertEqual(Keymap().action(for: try KeyChord("cmd-alt-enter")), .sendAgentPromptNow)
        let pane = QueueBackend().controller()
        defer { pane.dispose() }
        XCTAssertFalse(pane.performConversationShortcut(.sendAgentPromptNow), "Without the composer's focus the key goes on")
    }

    // MARK: C6

    func testStashedDraftSurvivesRestartAndRestoresOnlyWhenChosen() async throws {
        let backend = QueueBackend()
        let url = draftURL()
        let first = try await connected(backend, draft: url)
        let quoted = NSMutableAttributedString(string: "Compare with ")
        quoted.append(NSAttributedString(string: "the earlier answer", attributes: [.agentAssistantCitation: "tab-citation://quote"]))
        first.surface.composer.textStorage?.setAttributedString(quoted)
        let kept = text("Notes.txt", "kept notes")
        let lost = AgentDraftAttachment(name: "Lost.png", mimeType: "image/png", data: Data([7, 7, 7, 7, 7]))
        first.draftAttachments = [kept, lost]
        first.updateAttachments()
        let comment = AgentReviewComment(checkpoint: UUID().uuidString, path: "a.swift", old: false, firstLine: 1, lastLine: 2,
                                         source: "let a = 1", text: "Rename this")
        first.reviewComments = [comment]
        var stashed = false
        first.stashDraft { stashed = true }
        try await wait { stashed }
        XCTAssertTrue(first.surface.composer.string.isEmpty)
        XCTAssertTrue(first.draftAttachments.isEmpty)
        XCTAssertTrue(first.reviewComments.isEmpty)
        try await first.flushDraft()
        first.dispose()

        let stash = AgentDraftStash(draftURL: url)
        let entries = try await stash.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.settings?.provider, "claude")
        // One attachment's bytes go missing while the app is closed.
        let files = try FileManager.default.contentsOfDirectory(at: stash.directory.appendingPathComponent(entry.id), includingPropertiesForKeys: [.fileSizeKey])
        for file in files where (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == lost.data.count {
            try FileManager.default.removeItem(at: file)
        }

        let second = try await connected(backend, draft: url)
        defer { second.dispose() }
        XCTAssertTrue(second.surface.composer.string.isEmpty, "The stashed draft is not the pane's draft")
        second.surface.composer.string = "Second draft"
        var asked = 0
        second.composerWork.chooseStashRestore = { offered in
            asked += 1
            XCTAssertEqual(offered.id, entry.id)
            XCTAssertEqual(second.surface.composer.string, "Second draft", "Both drafts are kept until the choice")
            return .merge
        }
        var restored = false
        second.restoreStash(entry.id) { restored = true }
        try await wait { restored }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(second.surface.composer.string, "Second draft\n\nCompare with the earlier answer")
        let storage = try XCTUnwrap(second.surface.composer.textStorage)
        let location = (storage.string as NSString).range(of: "the earlier answer").location
        XCTAssertEqual(storage.attribute(.agentAssistantCitation, at: location, effectiveRange: nil) as? String, "tab-citation://quote")
        XCTAssertEqual(second.draftAttachments.map(\.name), ["Notes.txt"])
        XCTAssertEqual(second.draftAttachments.first?.data, kept.data)
        XCTAssertEqual(second.reviewComments, [comment])
        XCTAssertEqual(second.notice?.kind, .warning)
        XCTAssertTrue(second.notice?.text.contains("Lost.png") == true)
        let remaining = try await stash.list()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(backend.submissions.isEmpty, "Restoring never sends")

        // Replace sets the current draft aside rather than losing it.
        var again = false
        second.stashDraft { again = true }
        try await wait { again }
        let stashedAgain = try await stash.list()
        let replaced = try XCTUnwrap(stashedAgain.first)
        second.surface.composer.string = "Third draft"
        second.composerWork.chooseStashRestore = { _ in .replace }
        restored = false
        second.restoreStash(replaced.id) { restored = true }
        try await wait { restored }
        XCTAssertEqual(second.surface.composer.string, "Second draft\n\nCompare with the earlier answer")
        let swapped = try await stash.list()
        XCTAssertEqual(swapped.map(\.draft.text), ["Third draft"])
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    // MARK: C7

    func testDismissingTheOptimizationNoticeCancelsIt() async throws {
        let backend = QueueBackend()
        let pane = try await connected(backend)
        defer { pane.dispose() }
        let gate = ImportGate()
        let earlier = text("Earlier.txt")
        pane.prepareAttachments { await gate.wait(); return AgentAttachmentIntake(attachments: [earlier]) }
        pane.composerWork.confirmImageOptimization = { _ in true }
        pane.offerOptimizedCopies([.data(Data(repeating: 1, count: 64), name: "Huge.png")])
        try await wait { pane.notice?.kind == .progress }
        XCTAssertTrue(pane.notice?.text.contains("Huge.png") == true)
        pane.dismissNoticePressed()
        XCTAssertNil(pane.notice)
        await gate.release()
        try await wait { pane.composerWork.imports.isEmpty && pane.preparingAttachments == 0 }
        XCTAssertEqual(pane.draftAttachments.map(\.name), ["Earlier.txt"])
        XCTAssertNil(pane.notice, "A cancelled optimization reports no error")
    }
}
