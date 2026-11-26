import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentPaneTests: XCTestCase {
    func testClearUsesSameSessionAndNeverOpensANewPane() async throws {
        let backend = Backend()
        backend.snapshot.items = [.init(kind: .user, text: "Old conversation")]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.onNewConversation = { XCTFail("Clear must keep this pane") }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.composer.string = "/clear"
        pane.send()
        try await wait { pane.snapshot?.resetID != nil }
        XCTAssertEqual(pane.snapshot?.session, backend.session)
        XCTAssertTrue(pane.snapshot?.items.isEmpty == true)
        XCTAssertTrue(pane.surface.composer.string.isEmpty)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testInvalidLocalArgumentsStayInDraftAndNeverReachProvider() async throws {
        let backend = Backend()
        let controller = backend.controller()
        defer { controller.dispose() }
        controller.refresh()
        try await wait { controller.snapshot != nil }
        for text in ["/clear named", "/plan maybe", "/stop now", "/heapdump", "/effort unsupported"] {
            controller.surface.composer.string = text
            controller.send()
            XCTAssertEqual(controller.surface.composer.string, text)
        }
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testCopyFetchesAllEarlierPages() async throws {
        let backend = Backend()
        backend.snapshot.items = [.init(id: "latest", kind: .assistant, text: "Latest answer")]
        backend.snapshot.omittedItems = 2
        let pane = backend.controller()
        defer { pane.dispose() }
        var positions: [Int?] = []
        pane.conversationRequest = { request in
            guard case .earlier(_, let before, _) = request else { throw NSError(domain: "Unexpected", code: 1) }
            positions.append(before)
            return .earlier(.init(items: [.init(id: before == nil ? "middle" : "first", kind: .user,
                text: before == nil ? "Middle prompt" : "First prompt")], start: before == nil ? 1 : 0, total: 2))
        }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.copyConversation()
        try await wait { pane.notice?.text == "Copied the complete conversation as Markdown." }
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("First prompt")); XCTAssertTrue(copied.contains("Middle prompt")); XCTAssertTrue(copied.contains("Latest answer"))
        XCTAssertEqual(positions.count, 2)
    }

    private func modelItems(_ pane: AgentPaneController) -> [NSMenuItem] {
        pane.surface.model.itemArray.flatMap { $0.submenu?.items ?? [$0] }
    }

    func testModelMenuGroupsProvidersAndDispatchesSubmenuSelections() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.surface.model.isEnabled && self.modelItems(pane).contains { $0.title == "GPT-6 Astra" } }
        let root = try XCTUnwrap(pane.surface.model.menu)
        XCTAssertEqual(root.items.prefix(2).map(\.title), ["Claude Code", "Codex"])
        XCTAssertTrue(root.items.prefix(2).allSatisfy { $0.submenu != nil })
        let item = try XCTUnwrap(root.items[1].submenu?.items.first { $0.title == "GPT-6 Astra" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(pane.selection.provider, .codex)
        XCTAssertEqual(pane.selection.model, "gpt-6-astra")
        let selected = modelItems(pane).filter { $0.state == .on }
        XCTAssertEqual(selected.map(\.title), ["GPT-6 Astra"])
        XCTAssertEqual(pane.surface.model.labelText, "GPT-6 Astra")
    }

    @MainActor
    private final class Backend {
        let session = SessionId()
        let project = ProjectId()
        var requests: [AgentChatRequest] = []
        var submissions: [AgentPrompt] = []
        var failSend = false
        var failSendSnapshot = false
        var failCreate = false
        var closeError: Error?
        var readGate: CheckedContinuation<Void, Never>?
        var gateNextRead = false
        var sendGate: CheckedContinuation<Void, Never>?
        var gateNextSend = false
        var approvalGate: CheckedContinuation<Void, Never>?
        var gateNextApproval = false
        var failApproval = false
        lazy var snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, accessMode: .fullAccess)

        func request(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
            // Keep existing lifecycle fixtures shared by legacy send and durable submission.
            let operation: AgentChatRequest
            if case .submit(let session, let prompt) = request {
                submissions.append(prompt)
                operation = .send(session: session, text: prompt.text, model: prompt.model,
                                  reasoningEffort: prompt.effort, provider: prompt.provider, attachments: prompt.attachments.isEmpty ? nil : prompt.attachments)
            } else { operation = request }
            requests.append(operation)
            switch operation {
            case .submit, .editQueued, .editQueuedPrompt, .moveQueued, .removeQueued, .deliverQueued, .resumeQueue, .answer, .schedule,
                 .stop, .collect: break
            case .create, .fork:
                if failCreate { throw NSError(domain: "Offline", code: 1) }
            case .send(_, let text, let model, let effort, let provider, _, _):
                if gateNextSend {
                    gateNextSend = false
                    await withCheckedContinuation { sendGate = $0 }
                }
                if failSend { throw NSError(domain: "Send failed", code: 2) }
                snapshot.items.append(AgentChatItem(kind: .user, text: text))
                snapshot.model = model
                snapshot.reasoningEffort = effort
                snapshot.provider = provider ?? snapshot.provider
                snapshot.status = failSendSnapshot ? .failed : .working
                if failSendSnapshot {
                    snapshot.items.append(AgentChatItem(kind: .notice, text: "The selected model is unavailable."))
                }
                snapshot.revision += 1
            case .clear(_, let archive, _):
                snapshot.items = []; snapshot.providerSession = nil; snapshot.resetID = archive
                snapshot.contextUsage = nil; snapshot.omittedItems = nil; snapshot.revision += 1
            case .read:
                if gateNextRead {
                    gateNextRead = false
                    let beforeReconnect = snapshot
                    await withCheckedContinuation { readGate = $0 }
                    return beforeReconnect
                }
            case .decide(_, let id, let decision, _):
                if let index = snapshot.items.firstIndex(where: { $0.id == id }) {
                    snapshot.items[index].isComplete = true
                    let chosen = snapshot.items[index].approval?.decision(decision)
                    snapshot.items[index].approval?.outcome = .init(decision: decision, kind: chosen?.kind, title: chosen?.title ?? decision, source: .user)
                }
                snapshot.status = .working
                snapshot.revision += 1
            case .approve(_, let id, _, _, _):
                if gateNextApproval {
                    gateNextApproval = false
                    await withCheckedContinuation { approvalGate = $0 }
                }
                if failApproval { throw NSError(domain: "Approval failed", code: 3) }
                if let index = snapshot.items.firstIndex(where: { $0.id == id }) {
                    snapshot.items[index].isComplete = true
                }
                snapshot.status = .working
                snapshot.revision += 1
            case .interrupt:
                snapshot.status = .idle
                snapshot.revision += 1
            case .setPlan(_, let enabled):
                snapshot.planMode = enabled
                snapshot.revision += 1
                return snapshot
            case .setAccess(_, let mode):
                snapshot.accessMode = mode
                snapshot.revision += 1
            case .close:
                if let closeError { throw closeError }
                snapshot.status = .closed
            }
            return snapshot
        }

        func controller() -> AgentPaneController {
            let pane = AgentPaneController(session: session, project: project, provider: .claude) { [self] in
                try await request($0)
            }
            pane.loadProviders = {
                AgentProvidersState(settings: AgentProviderSettings(providers: [.builtIn(.claude), .builtIn(.codex)]))
            }
            pane.loadModelCatalog = { provider, _ in
                let options: [(String, String)] = provider.kind == .claude
                    ? [("claude-sonnet-5-5", "Claude Sonnet 5.5"), ("claude-opus-5-5", "Claude Opus 5.5")]
                    : [("gpt-6.1-sol", "GPT-6.1 Sol"), ("gpt-6-astra", "GPT-6 Astra")]
                return .init(models: options.map { .init(id: $0.0, title: $0.1, reasoningEfforts: [.low, .medium, .high, .max],
                                                         defaultReasoningEffort: .medium) }, source: "live")
            }
            return pane
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Agent pane did not settle")
    }

    func testAmbiguousRetryKeepsIdentityAcrossAuthoritativeSettingChanges() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        backend.failSend = true
        pane.surface.composer.string = "Exactly once"
        pane.send()
        try await wait { backend.submissions.count == 1 && pane.surface.send.isEnabled }
        let first = try XCTUnwrap(backend.submissions.first)
        backend.snapshot.model = "server-selected-model"
        backend.snapshot.planMode = true
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.planMode == true }
        pane.send()
        try await wait { backend.submissions.count == 2 && pane.surface.send.isEnabled }
        XCTAssertEqual(backend.submissions[1], first, "Refreshing settings must not turn an ambiguous retry into a new execution")
        pane.selectModel(provider: .claude, model: "explicit-new-choice")
        pane.send()
        try await wait { backend.submissions.count == 3 && pane.surface.send.isEnabled }
        XCTAssertNotEqual(backend.submissions[2].id, first.id)
    }

    func testConversationTitleReachesThePaneTitleLikeATerminalsDoes() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        var titles: [String] = []
        pane.onTitleChange = { titles.append($0) }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertEqual(titles.last, "Agent")
        XCTAssertNotNil(pane.icon)
        pane.surface.composer.string = "Fix the sidebar spinner\nand its tests"
        pane.send()
        try await wait { titles.last == "Fix the sidebar spinner" }
    }

    func testFailedSendRetainsDraftAndRetrySendsExactlyOnceWithDefaultModel() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.composer.string = "Please fix this\nwithout losing my draft"
        backend.failSend = true
        pane.send()
        pane.send()
        try await wait { pane.errorMessage != nil }
        XCTAssertEqual(pane.surface.composer.string, "Please fix this\nwithout losing my draft")
        XCTAssertEqual(backend.requests.filter { if case .send = $0 { return true }; return false }.count, 1)
        backend.failSend = false
        pane.send()
        try await wait { pane.surface.composer.string.isEmpty }
        XCTAssertNil(backend.snapshot.model)
        XCTAssertEqual(backend.snapshot.items.count, 1)
        XCTAssertFalse(pane.surface.send.isEnabled)
        XCTAssertTrue(pane.surface.stop.isEnabled)
    }

    func testAttachmentOnlySendTransfersBytesAndFailedSendKeepsDraft() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agent-attachment-\(UUID()).txt")
        let bytes = Data("Attached context from the client machine".utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        pane.attachFiles([file])
        try await wait { pane.surface.send.isEnabled }
        XCTAssertEqual(pane.draftAttachments.count, 1)
        backend.failSend = true
        pane.send()
        try await wait { pane.errorMessage != nil }
        XCTAssertEqual(pane.draftAttachments.first?.data, bytes)
        guard case .send(_, let text, _, _, _, let attachments, _) = backend.requests.last else { return XCTFail("Missing send") }
        XCTAssertEqual(text, "")
        XCTAssertEqual(attachments?.first?.data, bytes)
        XCTAssertEqual(attachments?.first?.name, file.lastPathComponent)
        backend.failSend = false
        pane.send()
        try await wait { pane.draftAttachments.isEmpty }
        XCTAssertEqual(backend.requests.filter { if case .send = $0 { return true }; return false }.count, 2)
    }

    func testSlashActionDoesNotSendAProviderMessage() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.composer.string = "/clear-draft"
        pane.send()
        XCTAssertTrue(pane.surface.composer.string.isEmpty)
        XCTAssertFalse(backend.requests.contains { if case .send = $0 { return true }; return false })
    }

    /// A hint raised while the agent streams used to vanish with the next snapshot, about
    /// 100 ms later; it now stays until dismissed and never offers Refresh.
    func testComposerNoticeSurvivesStreamingSnapshotsAndIsDismissible() async throws {
        let backend = Backend()
        backend.snapshot.status = .working
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.togglePlanMode()
        let hint = "Stop the current response before changing plan mode."
        XCTAssertEqual(pane.notice?.text, hint)
        backend.snapshot.items.append(.init(kind: .assistant, text: "Streaming…", isComplete: false))
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.revision == backend.snapshot.revision }
        XCTAssertEqual(pane.surface.feedback.stringValue, hint)
        XCTAssertTrue(pane.surface.retry.isHidden, "Refresh can't fix a validation hint")
        XCTAssertFalse(pane.surface.dismissNotice.isHidden)
        pane.surface.dismissNotice.perform()
        XCTAssertNil(pane.notice)
        XCTAssertNotEqual(pane.surface.feedback.stringValue, hint)
        XCTAssertTrue(pane.surface.dismissNotice.isHidden)
    }

    /// Escape stops the agent the way the Stop button does, and only when nothing else wants the key.
    func testEscapeStopsOnlyWhileWorkingAndNothingElseClaimsTheKey() async throws {
        _ = NSApplication.shared
        XCTAssertEqual(Keymap().action(for: try KeyChord("escape")), .stopAgent)
        let backend = Backend()
        backend.snapshot.status = .working
        backend.snapshot.revision = 2
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.keyDisplay = { $0 == .stopAgent ? "⎋" : nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let outside = NSTextField(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let root = NSView(frame: window.contentLayoutRect)
        pane.surface.frame = root.bounds
        root.addSubview(pane.surface)
        root.addSubview(outside)
        window.contentView = root
        defer { window.close() }
        pane.refresh()
        try await wait { pane.snapshot?.status == .working && pane.surface.stop.isEnabled }
        XCTAssertEqual(pane.surface.stop.toolTip, "Stop this turn (⎋)", "The tooltip names the key from the keymap")
        func interrupts() -> Int { backend.requests.filter { $0 == .interrupt(session: backend.session) }.count }

        window.makeFirstResponder(outside)
        XCTAssertFalse(pane.performConversationShortcut(.stopAgent), "Focus outside the pane")
        window.makeFirstResponder(pane.surface.composer)
        pane.surface.suggestions.isHidden = false
        XCTAssertFalse(pane.performConversationShortcut(.stopAgent), "The suggestion list closes first")
        pane.surface.suggestions.isHidden = true
        pane.surface.selectionToolbar.isHidden = false
        XCTAssertFalse(pane.performConversationShortcut(.stopAgent), "The selection toolbar hides first")
        pane.surface.selectionToolbar.isHidden = true
        pane.surface.composer.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(pane.performConversationShortcut(.stopAgent), "An input method's text is cancelled first")
        pane.surface.composer.unmarkText()
        XCTAssertTrue(pane.surface.performFind(.open))
        window.makeFirstResponder(pane.surface.composer)
        XCTAssertFalse(pane.performConversationShortcut(.stopAgent), "Find closes first")
        XCTAssertTrue(pane.surface.performFind(.close))
        XCTAssertEqual(interrupts(), 0)

        window.makeFirstResponder(pane.surface.composer)
        XCTAssertTrue(pane.performConversationShortcut(.stopAgent))
        try await wait { interrupts() == 1 }
        try await wait { pane.snapshot?.status == .idle }
        XCTAssertFalse(pane.performConversationShortcut(.stopAgent), "Nothing to stop: the key goes on")
        XCTAssertEqual(interrupts(), 1)
    }

    func testRetrySendsTheFailedTurnsPromptAgainAsANewPromptWithItsAttachments() async throws {
        let backend = Backend()
        let file = AgentChatAttachmentDescriptor(id: "a1", name: "notes.txt", mimeType: "text/plain", byteCount: 5)
        backend.snapshot.items = [.init(id: "u1", kind: .user, text: "Build it", attachments: [file]),
                                  .init(kind: .notice, text: "Model overloaded")]
        backend.snapshot.turns = [AgentChatTurn(userItemID: "u1", startedAt: Date(timeIntervalSinceNow: -5), completedAt: Date(),
                                                status: .failed, outcome: .failed)]
        backend.snapshot.status = .failed
        backend.snapshot.revision = 3
        let pane = backend.controller()
        defer { pane.dispose() }
        var fetches = 0
        pane.surface.fetchAttachment = { item, descriptor in
            fetches += 1
            XCTAssertEqual(item, "u1"); XCTAssertEqual(descriptor, file)
            return Data("hello".utf8)
        }
        pane.refresh()
        try await wait { pane.snapshot != nil && !pane.surface.retryTurn.isHidden }
        XCTAssertTrue(pane.surface.feedback.stringValue.hasPrefix("Turn failed"))
        XCTAssertTrue(pane.surface.retryTurn.isEnabled)
        pane.surface.retryTurn.perform()
        try await wait { backend.submissions.count == 1 }
        let prompt = try XCTUnwrap(backend.submissions.first)
        XCTAssertEqual(prompt.text, "Build it")
        XCTAssertNotEqual(prompt.id, "u1", "A retry is a new submission")
        XCTAssertEqual(prompt.attachments.map(\.data), [Data("hello".utf8)])
        XCTAssertEqual(prompt.attachments.map(\.name), ["notes.txt"])
        XCTAssertEqual(fetches, 1)
    }

    func testRetryIsDisabledWithAReasonWhenAttachmentsAreGone() async throws {
        let backend = Backend()
        backend.snapshot.items = [.init(id: "u1", kind: .user, text: "Look", attachments: [
            AgentChatAttachmentDescriptor(id: "a1", name: "shot.png", mimeType: "image/png", byteCount: 5)])]
        backend.snapshot.turns = [AgentChatTurn(userItemID: "u1", startedAt: Date(timeIntervalSinceNow: -5), completedAt: Date(),
                                                status: .idle, outcome: .interrupted)]
        backend.snapshot.revision = 3
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.surface.fetchAttachment = { _, _ in throw ModelError("expired") }
        pane.refresh()
        try await wait { !pane.surface.retryTurn.isHidden }
        XCTAssertEqual(pane.surface.feedback.stringValue, "Stopped", "A stopped turn can be retried too")
        pane.surface.retryTurn.perform()
        try await wait { pane.surface.retryTurn.toolTip?.hasPrefix("Can't retry") == true }
        XCTAssertFalse(pane.surface.retryTurn.isEnabled)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testEditAsNewPromptAddsToTheDraftWithoutSending() async throws {
        let backend = Backend()
        backend.snapshot.items = [.init(id: "u1", kind: .user, text: "Rename the type"), .init(kind: .assistant, text: "Done")]
        backend.snapshot.revision = 2
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        let message = try XCTUnwrap(pane.snapshot?.items.first)
        pane.editAsNewPrompt(message)
        XCTAssertEqual(pane.surface.composer.string, "Rename the type")
        pane.surface.composer.string = "Keep this"
        pane.editAsNewPrompt(message)
        XCTAssertEqual(pane.surface.composer.string, "Keep this\n\nRename the type", "A draft is added to, never replaced")
        XCTAssertTrue(backend.submissions.isEmpty)
        XCTAssertFalse(backend.requests.contains { if case .send = $0 { return true }; return false })
    }

    func testUpdatesReadOnlyWhatChangedAndFallBackToFullReads() async throws {
        let backend = Backend()
        backend.snapshot.items = [.init(id: "u", kind: .user, text: "Go"), .init(id: "a", kind: .assistant, text: "Wor", isComplete: false)]
        backend.snapshot.status = .working
        backend.snapshot.revision = 3
        let pane = backend.controller()
        defer { pane.dispose() }
        var sinceReads: [UInt64] = []
        pane.conversationRequest = { request in
            guard case .readSince(_, let revision) = request else { throw ModelError("unexpected") }
            sinceReads.append(revision)
            var changed = backend.snapshot
            changed.items = changed.items.filter { $0.id == "a" }
            return .delta(AgentChatDelta(snapshot: changed, since: revision, itemIDs: backend.snapshot.items.map(\.id)))
        }
        pane.refresh()
        try await wait { pane.snapshot?.revision == 3 }
        func fullReads() -> Int { backend.requests.filter { $0 == .read(session: backend.session) }.count }
        let readsBefore = fullReads()
        backend.snapshot.items[1].text = "Working"
        backend.snapshot.revision = 4
        pane.sessionChanged(session: backend.session, revision: 4)
        try await wait { pane.snapshot?.items.last?.text == "Working" }
        XCTAssertEqual(sinceReads, [3])
        XCTAssertEqual(fullReads(), readsBefore, "A streamed update reads only what changed")

        // A reply that doesn't fit what the pane holds falls back to a full read.
        pane.conversationRequest = { _ in .delta(AgentChatDelta(snapshot: backend.snapshot, since: 1, itemIDs: ["missing"])) }
        backend.snapshot.revision = 5
        pane.sessionChanged(session: backend.session, revision: 5)
        try await wait { pane.snapshot?.revision == 5 }
        XCTAssertEqual(fullReads(), readsBefore + 1)

        // An older server says it can't; the pane remembers that for the connection.
        var asked = 0
        pane.conversationRequest = { _ in asked += 1; throw ClientError.server(ErrorReply(code: .unsupported, message: "")) }
        for revision in [6, 7] as [UInt64] {
            backend.snapshot.revision = revision
            pane.sessionChanged(session: backend.session, revision: revision)
            try await wait { pane.snapshot?.revision == revision }
        }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(fullReads(), readsBefore + 3)

        // A reconnect always starts again from a full read.
        pane.connectionChanged()
        try await wait { fullReads() == readsBefore + 4 }
        XCTAssertEqual(asked, 1)
    }

    func testContextPopoverCompactsThroughTheProviderCommandWhenItHasOne() async throws {
        let backend = Backend()
        backend.snapshot.revision = 2
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertNotNil(pane.surface.contextIndicator.onCompact, "Built-in compaction is available before the first provider turn")
        backend.snapshot.commands = ["compact"]
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.surface.contextIndicator.onCompact != nil }
        pane.surface.composer.string = "My draft"
        pane.surface.contextIndicator.onCompact?()
        try await wait { backend.submissions.count == 1 }
        XCTAssertEqual(backend.submissions.first?.text, "/compact")
        XCTAssertEqual(pane.surface.composer.string, "My draft", "The draft is left alone")
    }

    func testUpRecallsEarlierPromptsAndDownWalksBack() async throws {
        let backend = Backend()
        backend.snapshot.items = [.init(id: "1", kind: .user, text: "First"), .init(kind: .assistant, text: "A"),
                                  .init(id: "2", kind: .user, text: "Second"), .init(kind: .assistant, text: "B")]
        backend.snapshot.revision = 2
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        let composer = pane.surface.composer
        let up = #selector(NSResponder.moveUp(_:)), down = #selector(NSResponder.moveDown(_:))
        XCTAssertTrue(pane.textView(composer, doCommandBy: up))
        XCTAssertEqual(composer.string, "Second")
        XCTAssertTrue(pane.textView(composer, doCommandBy: up))
        XCTAssertEqual(composer.string, "First")
        XCTAssertTrue(pane.textView(composer, doCommandBy: up), "The oldest stays")
        XCTAssertEqual(composer.string, "First")
        XCTAssertTrue(pane.textView(composer, doCommandBy: down))
        XCTAssertEqual(composer.string, "Second")
        XCTAssertTrue(pane.textView(composer, doCommandBy: down))
        XCTAssertEqual(composer.string, "", "Past the newest clears the composer")
        composer.string = "Typed"
        XCTAssertFalse(pane.textView(composer, doCommandBy: up), "A draft keeps Up for moving the caret")
        composer.string = ""
        XCTAssertTrue(pane.textView(composer, doCommandBy: up))
        composer.string = "Second, edited"
        XCTAssertFalse(pane.textView(composer, doCommandBy: up), "Editing ends the walk")
        composer.string = ""
        composer.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(pane.textView(composer, doCommandBy: up), "Not while an input method composes")
    }

    func testPlanChipShowsWhenOffAndSlashPlanTogglesIt() async throws {
        let backend = Backend()
        backend.snapshot.revision = 2
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertFalse(pane.surface.plan.isHidden, "The plan switch is visible while off")
        XCTAssertFalse(pane.surface.plan.active)
        pane.surface.composer.string = "/plan"
        pane.send()
        try await wait { pane.snapshot?.planMode == true }
        XCTAssertTrue(pane.surface.plan.active)
        XCTAssertEqual(pane.surface.plan.accessibilityLabel(), "Disable plan mode")
    }

    func testAModelChosenWhileWorkingGoesWithTheNextPrompt() async throws {
        let backend = Backend()
        backend.snapshot.status = .working
        backend.snapshot.revision = 2
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil && pane.surface.model.isEnabled }
        pane.selectModel(provider: .claude, model: "claude-opus-5-5")
        XCTAssertEqual(pane.selection.model, "claude-opus-5-5")
        pane.surface.composer.string = "Next, with Opus"
        pane.send()
        try await wait { backend.submissions.count == 1 }
        XCTAssertEqual(backend.submissions.first?.model, "claude-opus-5-5")
    }

    func testApprovalShortcutsAnswerTheOldestPendingApproval() async throws {
        let backend = Backend()
        backend.snapshot.status = .waiting
        backend.snapshot.items = [.init(id: "first", kind: .approval, text: "Run", isComplete: false),
                                  .init(id: "second", kind: .approval, text: "Write", isComplete: false)]
        let pane = backend.controller()
        defer { pane.dispose() }
        var answered: [(String, Bool)] = []
        pane.surface.onApproval = { answered.append(($0, $1)) }
        XCTAssertFalse(pane.performConversationShortcut(.allowAgentApproval), "Nothing is known yet")
        pane.refresh()
        try await wait { pane.snapshot?.items.count == 2 }
        XCTAssertTrue(pane.performConversationShortcut(.denyAgentApproval))
        XCTAssertEqual(answered.first?.0, "first")
        XCTAssertEqual(answered.first?.1, false)
    }

    func testRequestErrorOffersRefreshAndClearsOnTheNextAcceptedSnapshot() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        backend.failSend = true
        pane.surface.composer.string = "Hello"
        pane.send()
        try await wait { pane.errorMessage != nil }
        XCTAssertFalse(pane.surface.retry.isHidden)
        XCTAssertTrue(pane.surface.dismissNotice.isHidden)
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.errorMessage == nil }
        XCTAssertTrue(pane.surface.retry.isHidden)
        XCTAssertEqual(pane.surface.composer.string, "Hello", "The failed draft is retained")
    }

    func testStatusIsAnInformationalNoticeThatExpires() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.infoNoticeLifetime = .milliseconds(60)
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.composer.string = "/status"
        pane.send()
        XCTAssertEqual(pane.notice?.kind, .info)
        XCTAssertNil(pane.errorMessage, "/status is not an error")
        XCTAssertTrue(pane.surface.retry.isHidden)
        XCTAssertTrue(pane.surface.feedback.stringValue.hasPrefix("Claude Code"))
        try await wait { pane.notice == nil }
        XCTAssertFalse(pane.surface.feedback.stringValue.hasPrefix("Claude Code"))
        // A warning that replaced an expiring notice is not taken down by the old timer.
        pane.surface.composer.string = "/status"
        pane.send()
        backend.snapshot.status = .working
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.status == .working }
        pane.togglePlanMode()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(pane.notice?.kind, .warning)
    }

    func testProviderContextAndResolvedModelReachCompactControlsWithoutChangingSettings() async throws {
        let backend = Backend()
        backend.snapshot.resolvedModel = "claude-sonnet-5-5"
        backend.snapshot.contextUsage = .init(usedTokens: 42_000, contextWindow: 200_000)
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertNil(pane.selection.model, "A resolved provider model is display metadata, not a settings override")
        XCTAssertEqual(pane.surface.model.labelText, "Claude Sonnet 5.5")
        XCTAssertFalse(modelItems(pane).contains {
            guard let choice = $0.representedObject as? AgentModelSelection else { return false }
            return choice.model == nil
        })
        XCTAssertEqual(pane.surface.contextIndicator.fractionUsed ?? -1, 0.21, accuracy: 0.001)
        XCTAssertTrue(pane.surface.feedback.isHidden)
        XCTAssertEqual(pane.surface.modelPicker.frame.width, pane.surface.modelPicker.intrinsicContentSize.width)
        XCTAssertTrue(pane.surface.modelPicker.labelText.hasPrefix("Claude Sonnet 5.5"))
        backend.snapshot.contextUsage = .init(usedTokens: 123)
        pane.refresh()
        try await wait { pane.surface.contextIndicator.usedTokens == 123 }
        XCTAssertNil(pane.surface.contextIndicator.fractionUsed, "Unknown capacity must not produce a fabricated percentage")
    }

    func testDiscoveredModelsAndNewReasoningValuesNeedNoAppRelease() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.loadModelCatalog = { provider, _ in
            guard provider.kind == .codex else { return .init(models: []) }
            return .init(models: [.init(id: "future-codex-model", title: "Future Codex Model",
                                        reasoningEfforts: [.low, .high, .init(rawValue: "next-generation")], defaultReasoningEffort: .low)],
                         source: "live")
        }
        pane.refresh()
        try await wait { pane.snapshot != nil && modelItems(pane).map(\.title).contains("Future Codex Model") }
        XCTAssertFalse(modelItems(pane).map(\.title).contains("GPT-6 Astra"), "Only provider-discovered models belong in the menu")
        pane.selectModel(provider: .codex, model: "future-codex-model")
        XCTAssertEqual(pane.surface.model.labelText, "Future Codex Model")
        XCTAssertEqual(pane.surface.effort.itemTitles, ["Auto", "Low", "High", AgentReasoningEffort(rawValue: "next-generation").title])
        XCTAssertEqual(pane.surface.effort.defaultValueTitle, "Low")
        pane.selectEffort(.init(rawValue: "next-generation"))
        XCTAssertEqual(pane.reasoningEffort?.rawValue, "next-generation")
        pane.surface.composer.string = "Use the discovered model"
        pane.send()
        try await wait { pane.surface.composer.string.isEmpty }
        guard case .send(_, _, let model, let effort, let provider, _, _) = backend.requests.last else { return XCTFail("Missing send") }
        XCTAssertEqual(model, "future-codex-model")
        XCTAssertEqual(provider, .codex)
        XCTAssertEqual(effort?.rawValue, "next-generation")
    }

    func testRefreshModelsRequestsFreshProviderDataAndUpdatesMenu() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        var refreshes: [Bool] = []
        pane.loadModelCatalog = { provider, force in
            guard provider.kind == .codex else { return .init(models: []) }
            refreshes.append(force)
            return .init(models: [.init(id: force ? "new-release" : "existing", title: force ? "New release" : "Existing",
                                        reasoningEfforts: [.high])], source: "live")
        }
        pane.refresh()
        try await wait { pane.snapshot != nil && modelItems(pane).map(\.title).contains("Existing") }
        pane.surface.model.selectItem(withTitle: "Refresh models…")
        _ = (pane.surface.model.target as? NSObject)?.perform(try XCTUnwrap(pane.surface.model.action), with: pane.surface.model)
        try await wait { modelItems(pane).map(\.title).contains("New release") }
        XCTAssertEqual(refreshes, [false, true])
        XCTAssertFalse(modelItems(pane).map(\.title).contains("Existing"))
        XCTAssertFalse(backend.requests.contains { if case .send = $0 { return true }; return false })
    }

    func testSavedModelCatalogFollowsUpWithLiveRefresh() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        var refreshes: [Bool] = []
        pane.loadModelCatalog = { provider, force in
            guard provider.kind == .claude else { return .init(models: []) }
            refreshes.append(force)
            if !force {
                return .init(models: [.init(id: "opus", title: "Opus", reasoningEfforts: [.high], isDefault: true)],
                             source: "saved")
            }
            return .init(models: [.init(id: "opus", title: "Opus 5.5", reasoningEfforts: [.high], isDefault: true),
                                  .init(id: "sonnet", title: "Sonnet 5.5", reasoningEfforts: [.high])],
                         source: "live")
        }
        pane.refresh()
        try await wait { pane.snapshot != nil && modelItems(pane).map(\.title).contains("Opus 5.5") }
        XCTAssertEqual(refreshes, [false, true])
        XCTAssertTrue(modelItems(pane).map(\.title).contains("Sonnet 5.5"))
        XCTAssertFalse(modelItems(pane).map(\.title).contains("Opus"))
    }

    func testForcedModelRefreshCancelsInFlightRefresh() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        var codexStarted = false
        pane.loadModelCatalog = { provider, force in
            if provider.kind == .codex && !force {
                codexStarted = true
                try await Task.sleep(for: .seconds(10))
                return .init(models: [], source: "live")
            }
            guard provider.kind == .claude else { return .init(models: [], source: "live") }
            return .init(models: [.init(id: force ? "fresh" : "stale", title: force ? "Fresh" : "Stale",
                                        reasoningEfforts: [.high])], source: "live")
        }
        pane.refresh()
        try await wait { pane.snapshot != nil && codexStarted && modelItems(pane).map(\.title).contains("Stale") }
        pane.surface.model.selectItem(withTitle: "Refresh models…")
        _ = (pane.surface.model.target as? NSObject)?.perform(try XCTUnwrap(pane.surface.model.action), with: pane.surface.model)
        try await wait { modelItems(pane).map(\.title).contains("Fresh") }
        XCTAssertFalse(modelItems(pane).map(\.title).contains("Stale"))
    }

    func testRefreshCoalescesAndFiltersOtherSessionsAndOldRevisions() async throws {
        let backend = Backend()
        backend.snapshot.revision = 10
        let pane = backend.controller()
        defer { pane.dispose() }
        for _ in 0..<40 { pane.refresh() }
        try await wait { pane.snapshot != nil }
        XCTAssertEqual(backend.requests.count, 1)
        pane.sessionChanged(session: SessionId(), revision: 100)
        pane.sessionChanged(session: backend.session, revision: 9)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(backend.requests.count, 1)
        for _ in 0..<40 { pane.sessionChanged(session: backend.session, revision: 11) }
        try await wait { backend.requests.count == 2 }
        XCTAssertEqual(backend.requests.last, .read(session: backend.session))
    }

    func testSendPreservesNewEditsAndUsesExplicitModelWithoutParallelSends() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.composer.string = "First message"
        pane.selectModel(provider: .claude, model: "  custom-model  ")
        backend.gateNextSend = true
        pane.send()
        try await wait { backend.sendGate != nil }
        pane.surface.composer.string = "A new draft typed while sending"
        pane.send()
        XCTAssertEqual(backend.requests.filter { if case .send = $0 { return true }; return false }.count, 1)
        backend.sendGate?.resume()
        backend.sendGate = nil
        try await wait { pane.snapshot?.status == .working }
        XCTAssertEqual(backend.snapshot.model, "custom-model")
        XCTAssertEqual(pane.surface.composer.string, "A new draft typed while sending")
        XCTAssertTrue(pane.surface.model.isEnabled, "The model can change for the next prompt while the agent works")
    }

    func testStopDuringSubmissionWaitsForAcceptedSend() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.composer.string = "Start work"
        backend.gateNextSend = true
        pane.send()
        try await wait { backend.sendGate != nil }
        XCTAssertFalse(pane.surface.stop.isHidden)
        XCTAssertTrue(pane.surface.stop.isEnabled)
        pane.stop()
        XCTAssertFalse(backend.requests.contains(.interrupt(session: backend.session)))
        backend.sendGate?.resume()
        backend.sendGate = nil
        try await wait { backend.requests.contains(.interrupt(session: backend.session)) }
        try await wait { pane.snapshot?.status == .idle }
    }

    func testStopInterruptsAcceptedStartupBeforeSendReplyArrives() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.composer.string = "Start a provider"
        backend.gateNextSend = true
        pane.send()
        try await wait { backend.sendGate != nil }
        pane.stop()
        // The real daemon publishes this state before waiting for provider startup.
        backend.snapshot.status = .working
        backend.snapshot.revision += 1
        pane.sessionChanged(session: backend.session, revision: backend.snapshot.revision)
        try await wait { backend.requests.contains(.interrupt(session: backend.session)) }
        XCTAssertNotNil(backend.sendGate, "Stop must not await the provider's initialization reply")
        // Release the stand-in request for clean test teardown.
        backend.sendGate?.resume()
        backend.sendGate = nil
    }

    func testDurableAcceptanceClearsDraftEvenWhenEarlierTurnFailedAndAllowsModelCorrection() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        backend.failSendSnapshot = true
        pane.surface.composer.string = "Fix the tests"
        pane.selectModel(provider: .claude, model: "invalid-model")
        pane.send()
        try await wait { pane.snapshot?.status == .failed }
        XCTAssertTrue(pane.surface.composer.string.isEmpty, "The accepted queue now owns the prompt")
        XCTAssertTrue(pane.surface.model.isEnabled)
        pane.selectModel(provider: .claude, model: "corrected-model")
        pane.refresh()
        try await wait { backend.requests.count == 3 }
        // Allow the completed read to apply, not just start.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pane.selection.model, "corrected-model")
        backend.failSendSnapshot = false
        pane.surface.composer.string = "Retry with the corrected model"
        pane.send()
        try await wait { pane.snapshot?.status == .working }
        XCTAssertEqual(backend.snapshot.model, "corrected-model")
        XCTAssertTrue(pane.surface.composer.string.isEmpty)
    }

    func testUnusedOrMissingSessionsCanCloseButRunningOfflineSessionCannot() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        let unusedCanClose = await pane.commitClose()
        XCTAssertTrue(unusedCanClose)
        XCTAssertTrue(backend.requests.isEmpty)
        backend.failCreate = true
        pane.refresh()
        try await wait { pane.errorMessage != nil }
        let failedCreateCanClose = await pane.commitClose()
        XCTAssertTrue(failedCreateCanClose)
        XCTAssertFalse(backend.requests.contains(.close(session: backend.session)))
        backend.failCreate = false
        backend.snapshot.status = .working
        pane.refresh()
        try await wait { pane.snapshot != nil }
        backend.closeError = ClientError.disconnected
        let offlineCanClose = await pane.commitClose()
        XCTAssertFalse(offlineCanClose)
        backend.closeError = ClientError.server(ErrorReply(code: .unknownSession, message: "Already removed"))
        let missingCanClose = await pane.commitClose()
        XCTAssertTrue(missingCanClose)
    }

    func testComposerChoicesRestoreBeforeSendingAndSeedNewChats() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        let prefs = AgentComposerPreferences(provider: .codex, model: "gpt-6.1-sol", effort: .high, access: .fullAccess)
        var saved: AgentComposerPreferences?
        pane.restorePreferences(defaults: prefs, draft: prefs) { saved = $0 }
        pane.didShow()
        let loaded = await ModelFixtures.wait { pane.snapshot?.accessMode == .fullAccess }
        XCTAssertTrue(loaded)
        XCTAssertEqual(pane.selection.provider, .codex)
        XCTAssertEqual(pane.selection.model, prefs.model)
        XCTAssertEqual(pane.reasoningEffort, .high)
        pane.selectEffort(.low)
        XCTAssertEqual(saved?.effort, .low)

        let freshBackend = Backend()
        let fresh = freshBackend.controller()
        defer { fresh.dispose() }
        fresh.restorePreferences(defaults: prefs, draft: nil) { _ in }
        fresh.didShow()
        let seeded = await ModelFixtures.wait { fresh.snapshot?.accessMode == .fullAccess }
        XCTAssertTrue(seeded)
        XCTAssertEqual(fresh.selection.model, prefs.model)
        XCTAssertEqual(fresh.reasoningEffort, .high)

        backend.snapshot.revision = 4
        let next = backend.controller()
        defer { next.dispose() }
        next.restorePreferences(defaults: prefs, draft: nil) { _ in }
        next.didShow()
        let restored = await ModelFixtures.wait { next.snapshot != nil }
        XCTAssertTrue(restored)
        // This session already has a persisted access change and must retain its own choices.
        XCTAssertEqual(next.selection.provider, .claude)
    }

    func testModelAndEffortSelectionReachSendAndSurviveReconnect() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        try await wait { pane.surface.model.isEnabled && self.modelItems(pane).contains { $0.title == "GPT-6.1 Sol" } }
        let modelItem = try XCTUnwrap(modelItems(pane).first { $0.title == "GPT-6.1 Sol" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(modelItem.action), to: modelItem.target, from: modelItem))
        pane.surface.effort.selectItem(withTitle: "High")
        _ = (pane.surface.effort.target as? NSObject)?.perform(try XCTUnwrap(pane.surface.effort.action), with: pane.surface.effort)
        pane.connectionChanged()
        try await wait { backend.requests.count == 2 && pane.surface.model.isEnabled }
        XCTAssertEqual(pane.selection.provider, .codex)
        XCTAssertEqual(pane.reasoningEffort, .high)
        pane.surface.composer.string = "Review the code"
        pane.send()
        try await wait { pane.snapshot?.status == .working }
        XCTAssertEqual(backend.requests.last, .send(session: backend.session, text: "Review the code",
            model: "gpt-6.1-sol", reasoningEffort: .high, provider: .codex))
        XCTAssertEqual(pane.title, "Review the code")
        XCTAssertTrue(pane.surface.send.isHidden, "Stop takes the shared slot while the draft is empty")
        XCTAssertFalse(pane.surface.stop.isHidden)
        XCTAssertTrue(pane.surface.effort.isEnabled, "Effort can change for the next prompt while the agent works")
        pane.surface.composer.string = "/effort low"
        pane.send()
        XCTAssertEqual(pane.reasoningEffort, .low, "The command changes the same next-message setting as the picker")
        XCTAssertTrue(pane.surface.composer.string.isEmpty)
        var asked = false
        pane.confirmProviderHandoff = { _ in asked = true; return false }
        pane.selectModel(provider: .claude, model: nil)
        try await wait { asked }
        XCTAssertEqual(pane.selection.provider, .codex, "Declining the handoff keeps the provider")
    }

    func testResumedConversationRestoresOptionsAndOffersOtherProvidersAsAHandoff() async throws {
        let backend = Backend()
        backend.snapshot.provider = .codex
        backend.snapshot.providerSession = "thread-1"
        backend.snapshot.model = "gpt-6.1-sol"
        backend.snapshot.reasoningEffort = .high
        backend.snapshot.items = [AgentChatItem(kind: .assistant, text: "Previous answer")]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertEqual(pane.selection.provider, .codex)
        XCTAssertEqual(pane.reasoningEffort, .high)
        var asked: String?
        pane.confirmProviderHandoff = { provider in asked = provider; return false }
        pane.selectModel(provider: .claude, model: "claude-opus-5-5")
        try await wait { asked != nil }
        XCTAssertEqual(pane.selection.provider, .codex)
        let otherModels = modelItems(pane).filter {
            ($0.representedObject as? AgentModelSelection)?.provider == .claude
        }
        XCTAssertFalse(otherModels.isEmpty)
        XCTAssertTrue(otherModels.allSatisfy { $0.isEnabled && $0.toolTip?.contains("conversation so far") == true })
        pane.selectModel(provider: .codex, model: "gpt-6-astra")
        pane.selectEffort(nil)
        pane.surface.composer.string = "Continue"
        pane.send()
        try await wait { pane.snapshot?.status == .working }
        XCTAssertEqual(backend.snapshot.model, "gpt-6-astra")
        XCTAssertNil(backend.snapshot.reasoningEffort)
    }

    func testInitialOptionsWaitForSnapshotAndCustomChoiceSurvivesReconnect() async throws {
        let backend = Backend()
        backend.snapshot.provider = .codex
        let pane = backend.controller()
        defer { pane.dispose() }
        XCTAssertFalse(pane.surface.model.isEnabled)
        XCTAssertFalse(pane.surface.effort.isEnabled)
        pane.selectEffort(.high)
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertEqual(pane.selection.provider, .codex)
        XCTAssertNil(pane.reasoningEffort)
        backend.gateNextRead = true
        pane.connectionChanged()
        try await wait { backend.readGate != nil }
        // The custom-model sheet was opened before the connection went away.
        pane.selectModel(provider: .codex, model: "custom-model")
        XCTAssertEqual(pane.selection.model, "custom-model")
        backend.readGate?.resume()
        backend.readGate = nil
        try await wait { pane.surface.model.isEnabled }
        XCTAssertEqual(pane.selection.model, "custom-model")
    }

    func testClosingWhileCreateIsPendingWaitsThenClosesCreatedSession() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        let canClose = await pane.commitClose()
        XCTAssertTrue(canClose)
        XCTAssertEqual(backend.requests, [
            .create(session: backend.session, project: backend.project, provider: .claude),
            .close(session: backend.session),
        ])
    }

    func testEventDuringReadSchedulesOneFollowupRead() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        backend.gateNextRead = true
        pane.refresh()
        try await wait { backend.readGate != nil }
        for _ in 0..<25 { pane.sessionChanged(session: backend.session, revision: 5) }
        backend.readGate?.resume()
        backend.readGate = nil
        try await wait { backend.requests.count == 3 }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(backend.requests.count, 3)
    }

    func testActiveAgentCloseCanBeCancelledWithoutStoppingWork() async throws {
        for status: AgentChatStatus in [.working, .waiting, .idle, .failed, .closed] {
            let backend = Backend()
            backend.snapshot.status = status
            let pane = backend.controller()
            defer { pane.dispose() }
            var confirmations = 0
            pane.confirmClose = {
                confirmations += 1
                return false
            }
            pane.refresh()
            try await wait { pane.snapshot != nil }
            let approved = await pane.willClose()
            let active = status == .working || status == .waiting
            XCTAssertEqual(approved, !active)
            XCTAssertEqual(confirmations, active ? 1 : 0)
            XCTAssertFalse(backend.requests.contains(.close(session: backend.session)))
            XCTAssertEqual(backend.snapshot.status, status)
        }
    }

    func testDiffCommentsAppendToDraftWithoutSendingOrReplacingCitations() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        let draft = NSMutableAttributedString(string: "Keep my draft")
        draft.addAttribute(.agentAssistantCitation, value: "existing-citation", range: NSRange(location: 0, length: 4))
        pane.surface.composer.textStorage?.setAttributedString(draft)
        pane.loadCheckpoint = { request in .init(checkpoint: request.checkpoint, files: [], totalFiles: 0) }
        pane.surface.onOpenCheckpoint?("checkpoint", nil)
        let review = try XCTUnwrap(pane.checkpointWindows.values.first)
        let comment = AgentReviewComment(checkpoint: "checkpoint", path: "source.swift", old: false,
                                        firstLine: 4, lastLine: 6, source: "retained code", text: "Please handle empty input")
        review.onReviewChange?([comment])
        XCTAssertEqual(review.reviewComments, [comment])
        try review.onDraftReview?()
        XCTAssertTrue(pane.surface.composer.string.hasPrefix("Keep my draft\n\n"))
        XCTAssertTrue(pane.surface.composer.string.contains("Please handle empty input"))
        XCTAssertEqual(pane.surface.composer.attributedString().attribute(.agentAssistantCitation, at: 0, effectiveRange: nil) as? String, "existing-citation")
        XCTAssertTrue(backend.submissions.isEmpty)
        XCTAssertTrue(review.reviewComments.isEmpty)
        let after = pane.surface.composer.string
        try review.onDraftReview?()
        XCTAssertEqual(pane.surface.composer.string, after, "Adding twice cannot duplicate consumed comments")
    }

    func testIdleParentWithRunningSubagentRequiresCloseConfirmation() async throws {
        let backend = Backend()
        backend.snapshot.status = .idle
        backend.snapshot.subagents = [.init(id: "child", description: "Running tests", background: true)]
        let pane = backend.controller()
        defer { pane.dispose() }
        var asked = false
        pane.confirmClose = { asked = true; return false }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        let approved = await pane.willClose()
        XCTAssertFalse(approved)
        XCTAssertTrue(asked)
        XCTAssertFalse(backend.requests.contains(.close(session: backend.session)))
        XCTAssertEqual(backend.snapshot.subagents?.first?.status, .running)
    }

    func testCloseApprovalDoesNotTerminateAgentBeforeOtherPanesCanVeto() async throws {
        let backend = Backend()
        backend.snapshot.status = .working
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        let approved = await pane.willClose()
        XCTAssertTrue(approved)
        // Simulate a dirty editor vetoing the rest of the tab close transaction.
        XCTAssertFalse(backend.requests.contains(.close(session: backend.session)))
        XCTAssertEqual(backend.snapshot.status, .working)
        let committed = await pane.commitClose()
        XCTAssertTrue(committed)
        XCTAssertEqual(backend.requests.last, .close(session: backend.session))
    }

    func testContextRoutesCreateUsingCurrentHomeAfterCatalogRemapsBootstrapHome() async throws {
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(
            server: identity, home: home.id, revision: 1, projects: [home]))
        let model = ModelFixtures.model(try ModelFixtures.profile(), server: server)
        defer { model.connection(.local)?.disconnect() }
        let bootstrapHome = model.state.home
        var opened: PaneId?
        XCTAssertTrue(model.edit { opened = try $0.openAgent(bootstrapHome.id, provider: .claude) })
        let paneID = try XCTUnwrap(opened)
        let paneState = try XCTUnwrap(model.state.pane(paneID))
        var routedRequests: [AgentChatRequest] = []
        let pane = AgentPaneController(context: PaneContext(pane: paneState, project: bootstrapHome, model: model)) { _, request in
            routedRequests.append(request)
            guard case .create(let session, let project, let provider, _) = request else {
                throw ClientError.unexpectedReply("Expected create")
            }
            return AgentChatSnapshot(session: session, project: project, provider: provider)
        }
        defer { pane.dispose() }
        model.start()
        try await wait {
            model.state.paneProject(paneID) == home.id && model.sideClient(for: home.id) != nil
        }
        XCTAssertNotEqual(bootstrapHome.id, home.id)
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertEqual(pane.snapshot?.project, home.id)
        let routed = try XCTUnwrap(routedRequests.first)
        guard case .create(_, let project, _, _) = routed else {
            return XCTFail("No routed create request")
        }
        XCTAssertEqual(project, home.id)
    }

    func testReconnectAcceptsRecoveredLowerRevisionAndIgnoresOldInflightRead() async throws {
        let backend = Backend()
        backend.snapshot.revision = 100
        backend.snapshot.status = .working
        backend.snapshot.items = [AgentChatItem(kind: .assistant, text: "Unsaved streaming output", isComplete: false)]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot?.revision == 100 }
        pane.surface.composer.string = "Retry my request"
        backend.gateNextRead = true
        pane.refresh()
        try await wait { backend.readGate != nil }
        backend.snapshot.revision = 91
        backend.snapshot.status = .failed
        backend.snapshot.items = [AgentChatItem(kind: .notice, text: "The daemon restarted during this turn.")]
        pane.connectionChanged()
        XCTAssertEqual(pane.snapshot?.revision, 100)
        XCTAssertEqual(pane.snapshot?.items.first?.text, "Unsaved streaming output")
        XCTAssertFalse(pane.surface.send.isEnabled)
        try await wait { pane.snapshot?.revision == 91 }
        XCTAssertEqual(pane.snapshot?.status, .failed)
        XCTAssertTrue(pane.surface.send.isEnabled)
        XCTAssertEqual(pane.surface.composer.string, "Retry my request")
        backend.readGate?.resume()
        backend.readGate = nil
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(pane.snapshot?.revision, 91)
        XCTAssertEqual(pane.snapshot?.status, .failed)
        XCTAssertTrue(pane.surface.send.isEnabled)
        // The reset is one-shot: ordinary reads still reject stale revisions afterward.
        backend.snapshot.revision = 90
        pane.refresh()
        try await wait { backend.requests.count == 4 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pane.snapshot?.revision, 91)
    }

    func testOfflineReconnectPreservesDraftAndDisposeDoesNotCloseSession() async throws {
        let backend = Backend()
        backend.failCreate = true
        let pane = backend.controller()
        pane.surface.composer.string = "Keep this draft"
        pane.refresh()
        try await wait { pane.errorMessage != nil }
        XCTAssertFalse(pane.surface.retry.isHidden)
        backend.failCreate = false
        pane.connectionChanged()
        try await wait { pane.snapshot != nil }
        pane.didHide()
        pane.didShow()
        XCTAssertEqual(pane.surface.composer.string, "Keep this draft")
        pane.dispose()
        XCTAssertFalse(backend.requests.contains(.close(session: backend.session)))
        XCTAssertFalse(backend.requests.contains(.interrupt(session: backend.session)))
    }

    func testApprovalButtonsAndStopRouteThroughTheConversationActions() async throws {
        let backend = Backend()
        backend.snapshot.status = .waiting
        backend.snapshot.items = [AgentChatItem(id: "permission", kind: .approval,
                                               text: "Run tests?", detail: "swift test", isComplete: false)]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        let approve = try XCTUnwrap(pane.surface.actions.onApprove)
        var approvals: [String] = []
        pane.surface.actions.onApprove = { id, allow in approvals.append("\(id):\(allow)"); try await approve(id, allow) }
        pane.surface.onApproval?("permission", true)
        try await wait { approvals == ["permission:true"] }
        var interrupts = 0
        let interrupt = try XCTUnwrap(pane.surface.actions.onInterrupt)
        pane.surface.actions.onInterrupt = { interrupts += 1; interrupt() }
        pane.surface.stop.perform()
        XCTAssertEqual(interrupts, 1)
    }

    func testApprovalOnlyResolvesPendingRequestsAndStopInterrupts() async throws {
        let backend = Backend()
        backend.snapshot.status = .waiting
        backend.snapshot.items = [AgentChatItem(id: "permission", kind: .approval,
                                               text: "Run tests?", detail: "swift test", isComplete: false)]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.approve("unknown", allow: true)
        XCTAssertEqual(backend.requests.count, 1)
        pane.approve("permission", allow: false)
        pane.approve("permission", allow: true)
        try await wait { pane.snapshot?.status == .working }
        XCTAssertEqual(backend.requests.last, .approve(session: backend.session, request: "permission", allow: false))
        pane.stop()
        try await wait { pane.snapshot?.status == .idle }
        XCTAssertEqual(backend.requests.last, .interrupt(session: backend.session))
        let canClose = await pane.commitClose()
        XCTAssertTrue(canClose)
        XCTAssertEqual(backend.requests.last, .close(session: backend.session))
    }

    func testComposerIsOutsideTranscriptAndRemainsFixedAsTranscriptGrows() {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 680, height: 700)
        pane.view.layoutSubtreeIfNeeded()
        let before = pane.surface.composerScroll.convert(pane.surface.composerScroll.bounds, to: pane.view)
        XCTAssertFalse(pane.surface.composer.isDescendant(of: pane.surface.transcriptScroll))
        backend.snapshot.items = (0..<300).map {
            AgentChatItem(id: "\($0)", kind: .assistant, text: "Message \($0)\nA second line")
        }
        pane.surface.render(backend.snapshot)
        pane.view.layoutSubtreeIfNeeded()
        let after = pane.surface.composerScroll.convert(pane.surface.composerScroll.bounds, to: pane.view)
        XCTAssertGreaterThan(after.minY, before.minY, "Empty composer moves from center to bottom on the first message")
        XCTAssertEqual(after.height, before.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(after.height, 44)
        XCTAssertLessThanOrEqual(after.height, 164)
        // One control row keeps the composer short.
        XCTAssertLessThan(pane.view.bounds.maxY - after.maxY, 140)
        let document = pane.surface.transcriptScroll.documentView as? AgentTranscriptDocument
        XCTAssertEqual(document?.entryCount, backend.snapshot.items.count)
        XCTAssertLessThan(document?.mountedRowCount ?? .max, 50)
    }

    func testStreamingDoesNotPullReaderAwayFromEarlierMessages() {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 680, height: 700)
        backend.snapshot.items = (0..<40).map {
            AgentChatItem(id: "message-\($0)", kind: .assistant,
                          text: "### Finding \($0)\n\nA detailed explanation with **important context**.")
        }
        pane.view.layoutSubtreeIfNeeded()
        pane.surface.render(backend.snapshot)
        let clip = pane.surface.transcriptScroll.contentView
        XCTAssertGreaterThan(pane.surface.transcriptScroll.documentView?.bounds.height ?? 0, clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: 100))
        pane.surface.transcriptScroll.reflectScrolledClipView(clip)
        let readingPosition = clip.bounds.minY
        backend.snapshot.items.append(AgentChatItem(kind: .assistant, text: "New streamed text", isComplete: false))
        pane.surface.render(backend.snapshot)
        XCTAssertEqual(clip.bounds.minY, readingPosition, accuracy: 1)
    }

    func testApprovalActionWaitsForServerAcknowledgementAndPropagatesRejection() async throws {
        let backend = Backend()
        backend.snapshot.status = .waiting
        backend.snapshot.items = [.init(id: "approval:pending", kind: .approval, text: "Run", isComplete: false)]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        backend.gateNextApproval = true
        var acknowledged = false
        let action = Task {
            try await pane.surface.actions.approve(requestID: "pending", allow: true)
            acknowledged = true
        }
        try await wait { backend.approvalGate != nil }
        XCTAssertFalse(acknowledged)
        XCTAssertFalse(pane.snapshot?.items[0].isComplete ?? true)
        backend.approvalGate?.resume(); backend.approvalGate = nil
        try await action.value
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(pane.snapshot?.items[0].isComplete == true)

        backend.snapshot.items = [.init(id: "rejected", kind: .approval, text: "Run", isComplete: false)]
        backend.snapshot.status = .waiting
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.items.first?.id == "rejected" }
        backend.failApproval = true
        do {
            try await pane.surface.actions.approve(requestID: "rejected", allow: false)
            XCTFail("A failed server reply must reject the approval action")
        } catch {}
        XCTAssertFalse(pane.snapshot?.items[0].isComplete ?? true)
        XCTAssertNotNil(pane.errorMessage)
    }

    func testSendingFromEarlierHistoryFollowsTheNewTurn() async throws {
        let backend = Backend()
        backend.snapshot.items = (0..<40).map {
            AgentChatItem(id: "message-\($0)", kind: .assistant, text: "Earlier answer \($0)")
        }
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 680, height: 700)
        pane.view.layoutSubtreeIfNeeded()
        pane.refresh()
        try await wait { pane.snapshot != nil }
        let scroll = pane.surface.transcriptScroll
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        pane.surface.composer.string = "Continue here"
        pane.send()
        try await wait { backend.requests.contains(where: { if case .send = $0 { return true }; return false }) }
        pane.view.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 2)
    }

    /// Opt-in visual regression fixtures, matching AppSnapshotTests' PNG convention.
    func testRenderPopulatedAgentPaneWideAndNarrow() async throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render agent pane snapshots")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let backend = Backend()
        backend.snapshot.status = .waiting
        backend.snapshot.items = [
            AgentChatItem(id: "user", kind: .user, text: "Add a native agent conversation pane. Keep the composer fixed while messages scroll."),
            AgentChatItem(id: "assistant", kind: .assistant, text: "I’ll inspect the existing components and follow the app’s native theme."),
            AgentChatItem(id: "tool", kind: .tool, text: "Read · Sources/TabApp/Theme/Metrics.swift",
                           detail: "public static let gutter: CGFloat = 8\npublic static let cardRadius: CGFloat = 10\npublic static let controlGap: CGFloat = 8"),
            AgentChatItem(id: "tool-2", kind: .tool, text: "Read · Sources/TabApp/Agents/AgentPaneView.swift", detail: "Read 303 lines"),
            AgentChatItem(id: "answer", kind: .assistant, text: "### A calmer conversation\n\nThe chat now uses **native Markdown** and a composer that stays within reach.\n\n- **Model and effort** live below your message.\n- Tool activity folds into a compact summary.\n- Your terminal stays available beside the chat.\n\nUse `Shift-Return` for a new line. See the [project documentation](https://t3.codes/) for more."),
            AgentChatItem(id: "approval", kind: .approval, text: "Allow running the pane tests?",
                          detail: "swift test --filter AgentPaneTests", isComplete: false),
        ]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.composer.string = "Also verify the narrow split layout."
        pane.surface.refreshComposer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        defer { window.close() }
        pane.view.layoutSubtreeIfNeeded()

        func descendants(_ root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap { descendants($0) }
        }
        // Expand the tool result while leaving permission details visible by default.
        if let button = descendants(pane.view).compactMap({ $0 as? PillButton }).first(where: { $0.title == "Show details" }) {
            button.perform()
        }
        for dark in [true, false] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            for child in descendants(pane.view).compactMap({ $0 as? ThemedView }) {
                child.theme = theme
                child.themeDidChange()
            }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [1000, 680, 360] {
                window.setContentSize(NSSize(width: width, height: 800))
                pane.view.layoutSubtreeIfNeeded()
                pane.view.displayIfNeeded()
                let rep = try XCTUnwrap(pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds))
                pane.view.cacheDisplay(in: pane.view.bounds, to: rep)
                let name = "agent-\(dark ? "dark" : "light")-\(width).png"
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
            }
        }
    }

    func testConversationCopiesAsMarkdownWithEachSpeakerAndToolLines() {
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude)
        let tool = AgentToolActivity(name: "Bash", input: "swift test", status: .completed)
        snapshot.items = [
            AgentChatItem(kind: .user, text: "Run the tests"),
            AgentChatItem(kind: .tool, text: "Bash", tool: tool),
            AgentChatItem(kind: .assistant, text: "All **green**."),
        ]
        let markdown = AgentPaneController.markdown(snapshot)
        XCTAssertTrue(markdown.hasPrefix("**You**\n\nRun the tests\n\n> Bash"), markdown)
        XCTAssertTrue(markdown.hasSuffix("**Claude Code**\n\nAll **green**.\n"), markdown)
    }

    func testClosedConversationOffersNewConversation() async throws {
        let backend = Backend()
        backend.snapshot.status = .closed
        let pane = backend.controller()
        defer { pane.dispose() }
        var opened = 0
        pane.onNewConversation = { opened += 1 }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertFalse(pane.surface.newConversation.isHidden)
        pane.surface.newConversation.onPress?()
        XCTAssertEqual(opened, 1)
    }

    func testApprovalCanAllowAToolForTheConversationOrDenyWithAReason() async throws {
        let backend = Backend()
        backend.snapshot.status = .waiting
        backend.snapshot.items = [AgentChatItem(id: "first", kind: .approval, text: "Bash", isComplete: false),
                                  AgentChatItem(id: "second", kind: .approval, text: "Write", isComplete: false)]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertTrue(pane.surface.revealPendingRequest(), "The waiting capsule shows the first pending request")
        pane.choose(.allowAlways, approval: "first")
        try await wait { backend.requests.contains(.approve(session: backend.session, request: "first", allow: true, always: true)) }
        try await wait { pane.snapshot?.items.first?.isComplete == true }
        pane.askDenialReason = { tool in tool == "Write" ? "  Use the existing file  " : nil }
        pane.choose(.denyWithReason, approval: "second")
        try await wait {
            backend.requests.contains(.approve(session: backend.session, request: "second", allow: false, reason: "Use the existing file"))
        }
    }

    func testDictationShowsWordsAsTheyAreRecognized() {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.surface.composer.string = "Hello"
        pane.placeDictation("this is", final: false)
        XCTAssertEqual(pane.surface.composer.string, "Hello this is")
        pane.placeDictation("this is a test", final: false)
        XCTAssertEqual(pane.surface.composer.string, "Hello this is a test")
        pane.placeDictation("This is a test.", final: true)
        XCTAssertEqual(pane.surface.composer.string, "Hello This is a test.")
        pane.placeDictation("Again", final: true)
        XCTAssertEqual(pane.surface.composer.string, "Hello This is a test. Again", "A new dictation adds after the last one")
    }

    func testProjectFilesAreNamedAndOthersAttached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-e5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources/App.swift"), image = root.appendingPathComponent("shot.png")
        let spaced = root.appendingPathComponent("Read Me.md")
        for file in [source, image, spaced] { try Data("x".utf8).write(to: file) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.txt")
        let split = AgentPaneController.splitProjectFiles([source, image, spaced, outside], root: root.path)
        XCTAssertEqual(split.mentions, ["Sources/App.swift", "Read Me.md"])
        XCTAssertEqual(split.attachments, [image, outside], "Images are attached so the model sees them")
        XCTAssertEqual(AgentPaneController.splitProjectFiles([source], root: nil).attachments, [source], "A remote project attaches")

        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.localProjectRoot = root.path
        pane.attachFiles([source, spaced])
        XCTAssertEqual(pane.surface.composer.string, "@Sources/App.swift @\"Read Me.md\" ")
    }

    func testLongPasteBecomesATextAttachment() {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        XCTAssertFalse(pane.attachLongPaste("A short paste"))
        let long = (1...250).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertTrue(pane.attachLongPaste(long))
        XCTAssertTrue(pane.surface.composer.string.isEmpty)
    }

    func testEmptyMentionListsTopLevelFilesFirst() {
        let paths = ["b/deep/x.swift", "README.md", "a/one.swift", "Package.swift", "a/b/c.swift"]
        XCTAssertEqual(AgentComposerCoordinator.shallowest(paths, limit: 3), ["Package.swift", "README.md", "a/one.swift"])
    }

    /// T6: VoiceOver hears each approval, failure and finished turn once, while the
    /// keyboard is in the pane; never streaming text, a refresh, a reconnect or a return
    /// to the pane.
    func testVoiceOverHearsEachTransitionOnceWhileTheConversationHasTheKeyboard() async throws {
        let backend = Backend()
        let date = Date()
        backend.snapshot.items = [AgentChatItem(id: "u0", kind: .user, text: "Earlier"), AgentChatItem(id: "a0", kind: .assistant, text: "Done")]
        backend.snapshot.turns = [AgentChatTurn(userItemID: "u0", startedAt: date, completedAt: date, status: .idle, outcome: .completed)]
        backend.snapshot.status = .idle
        backend.snapshot.revision = 2
        let pane = backend.controller()
        defer { pane.dispose() }
        var spoken: [String] = []
        var keyboard = true
        pane.announcer.post = { text, _ in spoken.append(text) }
        pane.announcer.hasKeyboard = { _ in keyboard }
        func publish(_ change: (inout AgentChatSnapshot) -> Void) async throws {
            change(&backend.snapshot)
            backend.snapshot.revision += 1
            pane.sessionChanged(session: backend.session, revision: backend.snapshot.revision)
            try await wait { pane.snapshot?.revision == backend.snapshot.revision }
        }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertEqual(spoken, [], "Opening a pane replays nothing")

        try await publish {
            $0.items.append(AgentChatItem(id: "u1", kind: .user, text: "Run the tests"))
            $0.turns?.append(AgentChatTurn(userItemID: "u1", startedAt: date))
            $0.status = .waiting
            $0.items.append(AgentChatItem(id: "perm", kind: .approval, text: "Run swift test", isComplete: false))
        }
        XCTAssertEqual(spoken, ["The agent needs your approval: Run swift test"])
        // Streaming, refreshing and reconnecting repeat the same state.
        try await publish { $0.items.append(AgentChatItem(id: "a1", kind: .assistant, text: "Tok", isComplete: false)) }
        for token in ["en", " by", " token"] { try await publish { $0.items[$0.items.count - 1].text += token } }
        pane.connectionChanged()
        try await wait { pane.snapshot?.revision == backend.snapshot.revision }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(spoken.count, 1)

        try await publish {
            $0.items[$0.items.firstIndex { $0.id == "perm" } ?? 0].isComplete = true
            $0.turns?[1].completedAt = date
            $0.turns?[1].outcome = .completed
            $0.status = .idle
        }
        XCTAssertEqual(spoken.last, "The agent finished.")
        try await publish {
            $0.items.append(AgentChatItem(id: "u2", kind: .user, text: "Again"))
            $0.items.append(AgentChatItem(id: "err", kind: .notice, text: "Rate limited", workContext: .init(itemType: "error", sourceStatus: "failed")))
            $0.turns?.append(AgentChatTurn(userItemID: "u2", startedAt: date, completedAt: date, status: .failed, outcome: .failed))
            $0.status = .failed
        }
        XCTAssertEqual(spoken.last, "The agent's turn failed: Rate limited")
        XCTAssertEqual(spoken.count, 3)

        // With the keyboard in another pane, a question passes silently and isn't replayed later.
        keyboard = false
        try await publish {
            $0.items.append(AgentChatItem(id: "q", kind: .approval, text: "Which branch?", isComplete: false,
                                          questionnaire: AgentQuestionnaire(questions: [.init(id: "b", title: "Which branch?",
                                                                                              options: [.init(label: "main")])])))
        }
        keyboard = true
        try await publish { $0.items.append(AgentChatItem(id: "a3", kind: .assistant, text: "Waiting")) }
        XCTAssertEqual(spoken.count, 3)
    }

    func testTheConversationHasTheKeyboardOnlyInItsComposerOrTranscript() throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let outside = NSTextField(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let container = NSView(frame: window.contentLayoutRect)
        pane.surface.frame = container.bounds
        container.addSubview(pane.surface)
        container.addSubview(outside)
        window.contentView = container
        window.makeFirstResponder(pane.surface.composer)
        XCTAssertTrue(pane.surface.keyboardInConversation)
        window.makeFirstResponder(pane.surface.transcript)
        XCTAssertTrue(pane.surface.keyboardInConversation)
        window.makeFirstResponder(outside)
        XCTAssertFalse(pane.surface.keyboardInConversation)
    }

    func testEarlierItemsLoadAboveTheRetainedOnes() async throws {
        let backend = Backend()
        backend.snapshot.items = [AgentChatItem(id: "now", kind: .user, text: "Latest")]
        backend.snapshot.omittedItems = 3
        let pane = backend.controller()
        defer { pane.dispose() }
        var asked: [AgentConversationRequest] = []
        pane.conversationRequest = { request in
            asked.append(request)
            return .earlier(AgentEarlierItems(items: (1...3).map { AgentChatItem(id: "old-\($0)", kind: .user, text: "Old \($0)") },
                                              start: 0, total: 3))
        }
        XCTAssertNotNil(pane.surface.onLoadEarlier)
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.loadEarlier()
        try await wait { pane.earlierItems.count == 3 }
        XCTAssertEqual(asked, [.earlier(session: backend.session, before: nil, limit: AgentEarlierItems.maxItems)])
        XCTAssertEqual(pane.surface.snapshot?.items.map(\.id), ["old-1", "old-2", "old-3", "now"])
        XCTAssertEqual(pane.surface.snapshot?.omittedItems, 0)
        XCTAssertNil(pane.surface.onLoadEarlier, "The start is reached, so nothing more loads")
        XCTAssertEqual(pane.snapshot?.items.count, 1, "The conversation itself is unchanged")
    }
}

/// L1, L3 and L4 in the pane.
extension AgentPaneTests {
    func testShortcutsBindOnlyToTheExactOfferedDecisionAndButtonsSendTheirOwn() async throws {
        let backend = Backend()
        backend.snapshot.status = .waiting
        let noOneTime = AgentApprovalRequest(kind: "command", decisions: [
            .init(id: "acceptForSession", kind: .allowForSession, title: "Allow for this session"),
            .init(id: "cancel", kind: .cancel, title: "Decline and stop"),
        ])
        backend.snapshot.items = [AgentChatItem(id: "r1", kind: .approval, text: "make", isComplete: false, approval: noOneTime)]
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot?.items.count == 1 }
        XCTAssertFalse(pane.performConversationShortcut(.allowAgentApproval), "No one-time approval is offered")
        XCTAssertFalse(pane.performConversationShortcut(.denyAgentApproval), "Cancel stops the turn; Deny never sends it")
        XCTAssertFalse(backend.requests.contains { if case .decide = $0 { true } else if case .approve = $0 { true } else { false } })
        pane.choose(.decision("acceptForSession"), approval: "r1")
        try await wait { backend.requests.contains(.decide(session: backend.session, request: "r1", decision: "acceptForSession")) }
        try await wait { pane.snapshot?.items.first?.approval?.outcome?.decision == "acceptForSession" }

        backend.snapshot.status = .waiting
        let pair = AgentApprovalRequest(kind: "command", decisions: [
            .init(id: "accept", kind: .allowOnce, title: "Allow once"), .init(id: "decline", kind: .decline, title: "Decline"),
        ])
        backend.snapshot.items.append(AgentChatItem(id: "r2", kind: .approval, text: "ls", isComplete: false, approval: pair))
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.items.count == 2 }
        XCTAssertTrue(pane.performConversationShortcut(.denyAgentApproval))
        try await wait { backend.requests.contains(.decide(session: backend.session, request: "r2", decision: "decline")) }
        pane.choose(.decision("not-offered"), approval: "r2")
        XCTAssertFalse(backend.requests.contains(.decide(session: backend.session, request: "r2", decision: "not-offered")))
    }

    func testUsageLimitShowsItsResetAndResumeAtResetSchedulesOnceThenCancels() async throws {
        let backend = Backend()
        let reset = Date().addingTimeInterval(3600)
        let user = AgentChatItem(id: "u1", kind: .user, text: "Long task")
        backend.snapshot.items = [user, AgentChatItem(kind: .notice, text: "You've hit your usage limit.")]
        var turn = AgentChatTurn(userItemID: "u1", startedAt: Date().addingTimeInterval(-10), completedAt: Date(), status: .failed, outcome: .failed)
        turn.rateLimit = AgentRateLimitStop(resetsAt: reset, message: "Usage limit reached")
        backend.snapshot.turns = [turn]
        backend.snapshot.status = .failed
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot?.turns?.count == 1 }
        XCTAssertFalse(pane.surface.retryTurn.isHidden)
        XCTAssertFalse(pane.surface.resumeAtReset.isHidden)
        XCTAssertTrue(pane.surface.feedback.stringValue.contains("Resets"), pane.surface.feedback.stringValue)
        pane.toggleResumeAtReset()
        try await wait { backend.requests.contains { if case .schedule(_, _, let at) = $0 { at == reset } else { false } } }
        // The server now holds the retry for the reset.
        guard case .schedule(_, let prompt, _)? = backend.requests.last(where: { if case .schedule = $0 { true } else { false } }) else { return XCTFail() }
        var queued = AgentQueuedPrompt(prompt: prompt)
        queued.scheduledAt = reset
        backend.snapshot.queuedPrompts = [queued]
        backend.snapshot.revision += 1
        pane.refresh()
        try await wait { pane.snapshot?.queuedPrompts?.count == 1 }
        XCTAssertEqual(pane.surface.resumeAtReset.title, "Cancel Resume")
        XCTAssertEqual(pane.surface.retryTurn.title, "Retry Now")
        pane.retryLastTurn()
        try await wait { backend.requests.contains(.deliverQueued(session: backend.session, id: prompt.id, expectedRevision: 0)) }
        XCTAssertEqual(backend.submissions.count, 0, "Retry sends the scheduled prompt, not another one")
        pane.toggleResumeAtReset()
        try await wait { backend.requests.contains(.removeQueued(session: backend.session, id: prompt.id, expectedRevision: 0)) }
    }

    private func fire(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return XCTFail("No menu action") }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    func testClosedConversationsReopenAndDeleteOnlyAfterConfirming() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        let closed = SessionId()
        var conversationRequests: [AgentConversationRequest] = []
        pane.conversationRequest = { request in
            conversationRequests.append(request)
            switch request {
            case .reopen(let session): return .conversation(AgentChatSnapshot(session: session, project: backend.project, provider: .codex))
            case .delete(let session): return .deleted(AgentConversationDeletion(session: session))
            default: return .conversation(AgentChatSnapshot(session: closed, project: backend.project, provider: .codex))
            }
        }
        var shown: [SessionId] = []
        pane.showConversation = { shown.append($0.session) }
        pane.reopenConversation(closed)
        try await wait { shown == [closed] }
        let saved = AgentSavedConversation(session: closed, project: backend.project, provider: .codex, title: "Old work",
                                           updatedAt: nil, closedAt: Date(), archived: false, retention: .keep, expiresAt: nil, needsReview: true)
        let items = pane.savedConversationActions(saved)
        XCTAssertEqual(items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Reopen", "Keep until deleted", "Delete 7 days after closing", "Delete 30 days after closing",
                        "Delete 90 days after closing", "Delete Permanently…"])
        XCTAssertEqual(items.first { $0.title == "Keep until deleted" }?.state, .on)
        var confirmations: [String] = []
        pane.confirmDestructive = { title, message, _ in confirmations.append(message); return false }
        fire(items.last)
        try await wait { confirmations.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(conversationRequests.contains(.delete(session: closed)), "Nothing is deleted without confirming")
        XCTAssertTrue(confirmations[0].contains("may have reached the agent"), "Deleting says it drops prompts that need review")
        pane.confirmDestructive = { _, _, _ in true }
        fire(items.last)
        try await wait { conversationRequests.contains(.delete(session: closed)) }
        let thirty = items.first { $0.title == "Delete 30 days after closing" }
        try await Task.sleep(for: .milliseconds(100))
        fire(thirty)
        try await wait { conversationRequests.contains(.setRetention(session: closed, retention: .init(deleteAfterDays: 30))) }
    }
}

