import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// Opt-in only: these tests use the installed CLI's account and may incur charges.
final class AgentLiveSmokeTests: XCTestCase {
    func testClaudeLiveConversation() async throws {
        try await conversation(provider: .claude)
    }

    func testCodexLiveConversation() async throws {
        try await conversation(provider: .codex)
    }

    private func conversation(provider: AgentChatProvider) async throws {
        let selection = ProcessInfo.processInfo.environment["TAB_AGENT_LIVE_TESTS"]
        guard selection == provider.rawValue || selection == "all" else {
            throw XCTSkip("Live provider tests are disabled. Set TAB_AGENT_LIVE_TESTS=\(provider.rawValue) or all; this may incur charges.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tab-agent-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        let events = LiveAgentEvents(provider: provider)
        let runtime = AgentRuntime(provider: provider, directory: directory.path,
                                   resumeSession: nil, onEvent: { events.receive($0) })
        defer { runtime.stop() }

        try await turn(runtime: runtime, events: events, marker: "TAB_AGENT_OK", reasoningEffort: .low)
        let session = try XCTUnwrap(events.providerSession,
                                   "\(provider.name) completed without a provider session ID. \(events.diagnostic)")
        XCTAssertFalse(session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        try await turn(runtime: runtime, events: events, marker: "TAB_AGENT_FOLLOWUP_OK", reasoningEffort: .medium,
                       prompt: "Reply with TAB_AGENT_FOLLOWUP_OK followed by the exact marker I asked for in my FIRST message. Do not use tools or modify files.")
        XCTAssertTrue(events.assistantText.contains("TAB_AGENT_OK"),
                      "Changing effort on the same runtime must retain conversation context. \(events.diagnostic)")
        XCTAssertEqual(events.providerSession, session,
                       "\(provider.name) unexpectedly changed conversation IDs on the second turn. \(events.diagnostic)")

        runtime.stop()
        let resumedEvents = LiveAgentEvents(provider: provider)
        let resumed = AgentRuntime(provider: provider, directory: directory.path,
                                   resumeSession: session, onEvent: { resumedEvents.receive($0) })
        defer { resumed.stop() }
        try await turn(runtime: resumed, events: resumedEvents, marker: "TAB_AGENT_RESUMED_OK",
                       reasoningEffort: .high,
                       prompt: "Reply with TAB_AGENT_RESUMED_OK followed by the exact marker I asked for in my FIRST message in this conversation. Do not use any tools or modify any files.")
        XCTAssertEqual(resumedEvents.providerSession, session,
                       "The new agent process must resume the original provider conversation.")
        XCTAssertTrue(resumedEvents.assistantText.contains("TAB_AGENT_OK"),
                      "Resuming must retain the previous conversation, not just its identifier. \(resumedEvents.diagnostic)")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                      "The no-tools smoke conversation created files in its empty working directory.")
    }

    private func turn(runtime: AgentRuntime, events: LiveAgentEvents, marker: String,
                      reasoningEffort: AgentReasoningEffort? = nil, prompt: String? = nil) async throws {
        let finished = events.begin(marker: marker)
        let sending = Task {
            do {
                try await runtime.send(text: prompt ?? "Reply exactly \(marker). Do not use any tools or modify any files.",
                                       model: nil, reasoningEffort: reasoningEffort)
                events.sent()
            } catch {
                events.fail("Sending the prompt failed: \(error)")
            }
        }
        defer { sending.cancel() }

        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 90)
        guard result == .completed else {
            throw LiveAgentSmokeError(message: "Timed out waiting for \(marker). Check that the provider CLI is installed, authenticated, and reachable on PATH. \(events.diagnostic)")
        }
        if let failure = events.failure {
            throw LiveAgentSmokeError(message: "\(failure) Check CLI authentication and provider availability. \(events.diagnostic)")
        }
        XCTAssertTrue(events.assistantText.contains(marker),
                      "The completed turn did not contain \(marker). \(events.diagnostic)")
    }
}

private struct LiveAgentSmokeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// The callback is synchronous and can arrive on a provider's reader queue.
private final class LiveAgentEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let provider: AgentChatProvider
    private var session: String?
    private var rows: [String: String] = [:]
    private var expected: XCTestExpectation?
    private var error: String?
    private var sawWorking = false
    private var completed = false
    private var sendReturned = false
    private var fulfilled = false
    private var statuses: [String] = []

    init(provider: AgentChatProvider) { self.provider = provider }

    var providerSession: String? { locked { session } }
    var assistantText: String { locked { rows.values.joined(separator: "\n") } }
    var failure: String? { locked { error } }
    var diagnostic: String {
        locked {
            "Provider: \(provider.name); session: \(session ?? "none"); statuses: \(statuses.joined(separator: ", ")); send returned: \(sendReturned); assistant: \(rows.values.joined(separator: "\n").prefix(2000))"
        }
    }

    func begin(marker: String) -> XCTestExpectation {
        locked {
            let expectation = XCTestExpectation(description: "\(provider.name) successfully completes \(marker)")
            expected = expectation
            rows.removeAll()
            error = nil
            sawWorking = false
            completed = false
            sendReturned = false
            fulfilled = false
            statuses.removeAll()
            return expectation
        }
    }

    func receive(_ event: AgentRuntimeEvent) {
        locked {
            switch event {
            case .item(let item):
                switch item.kind {
                case .assistant: rows[item.id] = item.text
                case .approval, .tool:
                    error = "The no-tools prompt unexpectedly requested a tool or approval: \(item.text). No approval was sent."
                default: break
                }
            case .textDelta(let id, let text): rows[id, default: ""] += text
            case .providerSession(let id): session = id
            case .contextUsage, .resolvedModel: break
            case .failure(let message): error = message
            case .status(let status):
                statuses.append(status.rawValue)
                switch status {
                case .working: sawWorking = true
                case .idle: completed = sawWorking
                case .waiting: error = "Provider is waiting for input or permission; the smoke test never approves tools."
                case .failed, .closed:
                    if error == nil { error = "Provider ended with status \(status.rawValue)." }
                }
            }
            settle()
        }
    }

    func sent() {
        locked {
            sendReturned = true
            settle()
        }
    }

    func fail(_ message: String) {
        locked {
            error = message
            settle()
        }
    }

    private func settle() {
        guard !fulfilled, let expected, error != nil || (completed && sendReturned) else { return }
        fulfilled = true
        expected.fulfill()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
