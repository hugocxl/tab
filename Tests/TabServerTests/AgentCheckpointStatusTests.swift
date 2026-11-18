import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// Each turn says where recording its file changes stands: being recorded, ready with or
/// without changes, or unavailable with a reason, retryable only from its original baseline.
final class AgentCheckpointStatusTests: XCTestCase {
    private var repositories: [GitTestRepo] = []

    private func sessions(directory: String, store: AgentCheckpointStore = AgentCheckpointStore(),
                          change: @escaping @Sendable (Int) throws -> Void) throws -> AgentSessions {
        let storage = try agentStorage(), counter = ScriptCounter()
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, checkpointStore: store, factory: { _, _, _, callback in
            ScriptedAgentRuntime(callback, counter: counter) { number, _ in
                try change(number)
                return .idle
            }
        })
        addTeardownBlock { sessions.shutdown() }
        return sessions
    }

    private func repository() throws -> GitTestRepo {
        let repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        repositories.append(repo)
        return repo
    }

    func testAFolderOutsideGitSaysWhyItsChangesArentRecorded() async throws {
        let directory = try agentStorage().path
        let sessions = try sessions(directory: directory) { _ in
            try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
        }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Change it", model: nil))
        let snapshot = try await settle(sessions, id) { $0.turns?.first?.checkpointStatus?.state == .untracked }
        let turn = try XCTUnwrap(snapshot.turns?.first)
        XCTAssertNil(turn.checkpoint)
        XCTAssertEqual(turn.checkpointPhase, .untracked(
            reason: "This folder isn't in a Git repository, so Tab can't record the files a turn changes."))
        do {
            _ = try await sessions.conversation(.retryCheckpoint(session: id, turn: turn.userItemID))
            XCTFail("There is no baseline to try again from")
        } catch {}
    }

    func testACaptureErrorCanBeRetriedFromTheOriginalBaseline() async throws {
        let repo = try repository()
        let failAfter = ScriptFlag(false)
        var store = AgentCheckpointStore()
        store.willCapture = { _ in if failAfter.value { throw AgentRuntimeError("index.lock exists") } }
        let directory = repo.path
        let sessions = try sessions(directory: directory, store: store) { _ in
            try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
            failAfter.value = true // The baseline was taken; the turn's result fails.
        }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Change it", model: nil))
        let failed = try await settle(sessions, id) { $0.turns?.first?.checkpointStatus?.state == .unavailable }
        let turn = try XCTUnwrap(failed.turns?.first)
        XCTAssertEqual(turn.checkpointPhase, .unavailable(reason: "index.lock exists", retryable: true))

        failAfter.value = false
        guard case .snapshot(let retrying) = try await sessions.conversation(.retryCheckpoint(session: id, turn: turn.userItemID)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(retrying.turns?.first?.checkpointPhase, .capturing)
        let ready = try await settle(sessions, id) { $0.turns?.first?.checkpoint != nil }
        XCTAssertEqual(ready.turns?.first?.checkpointPhase, .changed)
        let diff = try await sessions.checkpoint(.init(session: id, checkpoint: turn.userItemID, path: "file.txt"))
        XCTAssertTrue(diff.diff?.rows.contains { $0.text == "-before" } == true, "Measured from the original baseline")
    }

    func testALaterTurnEndsTheChanceToRetryAnEarlierOne() async throws {
        let repo = try repository()
        let fail = ScriptFlag(false)
        var store = AgentCheckpointStore()
        store.willCapture = { _ in if fail.value { fail.value = false; throw AgentRuntimeError("busy") } }
        let directory = repo.path
        let sessions = try sessions(directory: directory, store: store) { number in
            try "turn \(number)\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
            if number == 1 { fail.value = true }
        }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "One", model: nil))
        _ = try await settle(sessions, id) { $0.turns?.first?.checkpointStatus?.retryable == true }
        _ = try await sessions.handle(.send(session: id, text: "Two", model: nil))
        let later = try await settle(sessions, id) { $0.turns?.count == 2 && $0.turns?.last?.checkpoint != nil }
        let first = try XCTUnwrap(later.turns?.first)
        XCTAssertEqual(first.checkpointPhase, .unavailable(reason: "busy", retryable: false))
        do {
            _ = try await sessions.conversation(.retryCheckpoint(session: id, turn: first.userItemID))
            XCTFail("Its result would include the later turn's work")
        } catch {}
    }

    func testADelayedResultIsCapturingAndAnUnchangedTurnIsReadyWithNoChanges() async throws {
        let repo = try repository()
        let gate = ScriptGate(), hold = ScriptFlag(false)
        var store = AgentCheckpointStore()
        store.willCapture = { _ in if hold.value { gate.wait() } }
        let directory = repo.path
        let sessions = try sessions(directory: directory, store: store) { number in
            if number == 1 { hold.value = true } // The first turn changes nothing; its result is slow.
        }
        defer { gate.release() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Look only", model: nil))
        try await waitUntilTrue { gate.reached }
        let pending = try await settle(sessions, id) { $0.status == .idle }
        XCTAssertEqual(pending.turns?.first?.checkpointPhase, .capturing, "Still being recorded, not unavailable")
        gate.release()
        let ready = try await settle(sessions, id) { $0.turns?.first?.checkpoint != nil }
        XCTAssertEqual(ready.turns?.first?.checkpointPhase, .unchanged)
        XCTAssertEqual(ready.turns?.first?.checkpoint?.totalFiles, 0)
    }

    func testRestartResumesAPendingCaptureAndMarksALostOneUnavailable() async throws {
        let repo = try repository()
        let storage = try agentStorage()
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        try repo.write("file.txt", "after\n")
        let id = SessionId(), resumable = UUID().uuidString, lost = UUID().uuidString
        let folder = storage.appendingPathComponent("checkpoints/" + id.description)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(AgentCheckpointPending(turnID: resumable, before: before))
            .write(to: folder.appendingPathComponent("pending-" + resumable + ".json"))
        let started = Date(timeIntervalSince1970: 100)
        var first = AgentChatTurn(userItemID: lost, startedAt: started, completedAt: started.addingTimeInterval(1), status: .idle)
        first.checkpointStatus = .init(state: .capturing)
        var second = AgentChatTurn(userItemID: resumable, startedAt: started.addingTimeInterval(2),
                                   completedAt: started.addingTimeInterval(3), status: .idle)
        second.checkpointStatus = .init(state: .capturing)
        let snapshot = AgentChatSnapshot(session: id, project: ProjectId(), provider: .codex, turns: [first, second], status: .idle,
            items: [.init(id: lost, kind: .user, text: "One"), .init(id: resumable, kind: .user, text: "Two")])
        let snapshotJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        try JSONSerialization.data(withJSONObject: ["snapshot": snapshotJSON, "directory": repo.path])
            .write(to: storage.appendingPathComponent(id.description + ".json"))
        let directory = repo.path
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory })
        defer { sessions.shutdown() }
        let recovered = try await settle(sessions, id) { $0.turns?.last?.checkpoint != nil }
        XCTAssertEqual(recovered.turns?.last?.checkpointPhase, .changed, "The persisted pending capture resumed")
        XCTAssertEqual(recovered.turns?.first?.checkpointPhase, .unavailable(
            reason: "Tab stopped before this turn's file changes were recorded.", retryable: false))
    }

    /// Older servers send no status: a checkpoint alone means ready, and none means unknown.
    func testOlderServersTurnsReadFromTheirCheckpointAlone() throws {
        var turn = AgentChatTurn(userItemID: UUID().uuidString, startedAt: Date())
        XCTAssertEqual(turn.checkpointPhase, .unknown)
        turn.checkpoint = AgentTurnCheckpoint(id: turn.userItemID, files: [], totalFiles: 0, additions: 0, deletions: 0)
        XCTAssertEqual(turn.checkpointPhase, .unchanged)
        let decoded = try JSONDecoder().decode(AgentChatTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertNil(decoded.checkpointStatus)
        XCTAssertNil(decoded.rewindable)
        // A future state reads as unavailable rather than failing to decode.
        let future = try JSONDecoder().decode(AgentTurnCheckpointStatus.self, from: Data(#"{"state":"verifying","reason":"Later"}"#.utf8))
        turn.checkpoint = nil
        turn.checkpointStatus = future
        XCTAssertEqual(turn.checkpointPhase, .unavailable(reason: "Later", retryable: false))
        XCTAssertLessThanOrEqual(AgentTurnCheckpointStatus(state: .unavailable, reason: String(repeating: "é", count: 600)).reason?.utf8.count ?? 0,
                                 AgentTurnCheckpointStatus.maxReasonBytes)
    }

    /// Review context comes from the checkpoint's own trees, never the working file.
    func testExpandedContextReadsTheCheckpointsHistoricalFiles() async throws {
        let repo = try GitTestRepo(commit: false)
        repositories.append(repo)
        let lines = (1...40).map { "line \($0)" }
        try repo.write("file.txt", lines.joined(separator: "\n") + "\n")
        try repo.write("gone.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n")
        try repo.commit("initial")
        let directory = repo.path
        let sessions = try sessions(directory: directory) { _ in
            var changed = lines
            changed[19] = "line 20 changed"
            try (changed.joined(separator: "\n") + "\n").write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: directory + "/gone.txt")
        }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "Change it", model: nil))
        let done = try await settle(sessions, id) { $0.turns?.first?.checkpoint != nil }
        let checkpoint = try XCTUnwrap(done.turns?.first?.checkpoint?.id)
        // The working file changes after the checkpoint.
        try repo.write("file.txt", "rewritten entirely\n")
        let usual = try await sessions.checkpoint(.init(session: id, checkpoint: checkpoint, path: "file.txt"))
        XCTAssertEqual(usual.context, 3)
        XCTAssertEqual(usual.diff?.rows.filter { $0.kind == .context }.count, 6)
        let whole = try await sessions.checkpoint(.init(session: id, checkpoint: checkpoint, path: "file.txt", context: AgentCheckpointRequest.wholeFile))
        XCTAssertEqual(whole.context, AgentCheckpointRequest.wholeFile)
        let rows = try XCTUnwrap(whole.diff?.rows.filter { $0.kind != .hunk })
        XCTAssertEqual(rows.filter { $0.kind == .context }.count, 39)
        XCTAssertEqual(rows.first?.text, " line 1")
        XCTAssertEqual(rows.last?.text, " line 40")
        XCTAssertFalse(rows.contains { $0.text.contains("rewritten") }, "Source lines stay historical")
        let deleted = try await sessions.checkpoint(.init(session: id, checkpoint: checkpoint, path: "gone.txt", context: 25))
        XCTAssertEqual(deleted.diff?.rows.filter { $0.kind == .deletion }.count, 8)
        XCTAssertTrue(deleted.diff?.rows.allSatisfy { $0.kind != .addition } == true)
    }
}
