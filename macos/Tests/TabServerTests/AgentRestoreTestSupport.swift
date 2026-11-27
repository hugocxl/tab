import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// A provider whose every message runs `turn` with the message's number across all its
/// conversations, then reports what `turn` returns: idle, or nothing for a turn left working.
final class ScriptedAgentRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    private let turn: @Sendable (Int, ScriptedAgentRuntime) throws -> AgentChatStatus?
    private let counter: ScriptCounter
    private let lock = NSLock()
    private var prepared: [AgentLaunch] = []
    var launches: [AgentLaunch] { lock.withLock { prepared } }

    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void, counter: ScriptCounter,
         turn: @escaping @Sendable (Int, ScriptedAgentRuntime) throws -> AgentChatStatus?) {
        self.callback = callback
        self.counter = counter
        self.turn = turn
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        let number = counter.next()
        if let status = try turn(number, self) { callback(.status(status)) }
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {}
    func prepare(_ launch: AgentLaunch) { lock.withLock { prepared.append(launch) } }
}

final class ScriptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Holds whoever waits on it until released, and says whether anyone came.
final class ScriptGate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var arrived = false
    private var open = false
    var reached: Bool { lock.withLock { arrived } }

    func wait() {
        let mustWait = lock.withLock { () -> Bool in arrived = true; return !open }
        if mustWait { released.wait(); released.signal() }
    }
    func release() {
        lock.withLock { open = true }
        released.signal()
    }
}

/// Settable from a test while a store hook reads it.
final class ScriptFlag<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension XCTestCase {
    func agentStorage() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func settle(_ sessions: AgentSessions, _ id: SessionId, timeout: Int = 500,
                until predicate: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        for _ in 0..<timeout {
            let snapshot = try await sessions.handle(.read(session: id))
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRuntimeError("The conversation did not settle")
    }

    func waitUntilTrue(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRuntimeError("The condition was not met")
    }

    /// What the server tells a client about `error`.
    func agentMessage(_ error: Error) -> String {
        (error as? ServiceError)?.message ?? error.localizedDescription
    }

    func contents(_ directory: String, _ path: String) -> String? {
        try? String(contentsOfFile: directory + "/" + path, encoding: .utf8)
    }

    func gitIndex(_ repo: GitTestRepo) throws -> Data {
        let path = try repo.run("rev-parse", "--path-format=absolute", "--git-path", "index").trimmingCharacters(in: .whitespacesAndNewlines)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
}
