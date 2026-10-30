import Foundation
import TabProtocol
import XCTest
@testable import TabServer

private final class FakeAgentRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let lock = NSLock()
    var onSend: (@Sendable () async throws -> Void)?
    var onApprove: (@Sendable (String, Bool) async throws -> Void)?
    var onInterrupt: (@Sendable () async throws -> Void)?
    var onStop: (@Sendable () -> Void)?
    var onAccess: (@Sendable (AgentAccessMode) async throws -> Void)?
    private var stopCount = 0
    private var submittedModels: [String?] = []
    private var submittedEfforts: [AgentReasoningEffort?] = []
    private var currentAccess: AgentAccessMode = .standard
    var providerSession: String? = "provider-resume-id"
    var stops: Int { lock.withLock { stopCount } }
    var models: [String?] { lock.withLock { submittedModels } }
    var efforts: [AgentReasoningEffort?] { lock.withLock { submittedEfforts } }
    var access: AgentAccessMode { lock.withLock { currentAccess } }

    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.callback = callback }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        lock.withLock { submittedModels.append(model); submittedEfforts.append(reasoningEffort) }
        if let providerSession { callback(.providerSession(providerSession)) }
        if let onSend { try await onSend() }
    }
    func approve(request: String, allow: Bool) async throws {
        if let onApprove { try await onApprove(request, allow) } else { callback(.status(.idle)) }
    }
    func setAccess(_ mode: AgentAccessMode) async throws {
        lock.withLock { currentAccess = mode }
        if let onAccess { try await onAccess(mode) }
    }
    func interrupt() async throws {
        if let onInterrupt { try await onInterrupt() } else { callback(.status(.idle)) }
    }
    func stop() {
        lock.withLock { stopCount += 1 }
        onStop?()
    }
}

private final class AgentRuntimeBox: @unchecked Sendable {
    let lock = NSLock()
    private var value: FakeAgentRuntime?
    var runtime: FakeAgentRuntime? { lock.withLock { value } }
    func install(_ runtime: FakeAgentRuntime) { lock.withLock { value = runtime } }
}

private final class AgentEventCount: @unchecked Sendable {
    let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private actor AgentSubmissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class AgentSessionsTests: XCTestCase {
    func testContextTelemetryPersistsAndModelChangesClearItWithoutChangingDefaultSelection() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                callback(.resolvedModel("provider-default"))
                callback(.contextUsage(.init(usedTokens: 42_000, contextWindow: 200_000)))
                callback(.status(.idle))
            }
            box.install(runtime)
            return runtime
        })
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let submitted = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        XCTAssertEqual(submitted.contextUsage, .init(usedTokens: 42_000, contextWindow: 200_000))
        XCTAssertEqual(submitted.resolvedModel, "provider-default")
        XCTAssertNil(submitted.model, "Resolved telemetry must not change provider-default selection semantics")
        sessions.shutdown()

        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            // Deliberately do not emit new telemetry, to expose stale values.
            runtime.onSend = { callback(.status(.idle)) }
            box.install(runtime)
            return runtime
        })
        defer { restored.shutdown() }
        let recovered = try await restored.handle(.read(session: id))
        XCTAssertEqual(recovered.contextUsage, submitted.contextUsage)
        XCTAssertEqual(recovered.resolvedModel, "provider-default")
        let sameModel = try await restored.handle(.send(session: id, text: "again", model: nil, reasoningEffort: .high))
        XCTAssertEqual(sameModel.contextUsage, submitted.contextUsage, "Effort alone does not invalidate the context capacity")
        let changedModel = try await restored.handle(.send(session: id, text: "switch", model: "other"))
        XCTAssertNil(changedModel.contextUsage)
        XCTAssertNil(changedModel.resolvedModel)
    }

    func testProviderChangeClearsUnestablishedTelemetryAndFencesLateEvents() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { provider, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.providerSession = nil
            runtime.onSend = {
                if provider == .claude {
                    callback(.contextUsage(.init(usedTokens: 123)))
                    callback(.resolvedModel("claude-default"))
                    callback(.failure("startup failed"))
                } else { callback(.status(.idle)) }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let failed = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        XCTAssertEqual(failed.contextUsage?.usedTokens, 123)
        let old = try XCTUnwrap(box.runtime)
        let switched = try await sessions.handle(.send(session: id, text: "retry", model: nil, provider: .codex))
        XCTAssertNil(switched.contextUsage)
        XCTAssertNil(switched.resolvedModel)
        old.callback(.contextUsage(.init(usedTokens: 999)))
        let latest = try await sessions.handle(.read(session: id))
        XCTAssertNil(latest.contextUsage)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testIdempotentCreateSubmissionSnapshotAndResumeAfterRestart() async throws {
        let root = try root()
        let box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        let id = SessionId(), project = ProjectId()
        let create = AgentChatRequest.create(session: id, project: project, provider: .claude)
        let initial = try await sessions.handle(create)
        XCTAssertNil(box.runtime, "Create must not launch a provider")
        let duplicate = try await sessions.handle(create)
        XCTAssertEqual(initial, duplicate)
        let submitted = try await sessions.handle(.send(session: id, text: "hello", model: "chosen", reasoningEffort: .high))
        XCTAssertEqual(submitted.status, .working)
        XCTAssertEqual(submitted.providerSession, "provider-resume-id")
        XCTAssertEqual(submitted.items.map(\.text), ["hello"])
        do {
            _ = try await sessions.handle(.send(session: id, text: "duplicate", model: nil))
            XCTFail("Concurrent turns must be refused")
        } catch {}
        sessions.shutdown()
        let resumed = AgentRuntimeBox()
        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, resume, callback in
            XCTAssertEqual(resume, "provider-resume-id")
            let runtime = FakeAgentRuntime(callback)
            resumed.install(runtime)
            return runtime
        })
        defer { restored.shutdown() }
        let recovered = try await restored.handle(.read(session: id))
        XCTAssertEqual(recovered.status, .failed)
        XCTAssertEqual(recovered.reasoningEffort, .high)
        XCTAssertEqual(recovered.model, "chosen")
        XCTAssertTrue(recovered.items.contains { $0.kind == .notice && $0.text.contains("interrupted") })
        XCTAssertNil(resumed.runtime, "Recovery is read-only until the next send")
        let reset = try await restored.handle(.send(session: id, text: "resume", model: nil))
        XCTAssertNil(reset.model)
        XCTAssertNil(reset.reasoningEffort)
        XCTAssertNotNil(resumed.runtime)
    }

    func testSynchronousCompletionIsNotOverwrittenBySendAndLateCallbacksCannotReopenClosedSession() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = { callback(.status(.idle)) }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        let submitted = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        XCTAssertEqual(submitted.status, .idle)
        XCTAssertTrue(sessions.hasSessions, "An idle provider process must still keep the server busy")
        let closed = try await sessions.handle(.close(session: id))
        box.runtime?.callback(.status(.working))
        box.runtime?.callback(.textDelta(id: "late", text: "must be ignored"))
        let read = try await sessions.handle(.read(session: id))
        XCTAssertEqual(read, closed)
        XCTAssertFalse(sessions.hasSessions)
    }

    func testOutputIsBoundedAndBurstEventsAreCoalesced() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let notified = expectation(description: "coalesced revision")
        notified.assertForOverFulfill = false
        let events = AgentEventCount()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, changed: { _, _ in
            events.increment()
            notified.fulfill()
        }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                for _ in 0..<100 { callback(.textDelta(id: "answer", text: String(repeating: "🙂", count: 1000))) }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        let snapshot = try await sessions.handle(.send(session: id, text: "hello", model: nil))
        try snapshot.validate()
        XCTAssertLessThanOrEqual(snapshot.items.last?.text.utf8.count ?? 0, 64 * 1024)
        XCTAssertTrue(snapshot.items.last?.text.hasPrefix("[Earlier text truncated]") == true)
        XCTAssertFalse(snapshot.items.last?.text.contains("�") == true)
        XCTAssertGreaterThan(snapshot.revision, 100)
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertLessThan(events.count, 20, "A burst must not emit an event per token")
    }

    func testCrashRecoveryMarksActiveCheckpointInterruptedWithoutLaunching() async throws {
        struct Checkpoint: Encodable {
            var snapshot: AgentChatSnapshot
            var directory: String
        }
        let root = try root(), session = SessionId()
        let user = AgentChatItem(kind: .user, text: "request before crash")
        let snapshot = AgentChatSnapshot(session: session, project: ProjectId(), provider: .claude,
                                         providerSession: "resume",
                                         turns: [.init(userItemID: user.id, startedAt: Date(timeIntervalSinceNow: -10))],
                                         status: .working, revision: 9,
                                         items: [user, AgentChatItem(kind: .assistant, text: "partial", isComplete: false)])
        try JSONEncoder().encode(Checkpoint(snapshot: snapshot, directory: root.path))
            .write(to: root.appendingPathComponent(session.description + ".json"))
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            XCTFail("Recovery must never launch a provider")
            return FakeAgentRuntime(callback)
        })
        defer { sessions.shutdown() }
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read.status, .failed)
        XCTAssertEqual(read.providerSession, "resume")
        XCTAssertGreaterThan(read.revision, snapshot.revision)
        XCTAssertTrue(read.items.allSatisfy(\.isComplete))
        XCTAssertEqual(read.turns?.last?.status, .failed)
        XCTAssertNotNil(read.turns?.last?.completedAt)
    }

    func testCloseWinsAgainstInFlightSubmissionAndProjectRemovalClosesAgents() async throws {
        let root = try root()
        let started = expectation(description: "submission started")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                started.fulfill()
                try await Task.sleep(nanoseconds: 150_000_000)
                callback(.status(.working))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId(), project = ProjectId()
        _ = try await sessions.handle(.create(session: session, project: project, provider: .codex))
        let sending = Task { try await sessions.handle(.send(session: session, text: "hello", model: nil)) }
        await fulfillment(of: [started], timeout: 2)
        sessions.close(project: project)
        let closed = try await sessions.handle(.read(session: session))
        XCTAssertEqual(closed.status, .closed)
        let submitted = try await sending.value
        XCTAssertEqual(submitted.status, .closed)
        XCTAssertEqual(submitted, closed)
    }

    func testPendingApprovalsSurviveTrimmingAndEscapedSnapshotFitsFrame() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                callback(.item(AgentChatItem(id: "permission", kind: .approval,
                                            text: String(repeating: "Command ", count: 1000),
                                            detail: String(repeating: "🙂\0", count: 10000), isComplete: false)))
                for index in 0..<520 {
                    callback(.item(AgentChatItem(id: "tool-\(index)", kind: .tool,
                                                text: String(repeating: "\0", count: 2000))))
                }
                callback(.status(.waiting))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let waiting = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        XCTAssertTrue(waiting.items.contains { $0.id == "permission" && !$0.isComplete })
        let permission = try XCTUnwrap(waiting.items.first { $0.id == "permission" })
        XCTAssertTrue(permission.text.hasPrefix("[Earlier text truncated]"))
        XCTAssertTrue(permission.detail?.hasPrefix("[Earlier text truncated]") == true)
        XCTAssertFalse(permission.detail?.contains("�") == true)
        try waiting.validate()
        let frame = try FrameEncoder.encode(Message.reply(RequestId(1), .agentChat(waiting)))
        XCTAssertLessThan(frame.count, Limits.maxFrame)
        let approved = try await sessions.handle(.approve(session: session, request: "permission", allow: true))
        XCTAssertEqual(approved.status, .idle)
    }

    func testServerSubmissionDeadlineStopsGenerationBeforeClientBudget() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, submissionTimeout: 0.02,
                                         factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                try await Task.sleep(nanoseconds: 100_000_000)
                callback(.status(.working))
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let failed = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.items.contains { $0.text.contains("timed out") })
        try await Task.sleep(nanoseconds: 150_000_000)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, failed, "Late callbacks must not revive a timed-out runtime")
        XCTAssertEqual(box.runtime?.stops, 1)
    }

    func testFailureRetryUsesNewRuntimeAndIgnoresOldGeneration() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "first", model: "invalid-model"))
        let old = try XCTUnwrap(box.runtime)
        old.callback(.failure("disconnected"))
        let failed = try await sessions.handle(.read(session: session))
        XCTAssertEqual(failed.status, .failed)
        let retried = try await sessions.handle(.send(session: session, text: "retry", model: nil))
        XCTAssertFalse(old === box.runtime)
        XCTAssertEqual(retried.status, .working)
        XCTAssertNil(retried.model, "nil explicitly resets a failed model choice to the provider default")
        let replacement = try XCTUnwrap(box.runtime)
        XCTAssertEqual(replacement.models.count, 1)
        XCTAssertEqual(replacement.models, [nil])
        old.callback(.status(.idle))
        old.callback(.providerSession("stale"))
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, retried)
    }

    func testApprovingOneOfSeveralPermissionsKeepsRemainingApprovalWaiting() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                for id in ["first", "second"] {
                    callback(.item(AgentChatItem(id: id, kind: .approval, text: "Allow?", isComplete: false)))
                }
                callback(.status(.waiting))
            }
            runtime.onApprove = { id, _ in
                callback(.item(AgentChatItem(id: id, kind: .approval, text: "Approved")))
                callback(.status(id == "first" ? .waiting : .idle))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        let waiting = try await sessions.handle(.approve(session: session, request: "first", allow: true))
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertTrue(waiting.items.contains { $0.id == "second" && !$0.isComplete })
        let approved = try await sessions.handle(.approve(session: session, request: "second", allow: false))
        XCTAssertEqual(approved.status, .idle)
    }

    func testInterruptAcknowledgmentWaitsForAuthoritativeCompletionAndKeepsRuntimeReusable() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onInterrupt = {} // Acknowledged, but the provider has not finished the turn.
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        let runtime = try XCTUnwrap(box.runtime)
        let acknowledged = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(acknowledged.status, .working)
        XCTAssertEqual(runtime.stops, 0)
        runtime.callback(.status(.idle))
        let completed = try await sessions.handle(.read(session: session))
        XCTAssertEqual(completed.status, .idle)
        XCTAssertTrue(completed.items.contains { $0.kind == .notice && $0.text == "Agent interrupted." })
        XCTAssertEqual(runtime.stops, 0)
        let next = try await sessions.handle(.send(session: session, text: "next turn", model: nil))
        XCTAssertEqual(next.status, .working)
        XCTAssertTrue(runtime === box.runtime)
    }

    func testUnresponsiveInterruptIsStoppedOnlyAfterBoundedCompletionTimeout() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, interruptTimeout: 0.02,
                                         factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onInterrupt = {}
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "hello", model: nil))
        let acknowledged = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(acknowledged.status, .working)
        XCTAssertEqual(box.runtime?.stops, 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        let stopped = try await sessions.handle(.read(session: session))
        XCTAssertEqual(stopped.status, .failed)
        XCTAssertTrue(stopped.items.contains { $0.text.contains("did not finish interrupting") })
        XCTAssertEqual(box.runtime?.stops, 1)
    }

    func testInterruptDuringStartupSettlesSendImmediatelyAndFencesLateCallbacks() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let gate = AgentSubmissionGate()
        let started = expectation(description: "startup blocked")
        let settled = expectation(description: "pending send settled without waiting for runtime")
        let stopped = expectation(description: "startup runtime stopped")
        let lateCallbacks = expectation(description: "old runtime callbacks delivered")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let first = box.runtime == nil
            let runtime = FakeAgentRuntime(callback)
            if first {
                runtime.onSend = {
                    started.fulfill()
                    await gate.wait() // Deliberately ignores task cancellation.
                    callback(.providerSession("stale-startup-session"))
                    callback(.status(.working))
                    callback(.item(AgentChatItem(id: "stale", kind: .assistant, text: "must be ignored")))
                    lateCallbacks.fulfill()
                }
                runtime.onInterrupt = { XCTFail("A startup without a turn must be stopped, not gracefully interrupted") }
                runtime.onStop = { stopped.fulfill() }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .codex))
        let sending = Task {
            let snapshot = try await sessions.handle(.send(session: session, text: "hello", model: nil))
            settled.fulfill()
            return snapshot
        }
        await fulfillment(of: [started], timeout: 2)
        let interrupted = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(interrupted.status, .failed)
        XCTAssertTrue(interrupted.items.contains { $0.text.contains("startup stopped") })
        await fulfillment(of: [settled, stopped], timeout: 1)
        let submission = try await sending.value
        XCTAssertEqual(submission, interrupted)
        let restarted = try await sessions.handle(.send(session: session, text: "retry", model: nil))
        XCTAssertEqual(restarted.status, .working)
        await gate.release()
        await fulfillment(of: [lateCallbacks], timeout: 2)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, restarted, "Neither cancelled completion nor provider callbacks may mutate the replacement generation")
    }

    func testAcceptedCreateWinsAgainstConcurrentIdleShutdownReservation() async throws {
        for stopIfIdle in [true, false] {
            let fixture = try CoreTestServer(start: false)
            let server = fixture.server
            defer {
                server.agents.shutdown()
                withExtendedLifetime(fixture) {}
            }
            let directoryEntered = expectation(description: "create entered directory check")
            let shutdownAttempted = expectation(description: "idle stop attempted")
            let gate = DispatchSemaphore(value: 0)
            server.agents.checkDirectory = { _ in
                directoryEntered.fulfill()
                gate.wait()
            }
            let session = SessionId()
            let creating = Task {
                try await server.agents.handle(.create(session: session, project: server.homeProject, provider: .codex))
            }
            await fulfillment(of: [directoryEntered], timeout: 2)
            let stopping = Task.detached {
                shutdownAttempted.fulfill()
                return stopIfIdle ? server.requestStopIfIdle() : server.requestStop(force: false)
            }
            await fulfillment(of: [shutdownAttempted], timeout: 2)
            gate.signal()
            let created = try await creating.value
            let stopped = await stopping.value
            XCTAssertEqual(stopped, .serverBusy)
            XCTAssertFalse(server.stopping)
            let read = try await server.agents.handle(.read(session: session))
            XCTAssertEqual(read, created)
        }
    }

    func testIdleShutdownWinningReservationRejectsConcurrentCreate() async throws {
        let fixture = try CoreTestServer(start: false)
        let server = fixture.server
        defer {
            server.agents.shutdown()
            withExtendedLifetime(fixture) {}
        }
        XCTAssertEqual(server.requestStopIfIdle(), .serverStopping)
        do {
            _ = try await server.agents.handle(.create(session: SessionId(), project: server.homeProject, provider: .claude))
            XCTFail("No create may succeed after idle shutdown reserves the store")
        } catch {}
    }

    func testBusyTerminalsDoNotLeaveAgentsRefusedAfterIdleStopRequest() throws {
        let fixture = try CoreTestServer()
        let client = try fixture.connect()
        let project = try client.home()
        _ = try client.createSession(project: project, directory: fixture.root.path)
        XCTAssertEqual(fixture.server.requestStopIfIdle(), .serverBusy)
        XCTAssertEqual(fixture.server.requestStop(force: false), .serverBusy)
        let result = try client.request(.agentChat(.create(session: SessionId(), project: project, provider: .codex)))
        guard case .agentChat(let snapshot) = result else { return XCTFail("Busy terminals must not freeze the agent store") }
        XCTAssertEqual(snapshot.status, .idle)
    }

    func testFailedFirstAttemptCanSwitchProviderAndOriginalCreateSeedReconnectsToSelectedProvider() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { provider, _, resume, callback in
            XCTAssertNil(resume)
            let runtime = FakeAgentRuntime(callback)
            if provider == .claude {
                runtime.providerSession = nil
                runtime.onSend = { throw AgentRuntimeError("CLI unavailable") }
            }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId(), project = ProjectId()
        let seed = AgentChatRequest.create(session: session, project: project, provider: .claude)
        _ = try await sessions.handle(seed)
        let failed = try await sessions.handle(.send(session: session, text: "first attempt", model: nil))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNil(failed.providerSession)
        XCTAssertTrue(failed.items.contains { $0.kind == .user })
        let selected = try await sessions.handle(.send(session: session, text: "retry with Codex", model: "gpt-6.1-sol",
                                                       reasoningEffort: .xhigh, provider: .codex))
        XCTAssertEqual(selected.provider, .codex)
        XCTAssertEqual(selected.status, .working)
        XCTAssertEqual(selected.model, "gpt-6.1-sol")
        XCTAssertEqual(selected.reasoningEffort, .xhigh)
        XCTAssertEqual(box.runtime?.efforts, [.xhigh])
        let reconnected = try await sessions.handle(seed)
        XCTAssertEqual(reconnected, selected, "The persisted pane's seed cannot overwrite the authoritative provider")
        do {
            _ = try await sessions.handle(.send(session: session, text: "busy switch", model: nil, provider: .claude))
            XCTFail("A busy provider cannot switch")
        } catch {}
        let unchanged = try await sessions.handle(.read(session: session))
        XCTAssertEqual(unchanged, selected)
        box.runtime?.callback(.status(.idle))
        let established = try await sessions.handle(.read(session: session))
        do {
            _ = try await sessions.handle(.send(session: session, text: "lose context", model: nil, provider: .claude))
            XCTFail("An established provider session cannot switch")
        } catch {}
        let afterRejection = try await sessions.handle(.read(session: session))
        XCTAssertEqual(afterRejection, established)
    }

    func testUnsupportedEffortAndBusyConfigurationChangesLeaveSnapshotUntouched() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        let original = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        do {
            _ = try await sessions.handle(.send(session: session, text: "unsupported", model: "claude-haiku-4-5",
                                               reasoningEffort: .init(rawValue: "bad\nvalue")))
            XCTFail("Control characters are not valid effort values")
        } catch {}
        do {
            _ = try await sessions.handle(.send(session: session, text: "invalid effort", model: "claude-opus-5-5",
                                               reasoningEffort: .init(rawValue: ""), provider: .claude))
            XCTFail("Validate effort before changing providers")
        } catch {}
        XCTAssertNil(box.runtime)
        let untouched = try await sessions.handle(.read(session: session))
        XCTAssertEqual(untouched, original)
        let working = try await sessions.handle(.send(session: session, text: "valid", model: "claude-opus-5-5",
                                                      reasoningEffort: .low))
        do {
            _ = try await sessions.handle(.send(session: session, text: "change while busy", model: nil,
                                               reasoningEffort: .medium))
            XCTFail("Cannot change an active turn's selection")
        } catch {}
        let afterBusy = try await sessions.handle(.read(session: session))
        XCTAssertEqual(afterBusy, working)
    }

    func testClaudeSelectionChangeRestartsWithResumeAndNilClearsBothOverrides() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { provider, _, resume, callback in
            XCTAssertEqual(provider, .claude)
            if box.runtime != nil { XCTAssertEqual(resume, "provider-resume-id") }
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = { callback(.status(.idle)) }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "one", model: "claude-opus-5-5", reasoningEffort: .low))
        let old = try XCTUnwrap(box.runtime)
        let selected = try await sessions.handle(.send(session: session, text: "two", model: "claude-opus-5-5", reasoningEffort: .max))
        XCTAssertEqual(selected.providerSession, "provider-resume-id")
        XCTAssertEqual(selected.reasoningEffort, .max)
        XCTAssertFalse(old === box.runtime)
        old.callback(.providerSession("stale"))
        let reset = try await sessions.handle(.send(session: session, text: "default", model: nil, reasoningEffort: nil))
        XCTAssertNil(reset.model)
        XCTAssertNil(reset.reasoningEffort)
        XCTAssertEqual(reset.providerSession, "provider-resume-id")
        XCTAssertEqual(box.runtime?.models, [nil])
        XCTAssertEqual(box.runtime?.efforts, [nil])
    }

    func testSuccessfulTurnWithoutProviderIDCannotSwitchEvenAfterRestart() async throws {
        let root = try root()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.providerSession = nil
            runtime.onSend = { callback(.status(.idle)) }
            return runtime
        })
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "completed without output", model: nil))
        sessions.shutdown()
        let recovered = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            XCTFail("A rejected provider switch must not launch a process")
            return FakeAgentRuntime(callback)
        })
        defer { recovered.shutdown() }
        let before = try await recovered.handle(.read(session: session))
        XCTAssertNil(before.providerSession)
        do {
            _ = try await recovered.handle(.send(session: session, text: "switch", model: nil, provider: .codex))
            XCTFail("Successful-turn history must survive bounded transcript persistence")
        } catch {}
        let after = try await recovered.handle(.read(session: session))
        XCTAssertEqual(after, before)
    }

    func testAccessChangesApplyToPendingApprovalsPersistAndConfigureReplacementRuntime() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                callback(.item(AgentChatItem(id: "search", kind: .approval, text: "WebSearch", isComplete: false)))
                callback(.item(AgentChatItem(id: "command", kind: .approval, text: "Bash", isComplete: false)))
                callback(.status(.waiting))
            }
            runtime.onAccess = { mode in
                if mode == .standard {
                    callback(.item(AgentChatItem(id: "search", kind: .approval, text: "Automatically approved")))
                    callback(.status(.waiting))
                } else if mode == .fullAccess {
                    callback(.item(AgentChatItem(id: "search", kind: .approval, text: "Automatically approved")))
                    callback(.item(AgentChatItem(id: "command", kind: .approval, text: "Automatically approved")))
                    callback(.status(.working))
                }
            }
            box.install(runtime)
            return runtime
        })
        let session = SessionId(), project = ProjectId()
        let initial = try await sessions.handle(.create(session: session, project: project, provider: .claude))
        XCTAssertEqual(initial.accessMode, .standard)
        let ask = try await sessions.handle(.setAccess(session: session, mode: .ask))
        XCTAssertEqual(ask.accessMode, .ask)
        XCTAssertNil(box.runtime, "Changing access before the first send must not launch a provider")
        let waiting = try await sessions.handle(.send(session: session, text: "search then run", model: nil))
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(box.runtime?.access, .ask)
        let runtime = try XCTUnwrap(box.runtime)
        let standard = try await sessions.handle(.setAccess(session: session, mode: .standard))
        XCTAssertEqual(standard.accessMode, .standard)
        XCTAssertEqual(standard.status, .waiting)
        XCTAssertTrue(standard.items.contains { $0.id == "search" && $0.isComplete })
        XCTAssertTrue(standard.items.contains { $0.id == "command" && !$0.isComplete })
        XCTAssertTrue(runtime === box.runtime)
        let full = try await sessions.handle(.setAccess(session: session, mode: .fullAccess))
        XCTAssertEqual(full.status, .working)
        XCTAssertEqual(full.accessMode, .fullAccess)
        XCTAssertTrue(full.items.filter { $0.kind == .approval }.allSatisfy(\.isComplete))
        XCTAssertEqual(runtime.stops, 0, "Changing pending approvals must not restart the active turn")
        let refreshed = try await sessions.handle(.create(session: session, project: project, provider: .claude))
        XCTAssertEqual(refreshed, full)
        sessions.shutdown()

        let replacement = AgentRuntimeBox()
        let restored = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, resume, callback in
            XCTAssertEqual(resume, "provider-resume-id")
            let runtime = FakeAgentRuntime(callback)
            replacement.install(runtime)
            return runtime
        })
        defer { restored.shutdown() }
        let persisted = try await restored.handle(.read(session: session))
        XCTAssertEqual(persisted.accessMode, .fullAccess)
        _ = try await restored.handle(.send(session: session, text: "continue", model: nil))
        XCTAssertEqual(replacement.runtime?.access, .fullAccess, "Persisted explicit access must be installed before send")
    }

    func testAccessCompletionCannotMutateClosedGeneration() async throws {
        let root = try root()
        let gate = AgentSubmissionGate()
        let entered = expectation(description: "access update in flight")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onAccess = { mode in
                guard mode == .fullAccess else { return }
                entered.fulfill()
                await gate.wait()
                callback(.item(AgentChatItem(id: "late", kind: .approval, text: "Automatically approved")))
                callback(.status(.working))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: session, text: "start", model: nil))
        let changing = Task { try await sessions.handle(.setAccess(session: session, mode: .fullAccess)) }
        await fulfillment(of: [entered], timeout: 2)
        let closed = try await sessions.handle(.close(session: session))
        await gate.release()
        let returned = try await changing.value
        XCTAssertEqual(returned, closed)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, closed)
        XCTAssertFalse(read.items.contains { $0.id == "late" })
    }

    func testTurnsRecordRealAcceptanceCompletionAndDoNotRewriteCompletedHistory() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let before = Date()
        let sent = try await sessions.handle(.send(session: session, text: "first turn", model: nil))
        let turn = try XCTUnwrap(sent.turns?.first)
        XCTAssertEqual(turn.userItemID, sent.items.first { $0.kind == .user }?.id)
        XCTAssertGreaterThanOrEqual(turn.startedAt, before)
        XCTAssertLessThanOrEqual(turn.startedAt, Date())
        XCTAssertEqual(turn.status, .working)
        XCTAssertNil(turn.completedAt)
        box.runtime?.callback(.status(.waiting))
        let waiting = try await sessions.handle(.read(session: session))
        XCTAssertEqual(waiting.turns?.first?.status, .waiting)
        XCTAssertEqual(waiting.turns?.first?.startedAt, turn.startedAt)
        box.runtime?.callback(.status(.idle))
        let completed = try await sessions.handle(.read(session: session))
        let finished = try XCTUnwrap(completed.turns?.first)
        let end = try XCTUnwrap(finished.completedAt)
        XCTAssertGreaterThanOrEqual(end, finished.startedAt)
        XCTAssertEqual(finished.status, .idle)
        let second = try await sessions.handle(.send(session: session, text: "second turn", model: nil))
        XCTAssertEqual(second.turns?.count, 2)
        XCTAssertEqual(second.turns?.first, finished)
        let closed = try await sessions.handle(.close(session: session))
        XCTAssertEqual(closed.turns?.first, finished, "Closing a later turn must not replace a previous completion time/status")
        XCTAssertEqual(closed.turns?.last?.status, .closed)
        XCTAssertNotNil(closed.turns?.last?.completedAt)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read.turns, closed.turns)
        let decoded = try WireJSON.decode(AgentChatSnapshot.self, from: WireJSON.encode(closed))
        XCTAssertEqual(decoded.turns, closed.turns)
        try decoded.validate()
    }

    func testToolMetadataDuplicatesAreBudgetedAndLatestUserAndTurnSurviveOutputTrimming() async throws {
        let root = try root()
        let content = String(repeating: "🙂\0", count: 8000)
        let metadata = AgentToolActivity(name: "Bash", category: .command,
                                         input: String(repeating: "x", count: 20000), output: content, status: .completed,
                                         filePaths: (0..<50).map { "/project/\($0)/" + String(repeating: "p", count: 2000) },
                                         fileChanges: (0..<50).map { .init(path: "/project/\($0)", diff: content, kind: "edit") },
                                         urls: (0..<50).map { "https://example.com/\($0)/" + String(repeating: "u", count: 3000) })
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onSend = {
                for index in 0..<30 {
                    callback(.item(AgentChatItem(id: "tool-\(index)", kind: .tool, text: "Bash", detail: content, tool: metadata)))
                }
                for _ in 0..<20 { callback(.textDelta(id: "answer", text: "continued ")) }
                callback(.status(.idle))
            }
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let snapshot = try await sessions.handle(.send(session: session, text: "keep this turn header", model: nil))
        XCTAssertLessThanOrEqual(snapshot.items.reduce(0, { $0 + $1.transcriptByteCount }), 512 * 1024)
        XCTAssertEqual(snapshot.items.first { $0.kind == .user }?.text, "keep this turn header")
        XCTAssertEqual(snapshot.turns?.first?.userItemID, snapshot.items.first { $0.kind == .user }?.id)
        XCTAssertNotNil(snapshot.turns?.first?.completedAt)
        let tools = snapshot.items.compactMap(\.tool)
        XCTAssertFalse(tools.isEmpty)
        XCTAssertTrue(tools.contains { $0.input?.hasPrefix("[Earlier text truncated]") == true })
        XCTAssertTrue(tools.contains { $0.output?.contains("[Tool metadata truncated]") == true })
        for tool in tools {
            XCTAssertLessThanOrEqual(tool.filePaths?.count ?? 0, 32)
            XCTAssertLessThanOrEqual(tool.fileChanges?.count ?? 0, 32)
            XCTAssertFalse(tool.output?.contains("�") == true)
            XCTAssertLessThanOrEqual(tool.output?.components(separatedBy: "[Tool metadata truncated]").count ?? 0, 2)
        }
        try snapshot.validate()
        let frame = try FrameEncoder.encode(Message.reply(RequestId(1), .agentChat(snapshot)))
        XCTAssertLessThan(frame.count, Limits.maxFrame)
    }

    func testStopWhileInitialAccessConfigurationIsPendingCannotSubmitLater() async throws {
        let root = try root(), box = AgentRuntimeBox()
        let gate = AgentSubmissionGate()
        let configuring = expectation(description: "initial access is pending")
        let configured = expectation(description: "old access operation finishes")
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = FakeAgentRuntime(callback)
            runtime.onAccess = { _ in
                configuring.fulfill()
                await gate.wait()
                configured.fulfill()
            }
            runtime.onSend = { XCTFail("A cancelled startup must not send after configuration resumes") }
            box.install(runtime)
            return runtime
        })
        defer { sessions.shutdown() }
        let session = SessionId()
        _ = try await sessions.handle(.create(session: session, project: ProjectId(), provider: .claude))
        let sending = Task { try await sessions.handle(.send(session: session, text: "cancel before launch", model: nil)) }
        await fulfillment(of: [configuring], timeout: 2)
        let stopped = try await sessions.handle(.interrupt(session: session))
        XCTAssertEqual(stopped.status, .failed)
        let submitted = try await sending.value
        XCTAssertEqual(submitted, stopped)
        await gate.release()
        await fulfillment(of: [configured], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(box.runtime?.models.count, 0)
        let read = try await sessions.handle(.read(session: session))
        XCTAssertEqual(read, stopped)
        XCTAssertNil(read.providerSession)
    }

    func testSocketDisconnectDoesNotCloseConversationAndRestartCanReadIt() throws {
        let fixture = try CoreTestServer()
        let first = try fixture.connect()
        let session = SessionId()
        let reply = try first.request(.agentChat(.create(session: session, project: first.home(), provider: .codex)))
        guard case .agentChat(let original) = reply else { return XCTFail("Expected snapshot") }
        first.close()
        let second = try fixture.connect()
        XCTAssertEqual(try second.request(.agentChat(.read(session: session))), .agentChat(original))
        XCTAssertEqual(try second.request(.stopServer(force: false)), .serverBusy)
        XCTAssertEqual(try second.request(.stopServerIfIdle), .serverBusy)
        try fixture.restart()
        let reconnected = try fixture.connect()
        XCTAssertEqual(try reconnected.request(.agentChat(.read(session: session))), .agentChat(original))
        guard case .agentChat(let closed) = try reconnected.request(.agentChat(.close(session: session))) else {
            return XCTFail("Expected closed snapshot")
        }
        XCTAssertEqual(closed.status, .closed)
    }
}
