import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// Edit as New Prompt, Edit from Here, revert availability and turn recording states in the pane.
@MainActor
final class AgentRewindPaneTests: XCTestCase {
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not met", file: file, line: line)
    }

    private final class Recorder {
        var requests: [AgentConversationRequest] = []
    }

    private let session = SessionId(), project = ProjectId()

    private func checkpoint(_ id: String, files: Int) -> AgentTurnCheckpoint {
        AgentTurnCheckpoint(id: id, files: (0..<files).map { .init(path: "file\($0).swift", additions: 1, deletions: 0) },
                            totalFiles: files, additions: UInt64(files), deletions: 0)
    }

    /// Three Claude turns; the second message has an image and a file attached.
    private func conversation(provider: AgentChatProvider = .claude, rewindable: Bool? = true,
                              recorded: Bool = true) -> AgentChatSnapshot {
        let ids = (0..<3).map { _ in UUID().uuidString }
        let image = AgentChatAttachmentDescriptor(id: "image", name: "screen.png", mimeType: "image/png", byteCount: 4)
        let notes = AgentChatAttachmentDescriptor(id: "notes", name: "notes.txt", mimeType: "text/plain", byteCount: 5)
        let items: [AgentChatItem] = [
            .init(id: ids[0], kind: .user, text: "Message 1"), .init(kind: .assistant, text: "Answer 1"),
            .init(id: ids[1], kind: .user, text: "Message 2", attachments: [image, notes]), .init(kind: .assistant, text: "Answer 2"),
            .init(id: ids[2], kind: .user, text: "Message 3"), .init(kind: .assistant, text: "Answer 3"),
        ]
        let turns = ids.enumerated().map { index, id -> AgentChatTurn in
            var turn = AgentChatTurn(userItemID: id, startedAt: Date(timeIntervalSince1970: Double(index)),
                                     completedAt: Date(timeIntervalSince1970: Double(index) + 1), status: .idle)
            turn.rewindable = rewindable
            if recorded || index == 0 {
                turn.checkpoint = checkpoint(id, files: index + 1)
                turn.checkpointStatus = .init(state: .ready)
            } else {
                turn.checkpointStatus = .init(state: .unavailable, reason: "index.lock exists", retryable: false)
            }
            return turn
        }
        return AgentChatSnapshot(session: session, project: project, provider: provider, turns: turns, status: .idle, revision: 7, items: items)
    }

    private func pane(_ snapshot: AgentChatSnapshot) async throws -> AgentPaneController {
        _ = NSApplication.shared
        let pane = AgentPaneController(session: session, project: project, provider: snapshot.provider) { _ in snapshot }
        addTeardownBlock { pane.dispose() }
        pane.conversationRequest = { _ in throw ClientError.server(ErrorReply(code: .unsupported, message: "")) }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        return pane
    }

    func testEditAsNewPromptRestoresAttachmentsAndNamesMissingOnes() async throws {
        var snapshot = conversation()
        let imageOnly = AgentChatItem(id: UUID().uuidString, kind: .user, text: "",
                                      attachments: [.init(id: "image", name: "only.png", mimeType: "image/png", byteCount: 4)])
        snapshot.items.append(imageOnly)
        let pane = try await pane(snapshot)
        pane.surface.fetchAttachment = { _, descriptor in
            guard descriptor.id == "image" else { throw ModelError("expired") }
            return Data([0x89, 0x50, 0x4E, 0x47])
        }
        pane.surface.composer.string = "Keep this"
        pane.editAsNewPrompt(snapshot.items[2])
        XCTAssertEqual(pane.surface.composer.string, "Keep this\n\nMessage 2", "The draft is added to, never replaced")
        try await wait { pane.draftAttachments.count == 1 }
        XCTAssertEqual(pane.draftAttachments.map(\.name), ["screen.png"])
        XCTAssertEqual(pane.draftAttachments.first?.data, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(pane.notice?.text, "An attachment is no longer available and wasn't added: “notes.txt”.")

        // A message that is only an image can be edited too.
        pane.editAsNewPrompt(imageOnly)
        try await wait { pane.draftAttachments.map(\.name) == ["screen.png", "only.png"] }
        XCTAssertEqual(pane.surface.composer.string, "Keep this\n\nMessage 2")
    }

    func testEditFromHereShowsTheTurnsAsksAboutFilesAndKeepsTheDraft() async throws {
        let snapshot = conversation()
        let pane = try await pane(snapshot)
        pane.surface.fetchAttachment = { _, _ in Data("bytes".utf8) }
        let recorder = Recorder()
        var plans: [AgentRewindPlan] = []
        pane.chooseRewind = { plan in plans.append(plan); return .restoreFiles }
        var confirmations: [String] = []
        pane.confirmDestructive = { title, _, _ in confirmations.append(title); return true }
        var rewound = snapshot
        rewound.items = Array(snapshot.items.prefix(2))
        rewound.turns = Array(snapshot.turns?.prefix(1) ?? [])
        rewound.revision = 8
        rewound.resetID = SessionId()
        pane.conversationRequest = { request in
            recorder.requests.append(request)
            guard case .rewind(_, _, _, _, _, let force) = request else { throw ClientError.server(ErrorReply(code: .unsupported, message: "")) }
            return .rewound(force ? AgentRewindReply(snapshot: rewound, files: .init(reverted: ["file0.swift", "file1.swift"]))
                                  : AgentRewindReply(snapshot: nil, files: .init(conflicts: ["file1.swift"])))
        }
        pane.surface.composer.string = "My unfinished draft"
        pane.editFromHere(snapshot.items[2])
        try await wait { pane.snapshot?.revision == 8 }
        try await wait { pane.draftAttachments.count == 2 }

        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.turns.map(\.userItemID), Array(snapshot.turns?.suffix(2).map(\.userItemID) ?? []))
        XCTAssertEqual(plan.messages, ["Message 2", "Message 3"])
        XCTAssertEqual(plan.changedFiles, 5)
        XCTAssertTrue(plan.canRestoreFiles)
        XCTAssertTrue(plan.summary.contains("The whole conversation is kept in history"))
        XCTAssertEqual(confirmations, ["1 file changed after these turns"])
        let at = snapshot.items[2].id
        guard recorder.requests.count == 2, case .rewind(let s1, let a1, let archive1, let r1, true, false) = recorder.requests[0],
              case .rewind(let s2, let a2, let archive2, let r2, true, true) = recorder.requests[1] else {
            return XCTFail("Unexpected requests: \(recorder.requests)")
        }
        XCTAssertEqual([s1, s2], [session, session])
        XCTAssertEqual([a1, a2], [at, at])
        XCTAssertEqual(archive1, archive2, "A forced retry keeps the same archive")
        XCTAssertEqual([r1, r2], [7, 7], "Both are checked against the conversation the user saw")
        XCTAssertEqual(pane.surface.composer.string, "My unfinished draft\n\nMessage 2", "The occupied draft is kept")
        XCTAssertEqual(pane.draftAttachments.map(\.name), ["screen.png", "notes.txt"])
        XCTAssertEqual(pane.notice?.text, "Rewound and restored 2 files. The message is in the composer.")
    }

    func testEditFromHereCancelledOrFailingChangesNothing() async throws {
        let snapshot = conversation()
        let pane = try await pane(snapshot)
        pane.surface.fetchAttachment = { _, _ in Data("bytes".utf8) }
        let recorder = Recorder()
        pane.conversationRequest = { request in
            recorder.requests.append(request)
            throw ModelError("Couldn't restore file1.swift: read-only volume No files were changed.")
        }
        pane.surface.composer.string = "Draft"
        var asked = 0
        pane.chooseRewind = { _ in asked += 1; return nil }
        pane.editFromHere(snapshot.items[4])
        try await wait { asked == 1 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(recorder.requests.isEmpty, "Cancelling sends nothing")

        pane.chooseRewind = { _ in .restoreFiles }
        pane.editFromHere(snapshot.items[4])
        try await wait { pane.notice?.text.hasPrefix("Couldn't edit from here") == true }
        XCTAssertEqual(pane.notice?.text, "Couldn't edit from here: Couldn't restore file1.swift: read-only volume No files were changed.")
        XCTAssertEqual(pane.surface.composer.string, "Draft")
        XCTAssertTrue(pane.draftAttachments.isEmpty)
        XCTAssertEqual(pane.snapshot?.items.count, 6, "The transcript stays as the server has it")

        pane.conversationRequest = { _ in throw ClientError.server(ErrorReply(code: .unsupported, message: "")) }
        pane.editFromHere(snapshot.items[4])
        try await wait { pane.notice?.text.hasPrefix("This server can't rewind") == true }
        XCTAssertEqual(pane.surface.composer.string, "Draft")
    }

    func testEditFromHereIsOfferedOnlyWhereTheConversationCanBeRewound() async throws {
        let codex = try await pane(conversation(provider: .codex, rewindable: false))
        var offered: [String?] = []
        codex.chooseEditMode = { _, unavailable in offered.append(unavailable); return nil }
        codex.chooseEdit(try XCTUnwrap(codex.snapshot?.items[2]))
        try await wait { offered.count == 1 }
        XCTAssertEqual(offered.last, "Codex can't continue from an earlier message. Use Edit as New Prompt instead.")
        codex.editFromHere(try XCTUnwrap(codex.snapshot?.items[2]))
        XCTAssertEqual(codex.notice?.text, "Edit from Here is unavailable. Codex can't continue from an earlier message. Use Edit as New Prompt instead.")

        let older = try await pane(conversation(rewindable: nil))
        older.chooseEditMode = { _, unavailable in offered.append(unavailable); return .asNewPrompt }
        older.chooseEdit(try XCTUnwrap(older.snapshot?.items[0]))
        try await wait { older.surface.composer.string == "Message 1" }
        XCTAssertEqual(offered.last, "This server can't rewind a conversation. Update Tab on it, then restart it.")

        // Without a checkpoint for every removed turn, files can only be kept.
        let unrecorded = conversation(recorded: false)
        guard case .success(let plan) = AgentRewindPlan.make(unrecorded, item: unrecorded.items[2]) else { return XCTFail("Rewindable") }
        XCTAssertFalse(plan.canRestoreFiles)
        XCTAssertEqual(plan.restoreUnavailable, "Turn 2's changes weren't recorded: index.lock exists")
        XCTAssertTrue(plan.summary.contains("Files stay as they are. Turn 2's changes weren't recorded"))
        var working = conversation()
        working.status = .working
        guard case .failure(let busy) = AgentRewindPlan.make(working, item: working.items[2]) else { return XCTFail("Busy") }
        XCTAssertEqual(busy.reason, "Stop active work and remove queued prompts before editing from here.")
    }

    func testRevertExplainsWhyItIsUnavailableAndWhenFilesAreAlreadyReverted() async throws {
        var snapshot = conversation()
        snapshot.status = .working
        let pane = try await pane(snapshot)
        let recorder = Recorder()
        pane.confirmDestructive = { _, _, _ in true }
        pane.conversationRequest = { request in
            recorder.requests.append(request)
            return .revert(AgentRevertReply(unchanged: ["file0.swift"]))
        }
        let checkpoint = try XCTUnwrap(snapshot.turns?.first?.checkpoint)
        pane.revertTurn(checkpoint, paths: nil)
        XCTAssertEqual(pane.notice?.text, "Revert is unavailable. Stop the agent first: it may be changing these files.")
        XCTAssertTrue(recorder.requests.isEmpty)

        XCTAssertNil(AgentRevertAvailability.reason(conversation(), submitting: false))
        var agents = conversation()
        agents.subagents = [AgentSubagent(id: "a", description: "Edit in the background", background: true)]
        XCTAssertEqual(AgentRevertAvailability.reason(agents, submitting: false),
                       "This conversation's agents are still running and may change these files. Wait for them or stop them first.")
        XCTAssertEqual(AgentRevertAvailability.outcome(AgentRevertReply(unchanged: ["a"])), "Already reverted: the file is as it was before this turn.")
        XCTAssertEqual(AgentRevertAvailability.outcome(AgentRevertReply(reverted: ["a"], unchanged: ["b", "c"])),
                       "Reverted 1 file. 2 files were already as before.")
    }

    func testChangesCardShowsRecordingStatesAndRetriesOnlyWhenItCan() throws {
        let row = AgentChangedFilesRow(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        var retried: [String] = []
        row.onRetryCheckpoint = { retried.append($0) }
        row.turnID = "turn"
        func labels() -> [String] { row.subviews.compactMap { ($0 as? NSTextField)?.isHidden == false ? ($0 as? NSTextField)?.stringValue : nil } }
        func retry() -> PillButton? { row.subviews.compactMap { $0 as? PillButton }.first { $0.title == "Retry" } }

        row.phase = .capturing
        row.layoutRow(width: 600)
        XCTAssertTrue(labels().contains("Recording file changes…"))
        XCTAssertEqual(retry()?.isHidden, true)
        XCTAssertEqual(row.preferredHeight(for: 600), 40)

        row.phase = .unavailable(reason: "index.lock exists", retryable: true)
        row.layoutRow(width: 600)
        XCTAssertTrue(labels().contains("File changes unavailable"))
        XCTAssertTrue(labels().contains("index.lock exists"))
        XCTAssertEqual(retry()?.isHidden, false)
        retry()?.perform()
        XCTAssertEqual(retried, ["turn"])

        row.phase = .unavailable(reason: "The turn's original baseline is gone.", retryable: false)
        row.layoutRow(width: 600)
        XCTAssertEqual(retry()?.isHidden, true, "No retry without the original baseline")

        row.phase = .untracked(reason: "This folder isn't in a Git repository.")
        row.layoutRow(width: 600)
        XCTAssertTrue(labels().contains("File changes aren't recorded"))

        XCTAssertFalse(AgentChatTurn.CheckpointPhase.unchanged.showsCard, "A turn that changed nothing shows no card")
        var running = AgentChatTurn(userItemID: "t", startedAt: Date())
        running.checkpointStatus = .init(state: .capturing)
        XCTAssertEqual(running.reviewPhase, .unknown, "Nothing shows while the turn still works")
    }
}
