import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentPaneTests: XCTestCase {
    @MainActor
    private final class Backend {
        let session = SessionId()
        let project = ProjectId()
        var requests: [AgentChatRequest] = []
        var failSend = false
        var failSendSnapshot = false
        var failCreate = false
        var closeError: Error?
        var readGate: CheckedContinuation<Void, Never>?
        var gateNextRead = false
        var sendGate: CheckedContinuation<Void, Never>?
        var gateNextSend = false
        lazy var snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude)

        func request(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
            requests.append(request)
            switch request {
            case .create:
                if failCreate { throw NSError(domain: "Offline", code: 1) }
            case .send(_, let text, let model, let effort, let provider, _):
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
            case .read:
                if gateNextRead {
                    gateNextRead = false
                    let beforeReconnect = snapshot
                    await withCheckedContinuation { readGate = $0 }
                    return beforeReconnect
                }
            case .approve(_, let id, _):
                if let index = snapshot.items.firstIndex(where: { $0.id == id }) {
                    snapshot.items[index].isComplete = true
                }
                snapshot.status = .working
                snapshot.revision += 1
            case .interrupt:
                snapshot.status = .idle
                snapshot.revision += 1
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
            AgentPaneController(session: session, project: project, provider: .claude) { [self] in
                try await request($0)
            }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Agent pane did not settle")
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
        guard case .send(_, let text, _, _, _, let attachments) = backend.requests.last else { return XCTFail("Missing send") }
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
        pane.surface.composer.string = "/clear"
        pane.send()
        XCTAssertTrue(pane.surface.composer.string.isEmpty)
        XCTAssertFalse(backend.requests.contains { if case .send = $0 { return true }; return false })
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
        XCTAssertFalse(pane.surface.model.isEnabled)
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

    func testAccessCanChangeWhileWaitingAndSurvivesRefresh() async throws {
        let backend = Backend()
        backend.snapshot.status = .waiting
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertTrue(pane.surface.access.isEnabled)
        pane.selectAccess(.fullAccess)
        try await wait { pane.snapshot?.accessMode == .fullAccess }
        pane.refresh()
        try await wait { backend.requests.contains(.read(session: backend.session)) }
        XCTAssertEqual(pane.surface.access.selectedItem?.representedObject as? AgentAccessMode, .fullAccess)
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

    func testFailedSnapshotPreservesDraftAndAllowsStableModelCorrectionBeforeRetry() async throws {
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
        XCTAssertEqual(pane.surface.composer.string, "Fix the tests")
        XCTAssertTrue(pane.surface.model.isEnabled)
        pane.selectModel(provider: .claude, model: "corrected-model")
        pane.refresh()
        try await wait { backend.requests.count == 3 }
        // Allow the completed read to apply, not just start.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pane.selection.model, "corrected-model")
        backend.failSendSnapshot = false
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

    func testModelAndEffortSelectionReachSendAndSurviveReconnect() async throws {
        let backend = Backend()
        let pane = backend.controller()
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.surface.model.selectItem(withTitle: "GPT-6.1 Sol")
        _ = (pane.surface.model.target as? NSObject)?.perform(try XCTUnwrap(pane.surface.model.action), with: pane.surface.model)
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
        XCTAssertEqual(pane.title, "Agent")
        XCTAssertTrue(pane.surface.send.isHidden)
        XCTAssertFalse(pane.surface.stop.isHidden)
        XCTAssertFalse(pane.surface.effort.isEnabled)
        pane.selectModel(provider: .claude, model: nil)
        XCTAssertEqual(pane.selection.provider, .codex)
    }

    func testResumedConversationRestoresOptionsAndLocksOnlyOtherProviders() async throws {
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
        pane.selectModel(provider: .claude, model: "claude-opus-5-5")
        XCTAssertEqual(pane.selection.provider, .codex)
        let otherModels = pane.surface.model.itemArray.filter {
            ($0.representedObject as? AgentModelSelection)?.provider == .claude
        }
        XCTAssertFalse(otherModels.isEmpty)
        XCTAssertTrue(otherModels.allSatisfy { !$0.isEnabled })
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
            guard case .create(let session, let project, let provider) = request else {
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
        guard case .create(_, let project, _) = routed else {
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
        XCTAssertEqual(before.minY, after.minY, accuracy: 1)
        XCTAssertEqual(after.height, before.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(after.height, 56)
        XCTAssertLessThanOrEqual(after.height, 164)
        // Only the action row and compact footer may sit below the message editor.
        XCTAssertLessThan(pane.view.bounds.maxY - after.maxY, 100)
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
}
