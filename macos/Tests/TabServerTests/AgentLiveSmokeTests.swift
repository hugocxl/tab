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

    func testGeminiLiveConversation() async throws {
        try await conversation(provider: .gemini)
    }

    /// OpenCode's free models need no account, so this one runs without charges.
    func testOpenCodeLiveConversation() async throws {
        try await conversation(provider: .openCode)
    }

    /// Installs Antigravity CLI from Google's manifest into a temporary home, then checks it there.
    func testAntigravityLiveInstallAndCheck() async throws {
        guard ["antigravity", "all"].contains(ProcessInfo.processInfo.environment["TAB_AGENT_LIVE_TESTS"] ?? "") else {
            throw XCTSkip("Set TAB_AGENT_LIVE_TESTS=antigravity; this downloads about 90 MB from Google.")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tab-agy-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = try await AgentProviderRelease.install(AgentChatProvider.antigravity.spec, home: home)
        XCTAssertTrue(log.contains("SHA-512 matches"), log)
        let agy = home.appendingPathComponent(".local/bin/agy")
        let health = AgentProviderStore.check(AgentProviderConfig(id: "antigravity", kind: .antigravity, executable: agy.path),
                                              environment: ["PATH": "/usr/bin:/bin", "HOME": home.path], now: Date())
        XCTAssertTrue(health.installed, health.message ?? "")
        XCTAssertNotNil(health.version)
        XCTAssertEqual(health.auth, .signedOut, "a new home has no Google sign-in")
        XCTAssertEqual(health.message, "Run `agy` in a terminal and sign in with Google, or add GEMINI_API_KEY under Variables.")
        let latest = await AgentProviderLatestVersions().latest(.manifest(try XCTUnwrap(AgentProviderRelease.manifestURL(
            AgentChatProvider.antigravity.spec.releaseManifest ?? ""))))
        XCTAssertEqual(latest, health.version, "a fresh install is the latest")
    }

    /// Lists an ACP agent's models the way the composer's menu does. Opening a session costs nothing.
    func testACPLiveModelCatalog() async throws {
        let selection = ProcessInfo.processInfo.environment["TAB_AGENT_LIVE_TESTS"]
        let kinds = AgentChatProvider.allCases.filter { $0.spec.wire == .acp && (selection == $0.rawValue || selection == "all") }
        guard !kinds.isEmpty else { throw XCTSkip("Set TAB_AGENT_LIVE_TESTS to an ACP provider, such as opencode or gemini.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-acp-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AgentModelCatalogService(home: URL(fileURLWithPath: NSHomeDirectory()), projectDirectory: { _ in directory })
        for kind in kinds {
            let reply = try await service.handle(.init(project: ProjectId(), provider: kind))
            XCTAssertFalse(reply.models.isEmpty, "\(kind.name) listed no models")
            XCTAssertEqual(reply.source, "live")
            XCTAssertEqual(reply.models.filter(\.isDefault).count, 1, "the session's current model is the default")
        }
    }

    private func makeRuntime(_ provider: AgentChatProvider, directory: URL, resume: String?,
                         events: LiveAgentEvents) -> any AgentSessionRuntime {
        provider.spec.wire == .acp
            ? AcpAgentRuntime(provider: provider, directory: directory.path, resumeSession: resume, onEvent: { events.receive($0) })
            : AgentRuntime(provider: provider, directory: directory.path, resumeSession: resume, onEvent: { events.receive($0) })
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
        let runtime = makeRuntime(provider, directory: directory, resume: nil, events: events)
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
        let resumed = makeRuntime(provider, directory: directory, resume: session, events: resumedEvents)
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

    private func turn(runtime: any AgentSessionRuntime, events: LiveAgentEvents, marker: String,
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
            case .commands, .commandDescriptors: break
            case .item(let item), .toolItem(let item, _), .itemUpdate(let item):
                switch item.kind {
                case .assistant: rows[item.id] = item.text
                case .tool where ["reasoning", "todo_list"].contains(item.workContext?.itemType ?? ""):
                    break
                case .approval, .tool:
                    error = "The no-tools prompt unexpectedly requested a tool or approval: \(item.text). No approval was sent."
                default: break
                }
            case .textDelta(let id, let text): rows[id, default: ""] += text
            case .providerSession(let id): session = id
            case .contextUsage, .resolvedModel, .providerMessage, .planMode, .subagents, .subagentSteps, .providerTurn, .activity, .turnUsage: break
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
