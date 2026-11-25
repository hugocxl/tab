import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

/// A provider that names its conversation and works until the test ends its turn.
private final class ResumeRuntime: AgentSessionRuntime, @unchecked Sendable {
    let resumed: String?
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    private let lock = NSLock()
    private var sent: [String] = []
    var texts: [String] { lock.withLock { sent } }

    init(resumed: String?, _ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.resumed = resumed
        self.callback = callback
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        lock.withLock { sent.append(text) }
        callback(.providerSession(resumed ?? "provider-conversation"))
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws {}
    func stop() {}
}

private final class ResumeRuntimes: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [ResumeRuntime] = []
    var all: [ResumeRuntime] { lock.withLock { made } }

    func make(_ resume: String?, _ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) -> any AgentSessionRuntime {
        let runtime = ResumeRuntime(resumed: resume, callback)
        lock.withLock { made.append(runtime) }
        return runtime
    }
}

final class AgentRestartResumeTests: XCTestCase {
    func testATurnTheServerStoppedCarriesOnWhenItStartsAgain() async throws {
        let root = try temporaryRoot()
        let first = ResumeRuntimes()
        let sessions = try make(root, first)
        let id = try await create(sessions)
        _ = try await sessions.handle(.send(session: id, text: "Refactor the parser", model: nil))
        _ = try await until(sessions, id) { $0.providerSession == "provider-conversation" && $0.status == .working }
        sessions.shutdown()

        let second = ResumeRuntimes()
        let restarted = try make(root, second)
        defer { restarted.shutdown() }
        let stopped = try await restarted.handle(.read(session: id))
        XCTAssertEqual(stopped.status, .failed, "Nothing runs before the server is set up")
        XCTAssertEqual(stopped.items.last?.text, AgentRestartResume.stoppedNotice)
        restarted.resumeWorkEndedByRestart()
        let resumed = try await until(restarted, id) { $0.status == .working && $0.items.last?.isRestartResume == true }
        XCTAssertEqual(resumed.items.filter { $0.kind == .user && !$0.isAutomaticTurn }.map(\.text), ["Refactor the parser"])
        XCTAssertEqual(resumed.items.last?.text, AgentRestartResume.note)
        try await eventually { second.all.first?.texts == [AgentRestartResume.prompt] }
        XCTAssertEqual(second.all.count, 1)
        XCTAssertEqual(second.all.first?.resumed, "provider-conversation", "The provider picks its own conversation up again")
    }

    func testATurnCutShortByACrashCarriesOn() async throws {
        let root = try temporaryRoot()
        let id = SessionId()
        var snapshot = AgentChatSnapshot(session: id, project: ProjectId(), provider: .claude)
        snapshot.providerSession = "crashed-conversation"
        snapshot.status = .working
        snapshot.items = [AgentChatItem(kind: .user, text: "Long job")]
        try write(snapshot, root: root)

        let runtimes = ResumeRuntimes()
        let sessions = try make(root, runtimes)
        defer { sessions.shutdown() }
        sessions.resumeWorkEndedByRestart()
        _ = try await until(sessions, id) { $0.status == .working && $0.items.last?.isRestartResume == true }
        try await eventually { runtimes.all.first?.resumed == "crashed-conversation" }
    }

    func testResumesThatGetNowhereStopAfterAFewTries() async throws {
        let root = try temporaryRoot()
        let id = SessionId()
        var snapshot = AgentChatSnapshot(session: id, project: ProjectId(), provider: .claude)
        snapshot.providerSession = "conversation"
        snapshot.status = .working
        snapshot.items = [AgentChatItem(kind: .user, text: "Long job"), AgentChatItem(kind: .assistant, text: "On it")]
            + (0 ..< AgentRestartResume.maxAttempts).flatMap { _ in [
                AgentChatItem(kind: .user, text: AgentRestartResume.note,
                              workContext: .init(itemType: AgentChatItem.restartResumeType)),
                AgentChatItem(kind: .notice, text: AgentRestartResume.stoppedNotice),
            ] }
        try write(snapshot, root: root)

        let runtimes = ResumeRuntimes()
        let sessions = try make(root, runtimes)
        defer { sessions.shutdown() }
        sessions.resumeWorkEndedByRestart()
        try await Task.sleep(for: .milliseconds(200))
        let loaded = try await sessions.handle(.read(session: id))
        XCTAssertEqual(loaded.status, .failed)
        XCTAssertEqual(loaded.items.last?.text, AgentRestartResume.interruptedNotice)
        XCTAssertTrue(runtimes.all.isEmpty)
    }

    func testATurnTheUserWasStoppingStaysStopped() async throws {
        let root = try temporaryRoot()
        let runtimes = ResumeRuntimes()
        let sessions = try make(root, runtimes)
        let id = try await create(sessions)
        _ = try await sessions.handle(.send(session: id, text: "Work", model: nil))
        _ = try await until(sessions, id) { $0.providerSession != nil }
        // The fake provider never confirms the stop, so the turn is still stopping.
        _ = try await sessions.handle(.interrupt(session: id))
        sessions.shutdown()

        let restarted = try make(root, ResumeRuntimes())
        defer { restarted.shutdown() }
        restarted.resumeWorkEndedByRestart()
        try await Task.sleep(for: .milliseconds(200))
        let loaded = try await restarted.handle(.read(session: id))
        XCTAssertEqual(loaded.status, .failed)
        XCTAssertFalse(loaded.items.contains(where: \.isRestartResume))
    }

    // MARK: Helpers

    private func make(_ root: URL, _ runtimes: ResumeRuntimes) throws -> AgentSessions {
        try AgentSessions(root: root, projectDirectory: { _ in root.path },
                          factory: { _, _, resume, callback in runtimes.make(resume, callback) })
    }

    private func create(_ sessions: AgentSessions) async throws -> SessionId {
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude, options: nil))
        return id
    }

    private func write(_ snapshot: AgentChatSnapshot, root: URL) throws {
        let saved = AgentSessions.Saved(snapshot: snapshot, directory: root.path)
        try JSONEncoder().encode(saved).write(to: root.appendingPathComponent(snapshot.session.description + ".json"))
    }

    private func until(_ sessions: AgentSessions, _ session: SessionId,
                       _ condition: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        var snapshot = try await sessions.handle(.read(session: session))
        for _ in 0 ..< 100 where !condition(snapshot) {
            try await Task.sleep(for: .milliseconds(20))
            snapshot = try await sessions.handle(.read(session: session))
        }
        XCTAssertTrue(condition(snapshot), "condition never held")
        return snapshot
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "condition never held")
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
