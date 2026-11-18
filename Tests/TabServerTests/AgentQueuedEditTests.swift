import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

/// A provider that starts a turn and keeps it running until told otherwise, counting
/// what reaches it.
private final class QueueRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    private let lock = NSLock()
    private var sent: [String] = []
    private var steered: [String] = []
    var sends: [String] { lock.withLock { sent } }
    var steers: [String] { lock.withLock { steered } }

    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.callback = callback }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        lock.withLock { sent.append(text) }
        callback(.providerSession("provider-session"))
    }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?, attachments: [StagedAgentAttachment]) async throws {
        try await send(text: text, model: model, reasoningEffort: reasoningEffort)
    }
    func steer(text: String, attachments: [StagedAgentAttachment]) async throws { lock.withLock { steered.append(text) } }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {}
}

private final class QueueRuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: QueueRuntime?
    var runtime: QueueRuntime? { lock.withLock { value } }
    func install(_ runtime: QueueRuntime) { lock.withLock { value = runtime } }
}

final class AgentQueuedEditTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-queue-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func sessions(_ root: URL, _ box: QueueRuntimeBox) throws -> AgentSessions {
        try AgentSessions(root: root, projectDirectory: { _ in root.path }, factory: { _, _, _, callback in
            let runtime = QueueRuntime(callback)
            box.install(runtime)
            return runtime
        })
    }

    private func wait(_ sessions: AgentSessions, _ id: SessionId, until predicate: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        for _ in 0..<300 {
            let snapshot = try await sessions.handle(.read(session: id))
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRuntimeError("The conversation did not settle")
    }

    private func png(_ byte: UInt8, name: String) -> AgentChatAttachment {
        AgentChatAttachment(name: name, mimeType: "image/png", data: Data([137, 80, 78, 71, byte]))
    }

    /// Starts a running turn, then queues `prompt` behind it.
    private func queue(_ prompt: AgentPrompt, in sessions: AgentSessions, project: ProjectId = ProjectId()) async throws -> SessionId {
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: project, provider: .codex))
        _ = try await sessions.handle(.submit(session: id, prompt: AgentPrompt(text: "Work", model: nil, effort: nil, provider: .codex, planMode: false)))
        _ = try await wait(sessions, id) { $0.status == .working && $0.queuedPrompts?.isEmpty == true }
        let queued = try await sessions.handle(.submit(session: id, prompt: prompt))
        XCTAssertEqual(queued.queuedPrompts?.map(\.id), [prompt.id])
        return id
    }

    func testReplacingAScreenshotIsAtomicAndAFailedSaveLeavesTheOriginalUsable() async throws {
        let root = try root(), box = QueueRuntimeBox()
        let sessions = try sessions(root, box)
        defer { sessions.shutdown() }
        let first = png(1, name: "First.png"), second = png(2, name: "Second.png")
        let prompt = AgentPrompt(text: "Compare these", model: nil, effort: nil, provider: .codex, planMode: false, attachments: [first, second])
        let id = try await queue(prompt, in: sessions)
        let replacement = png(3, name: "Replacement.png")

        // A save against a stale revision changes nothing.
        do {
            _ = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 9,
                edit: .init(text: "Compare again", keptAttachments: [first.id], addedAttachments: [replacement])))
            XCTFail("A stale revision must be rejected")
        } catch {}
        // So does one that names an attachment the prompt no longer has.
        do {
            _ = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 0,
                edit: .init(text: "Compare again", keptAttachments: ["gone"], addedAttachments: [replacement])))
            XCTFail("An unknown kept attachment must be rejected")
        } catch {}
        var current = try await sessions.handle(.read(session: id))
        XCTAssertEqual(current.queuedPrompts?.first?.revision, 0)
        XCTAssertEqual(current.queuedPrompts?.first?.attachments.map(\.id), [first.id, second.id])
        let original = try await sessions.attachment(.init(session: id, item: prompt.id, attachment: second.id))
        XCTAssertEqual(original.attachment.data, second.data, "The queued editor previews the server's bytes")

        // The retry replaces the second screenshot in one step.
        current = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 0,
            edit: .init(text: "Compare again", keptAttachments: [first.id], addedAttachments: [replacement])))
        let edited = try XCTUnwrap(current.queuedPrompts?.first)
        XCTAssertEqual(edited.text, "Compare again")
        XCTAssertEqual(edited.attachments.map(\.name), ["First.png", "Replacement.png"])
        XCTAssertEqual(edited.revision, 1)
        do {
            _ = try await sessions.attachment(.init(session: id, item: prompt.id, attachment: second.id))
            XCTFail("The replaced attachment is gone")
        } catch {}
        XCTAssertEqual(box.runtime?.sends, ["Work"], "Editing never delivers")

        // The edit survives a restart and is what the agent finally receives.
        sessions.shutdown()
        let restored = try self.sessions(root, box)
        defer { restored.shutdown() }
        let reread = try await restored.handle(.read(session: id))
        XCTAssertEqual(reread.queuedPrompts?.first?.attachments.map(\.name), ["First.png", "Replacement.png"])
        let bytes = try await restored.attachment(.init(session: id, item: prompt.id, attachment: replacement.id))
        XCTAssertEqual(bytes.attachment.data, replacement.data)
    }

    func testAnAttachmentOnlyPromptCanBeEditedButNeverEmptied() async throws {
        let root = try root(), box = QueueRuntimeBox()
        let sessions = try sessions(root, box)
        defer { sessions.shutdown() }
        let only = png(4, name: "Only.png")
        let prompt = AgentPrompt(text: "", model: nil, effort: nil, provider: .codex, planMode: false, attachments: [only])
        let id = try await queue(prompt, in: sessions)
        // The text-only edit can't express an empty text; the whole-prompt edit can.
        XCTAssertThrowsError(try AgentChatRequest.editQueued(session: id, id: prompt.id, text: "", expectedRevision: 0).validate())
        XCTAssertThrowsError(try AgentChatRequest.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 0,
                                                                   edit: .init(text: " ")).validate(), "An empty edit is refused before it travels")
        do {
            _ = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 0, edit: .init(text: "", keptAttachments: [])))
            XCTFail("An edit must not empty a prompt")
        } catch {}
        let kept = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 0,
                                                              edit: .init(text: "", settings: .init(model: "gpt", effort: .high, planMode: false),
                                                                          keptAttachments: [only.id])))
        XCTAssertEqual(kept.queuedPrompts?.first?.attachments.map(\.id), [only.id])
        XCTAssertEqual(kept.queuedPrompts?.first?.revision, 1)
        let described = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 1,
                                                                   edit: .init(text: "Describe it", keptAttachments: [])))
        XCTAssertEqual(described.queuedPrompts?.first?.text, "Describe it")
        XCTAssertEqual(described.queuedPrompts?.first?.attachments, [])
    }

    func testTwoClientsEditingTheSamePromptKeepTheLatestAndNeverResend() async throws {
        let root = try root(), box = QueueRuntimeBox()
        let sessions = try sessions(root, box)
        defer { sessions.shutdown() }
        let prompt = AgentPrompt(text: "Original", model: nil, effort: nil, provider: .codex, planMode: false)
        let id = try await queue(prompt, in: sessions)
        // Both clients open the editor at revision 0; the second saves first.
        let other = try await sessions.handle(.editQueued(session: id, id: prompt.id, text: "Other client", expectedRevision: 0))
        XCTAssertEqual(other.queuedPrompts?.first?.revision, 1)
        do {
            _ = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 0, edit: .init(text: "Mine")))
            XCTFail("The slower client's edit is stale")
        } catch {}
        // A retry of a save whose reply was lost is equally stale, never a second delivery.
        do { _ = try await sessions.handle(.editQueued(session: id, id: prompt.id, text: "Other client", expectedRevision: 0)); XCTFail() } catch {}
        let latest = try await sessions.handle(.read(session: id))
        XCTAssertEqual(latest.queuedPrompts?.map(\.text), ["Other client"])
        XCTAssertEqual(box.runtime?.sends, ["Work"])
        XCTAssertEqual(box.runtime?.steers, [])
        // Once it started, an edit can't change what the agent receives.
        _ = try await sessions.handle(.deliverQueued(session: id, id: prompt.id, expectedRevision: 1))
        do {
            _ = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 2, edit: .init(text: "Too late")))
            XCTFail("A delivering prompt can't be edited")
        } catch {}
        let delivered = try await wait(sessions, id) { $0.queuedPrompts?.isEmpty == true }
        XCTAssertEqual(delivered.items.filter { $0.kind == .user }.map(\.text), ["Work", "Other client"])
        XCTAssertEqual(box.runtime?.steers, ["Other client"])
    }

    func testEditKeepsAttachmentLimits() async throws {
        let root = try root(), box = QueueRuntimeBox()
        let sessions = try sessions(root, box)
        defer { sessions.shutdown() }
        let big = AgentChatAttachment(name: "Big.bin", mimeType: "application/octet-stream", data: Data(count: 5 * 1024 * 1024))
        let prompt = AgentPrompt(text: "Large", model: nil, effort: nil, provider: .codex, planMode: false, attachments: [big])
        let id = try await queue(prompt, in: sessions)
        let another = AgentChatAttachment(name: "Another.bin", mimeType: "application/octet-stream", data: Data(count: 4 * 1024 * 1024))
        do {
            _ = try await sessions.handle(.editQueuedPrompt(session: id, id: prompt.id, expectedRevision: 0,
                                                           edit: .init(text: "Large", keptAttachments: [big.id], addedAttachments: [another])))
            XCTFail("The edit must keep the 8 MB limit")
        } catch {}
        let current = try await sessions.handle(.read(session: id))
        XCTAssertEqual(current.queuedPrompts?.first?.attachments.map(\.id), [big.id])
    }
}
