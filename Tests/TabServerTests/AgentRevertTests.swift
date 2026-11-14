import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// Reverting a turn restores its files from the before checkpoint, refuses files changed
/// since unless forced, and never touches the index or files outside the turn.
final class AgentRevertTests: XCTestCase {
    private func turn(_ repo: GitTestRepo, _ change: () throws -> Void) throws
        -> (store: AgentCheckpointStore, before: AgentCheckpointStore.Snapshot, after: AgentCheckpointStore.Snapshot, paths: [String]) {
        let store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        try change()
        let after = try store.capture(directory: repo.path)
        addTeardownBlock { try? store.remove(before); try? store.remove(after) }
        return (store, before, after, try store.files(from: before, to: after).map(\.path))
    }

    private func read(_ repo: GitTestRepo, _ path: String) -> String? {
        try? String(contentsOfFile: repo.path + "/" + path, encoding: .utf8)
    }

    func testRevertRestoresEditedDeletedAndRemovesAddedFilesOnly() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("edited.txt", "original\n")
        try repo.write("deleted.txt", "keep me\n")
        try repo.write("untouched.txt", "same\n")
        try repo.commit("initial")
        try repo.write("staged.txt", "in the index\n")
        try repo.run("add", "staged.txt")
        let indexPath = try repo.run("rev-parse", "--path-format=absolute", "--git-path", "index").trimmingCharacters(in: .whitespacesAndNewlines)
        let index = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let change = try turn(repo) {
            try repo.write("edited.txt", "changed by the agent\n")
            try FileManager.default.removeItem(atPath: repo.path + "/deleted.txt")
            try repo.write("added/new.txt", "new\n")
        }
        XCTAssertEqual(Set(change.paths), ["edited.txt", "deleted.txt", "added/new.txt"])
        // A file outside the turn changes meanwhile and must stay as it is.
        try repo.write("untouched.txt", "changed later\n")
        XCTAssertEqual(try change.store.changedSince(change.after, paths: change.paths), [])
        try change.store.restore(change.before, paths: change.paths)
        XCTAssertEqual(read(repo, "edited.txt"), "original\n")
        XCTAssertEqual(read(repo, "deleted.txt"), "keep me\n")
        XCTAssertNil(read(repo, "added/new.txt"), "A file the turn added is removed")
        XCTAssertEqual(read(repo, "untouched.txt"), "changed later\n")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: indexPath)), index, "The index is untouched")
        XCTAssertEqual(try repo.run("show", ":staged.txt"), "in the index\n")
    }

    func testAFolderOrALinkedFolderInTheWayIsNeverReplaced() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("plain.txt", "original\n")
        try repo.write("nested/inner.txt", "original\n")
        try repo.commit("initial")
        let change = try turn(repo) {
            try repo.write("plain.txt", "changed\n")
            try repo.write("nested/inner.txt", "changed\n")
        }
        // The user replaced a changed file with a folder holding their own work.
        try FileManager.default.removeItem(atPath: repo.path + "/plain.txt")
        try repo.write("plain.txt/mine.txt", "mine\n")
        XCTAssertThrowsError(try change.store.restore(change.before, paths: change.paths))
        XCTAssertEqual(read(repo, "plain.txt/mine.txt"), "mine\n")
        XCTAssertEqual(read(repo, "nested/inner.txt"), "changed\n", "A refusal reverts nothing")

        // A folder on the way now links outside the project.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tab-revert-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try "theirs\n".write(to: outside.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: repo.path + "/nested")
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/nested", withDestinationPath: outside.path)
        XCTAssertThrowsError(try change.store.restore(change.before, paths: ["nested/inner.txt"]))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("inner.txt"), encoding: .utf8), "theirs\n")
    }

    func testFilesChangedSinceTheTurnAreRefusedUnlessForced() throws {
        let repo = try GitTestRepo(commit: false)
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "two\n")
        try repo.commit("initial")
        let change = try turn(repo) {
            try repo.write("a.txt", "agent one\n")
            try repo.write("b.txt", "agent two\n")
        }
        try repo.write("b.txt", "my own edit\n")
        XCTAssertEqual(try change.store.changedSince(change.after, paths: change.paths), ["b.txt"])
        // Force reverts it anyway, as the user confirmed.
        try change.store.restore(change.before, paths: ["b.txt"])
        XCTAssertEqual(read(repo, "b.txt"), "two\n")
        XCTAssertEqual(read(repo, "a.txt"), "agent one\n", "Only the chosen file changes")
        XCTAssertThrowsError(try change.store.restore(change.before, paths: ["../escape.txt"]))
    }

    func testConversationRevertRefusesThenForcesAndRecordsANotice() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("agent-revert-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, factory: { _, _, _, callback in
            AgentRevertRuntime(callback) {
                try "after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                try "added\n".write(toFile: directory + "/added.txt", atomically: true, encoding: .utf8)
            }
        })
        defer { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .codex))
        _ = try await sessions.handle(.send(session: id, text: "change it", model: nil))
        var snapshot = try await sessions.handle(.read(session: id))
        for _ in 0..<100 where snapshot.turns?.last?.checkpoint == nil {
            try await Task.sleep(for: .milliseconds(30))
            snapshot = try await sessions.handle(.read(session: id))
        }
        let checkpoint = try XCTUnwrap(snapshot.turns?.last?.checkpoint)
        try "edited after\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
        guard case .revert(let refused) = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint.id, paths: nil, force: false)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(refused.conflicts, ["file.txt"])
        XCTAssertEqual(refused.reverted, [])
        XCTAssertEqual(read(repo, "added.txt"), "added\n", "A refused revert changes nothing")
        guard case .revert(let forced) = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint.id, paths: nil, force: true)) else {
            return XCTFail("Unexpected reply")
        }
        XCTAssertEqual(Set(forced.reverted), ["file.txt", "added.txt"])
        XCTAssertEqual(read(repo, "file.txt"), "before\n")
        XCTAssertNil(read(repo, "added.txt"))
        do {
            _ = try await sessions.conversation(.revert(session: id, checkpoint: checkpoint.id, paths: ["other.txt"], force: true))
            XCTFail("Only the turn's files can be reverted")
        } catch {}
        try await Task.sleep(for: .milliseconds(50))
        let after = try await sessions.handle(.read(session: id))
        XCTAssertTrue(after.items.contains { $0.kind == .notice && $0.text == "Reverted 2 files to before a turn." })
    }
}

private final class AgentRevertRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    let change: @Sendable () throws -> Void
    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void, change: @escaping @Sendable () throws -> Void) {
        self.callback = callback
        self.change = change
    }
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        try change()
        callback(.status(.idle))
    }
    func approve(request: String, allow: Bool) async throws {}
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {}
}

final class AgentDiffClippingTests: XCTestCase {
    /// A large edit's diff used to keep only its last 8 KiB, losing its hunk header and
    /// saying nothing; it now keeps its start, cut at a line, and says it was cut.
    func testLongDiffsKeepTheirStartAndSayTheyWereCut() {
        let lines = ["@@ -1,400 +1,400 @@"] + (0..<400).map { "+line number \($0) with some text" }
        let diff = lines.joined(separator: "\n")
        let clipped = AgentSessions.clippedDiff(diff, bytes: 8 * 1024)
        XCTAssertLessThanOrEqual(clipped.utf8.count, 8 * 1024)
        XCTAssertTrue(clipped.hasPrefix("@@ -1,400 +1,400 @@\n+line number 0 "))
        XCTAssertTrue(clipped.hasSuffix("\n" + AgentToolActivity.diffTruncationMarker))
        let body = clipped.components(separatedBy: "\n").dropLast()
        XCTAssertTrue(body.allSatisfy { $0.hasPrefix("@@") || $0.hasSuffix("with some text") }, "Cut only between lines")
        XCTAssertEqual(AgentSessions.clippedDiff("@@ -1 +1 @@\n+short", bytes: 8 * 1024), "@@ -1 +1 @@\n+short")
    }
}

final class AgentToolDenialTests: XCTestCase {
    func testACommandsOwnPermissionErrorIsAFailureNotADenial() {
        XCTAssertFalse(agentToolDenied("cat: /etc/sudoers: Permission denied"))
        XCTAssertTrue(agentToolDenied("Permission to use Bash with command rm -rf / has been denied."))
        XCTAssertTrue(agentToolDenied("The user declined tool execution."), "Only explicit refusals are denials")
        XCTAssertTrue(agentToolDenied("User rejected the change"))
    }
}

final class AgentCodexReviewTests: XCTestCase {
    /// `/review` findings arrive as the review item's text. Shape from the Codex app-server
    /// protocol; not checked against a recorded session.
    func testReviewFindingsBecomeAMessage() {
        let recorder = AgentRuntimeRecorder()
        let runtime = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(["method": "item/completed", "params": ["threadId": "t", "turnId": "u",
            "item": ["type": "exitedReviewMode", "id": "review-1", "review": "No issues found."]]])
        XCTAssertEqual(recorder.transcript["review-1"]?.text, "No issues found.")
        XCTAssertEqual(recorder.transcript["review-1"]?.kind, .assistant)
    }
}

final class AgentCodexOutputTests: XCTestCase {
    /// Command output used to grow without bound and be re-sent whole on every delta.
    func testStreamedCommandOutputKeepsItsNewestPartBounded() {
        let recorder = AgentRuntimeRecorder()
        let runtime = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        let chunk = String(repeating: "x", count: 4096) + "\n"
        for _ in 0..<40 {
            runtime.receive(["method": "item/commandExecution/outputDelta", "params": ["itemId": "cmd", "delta": chunk]])
        }
        runtime.receive(["method": "item/commandExecution/outputDelta", "params": ["itemId": "cmd", "delta": "done\n"]])
        let output = recorder.transcript["cmd"]?.tool?.output ?? ""
        XCTAssertLessThanOrEqual(output.utf8.count, CodexAgentRuntime.maximumCommandOutput)
        XCTAssertTrue(output.hasSuffix("done\n"), "The newest output is kept")
    }
}

final class AgentTurnDetailsTests: XCTestCase {
    private func json(_ source: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    }

    /// Shapes copied from a recorded Claude Code 2.1.311 result.
    func testTurnUsageComesFromTheResult() throws {
        let result = try json(#"{"type":"result","subtype":"success","stop_reason":"end_turn","total_cost_usd":0.00245,"usage":{"input_tokens":4,"cache_creation_input_tokens":10233,"cache_read_input_tokens":33394,"output_tokens":156},"modelUsage":{"claude-haiku-5-5":{"inputTokens":4}}}"#)
        let usage = try XCTUnwrap(ClaudeAgentRuntime.turnUsage(result, model: nil))
        XCTAssertEqual(usage.inputTokens, 43631)
        XCTAssertEqual(usage.outputTokens, 156)
        XCTAssertEqual(usage.model, "claude-haiku-5-5")
        XCTAssertEqual(usage.stopReason, "end_turn")
        XCTAssertFalse(usage.stoppedAtLimit)
        XCTAssertTrue(AgentTurnUsage(stopReason: "max_tokens").stoppedAtLimit)
    }

    func testFailedMcpServersBackgroundShellsAndGrepResultsAreShown() throws {
        let recorder = AgentRuntimeRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(try json(#"{"type":"system","subtype":"init","mcp_servers":[{"name":"linear","status":"failed"},{"name":"docs","status":"connected"}]}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"init","mcp_servers":[{"name":"linear","status":"failed"}]}"#))
        XCTAssertEqual(recorder.transcript.values.filter { $0.kind == .notice }.map(\.text),
                       ["The MCP server “linear” failed to start; its tools are unavailable."], "Said once")

        let shells = AgentRuntimeRecorder()
        let shellRuntime = ClaudeAgentRuntime(onEvent: { shells.receive($0) })
        shellRuntime.receive(try json(#"{"type":"system","subtype":"task_started","task_id":"b1","tool_use_id":"t1","description":"npm run dev","is_backgrounded":true,"task_type":"local_bash"}"#))
        XCTAssertEqual(shells.subagentLists.last?.map(\.agentType), ["Shell"], "A background shell shows with the agents")

        let grep = agentClaudeFileSearch(name: "Grep", input: #"{"pattern":"needle"}"#,
                                         output: "Sources/A.swift:12:let needle = 1\nSources/B.swift:3:needle()")
        XCTAssertEqual(grep?.pattern, "needle")
        XCTAssertEqual(grep?.results?.map(\.fileName), ["Sources/A.swift", "Sources/B.swift"])
        XCTAssertEqual(grep?.results?.first?.line, 12)
        let glob = agentClaudeFileSearch(name: "Glob", input: #"{"pattern":"**/*.swift"}"#, output: "Found 2 files\n/repo/A.swift\n/repo/B.swift")
        XCTAssertEqual(glob?.results?.map(\.fileName), ["/repo/A.swift", "/repo/B.swift"])
        XCTAssertNil(agentClaudeFileSearch(name: "Grep", input: nil, output: "Something went wrong reading the files"))
    }
}
