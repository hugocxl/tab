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

/// Reverts are reserved on the server against work Tab runs that may change the same files,
/// and against other restores in the same folder. Starting cases from AgentKit 1.3.0's
/// restore tests, mapped onto Tab's durable prompt queue.
final class AgentRestoreCoordinationTests: XCTestCase {
    private struct Fixture: @unchecked Sendable {
        let storage: URL
        let repo: GitTestRepo
        let sessions: AgentSessions
        let id: SessionId
        let checkpoint: String
        let counter: ScriptCounter
        let runtimes: ScriptFlag<[ScriptedAgentRuntime]>
    }

    /// A conversation whose first turn changed `file.txt` from "before" to "turn 1", with its
    /// checkpoint recorded. Later turns write "turn N" and end, unless `working` holds them.
    private func fixture(store: AgentCheckpointStore = AgentCheckpointStore(), provider: AgentChatProvider = .claude,
                         working: ScriptFlag<Bool> = ScriptFlag(false)) async throws -> Fixture {
        let storage = try agentStorage()
        let repo = try GitTestRepo(commit: false)
        try repo.write("file.txt", "before\n")
        try repo.write("unrelated.txt", "mine\n")
        try repo.commit("initial")
        let directory = repo.path, counter = ScriptCounter(), runtimes = ScriptFlag<[ScriptedAgentRuntime]>([])
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, checkpointStore: store, factory: { _, _, _, callback in
            let runtime = ScriptedAgentRuntime(callback, counter: counter) { number, runtime in
                try "turn \(number)\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                runtime.callback(.providerSession("provider"))
                runtime.callback(.providerMessage("message-\(number)"))
                return working.value && number > 1 ? nil : .idle
            }
            runtimes.value.append(runtime)
            return runtime
        })
        addTeardownBlock { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: provider))
        _ = try await sessions.handle(.send(session: id, text: "Change it", model: nil))
        let done = try await settle(sessions, id) { $0.status == .idle && $0.turns?.first?.checkpoint != nil }
        return Fixture(storage: storage, repo: repo, sessions: sessions, id: id, checkpoint: try XCTUnwrap(done.turns?.first?.checkpoint?.id),
                       counter: counter, runtimes: runtimes)
    }

    private func revert(_ fixture: Fixture, force: Bool = true) async throws -> AgentRevertReply {
        guard case .revert(let reply) = try await fixture.sessions.conversation(.revert(session: fixture.id, checkpoint: fixture.checkpoint,
                                                                                       paths: nil, force: force)) else {
            throw AgentRuntimeError("Unexpected reply")
        }
        return reply
    }

    private func assertRefused(_ fixture: Fixture, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let before = contents(fixture.repo.path, "file.txt")
        do {
            _ = try await revert(fixture)
            XCTFail("Refused: \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(agentMessage(error), message, file: file, line: line)
        }
        XCTAssertEqual(contents(fixture.repo.path, "file.txt"), before, "A refused restore changes no files", file: file, line: line)
    }

    func testARevertHoldsBackNewSubmissionsUntilItFinishes() async throws {
        let gate = ScriptGate()
        var store = AgentCheckpointStore()
        store.willRestore = { _ in gate.wait() }
        let fixture = try await fixture(store: store)
        defer { gate.release() }
        let revert = Task { try await self.revert(fixture) }
        try await waitUntilTrue { gate.reached }

        // A direct send is refused and says so; a submitted prompt waits in the queue.
        do {
            _ = try await fixture.sessions.handle(.send(session: fixture.id, text: "Now", model: nil))
            XCTFail("A send can't start while files are restored")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Files are being restored"))
        }
        let prompt = AgentPrompt(text: "Change it again", model: nil, effort: nil, provider: .claude, planMode: false)
        let queued = try await fixture.sessions.handle(.submit(session: fixture.id, prompt: prompt))
        XCTAssertEqual(queued.queuedPrompts?.map(\.id), [prompt.id], "Accepted and kept, not delivered")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.counter.count, 1, "No turn starts while the restore runs")
        do {
            _ = try await fixture.sessions.handle(.clear(session: fixture.id, archive: SessionId(), expectedRevision: queued.revision))
            XCTFail("A clear waits for the restore")
        } catch {}

        gate.release()
        let reply = try await revert.value
        XCTAssertEqual(reply.reverted, ["file.txt"])
        // Then the queued prompt is delivered, and its turn's baseline is the restored file.
        let done = try await settle(fixture.sessions, fixture.id) { $0.turns?.count == 2 && $0.turns?.last?.checkpoint != nil }
        XCTAssertEqual(fixture.counter.count, 2)
        XCTAssertEqual(contents(fixture.repo.path, "file.txt"), "turn 2\n", "The later turn's work stays")
        let second = try XCTUnwrap(done.turns?.last?.checkpoint?.id)
        let diff = try await fixture.sessions.checkpoint(.init(session: fixture.id, checkpoint: second, path: "file.txt"))
        XCTAssertTrue(diff.diff?.rows.contains { $0.text == "-before" } == true, "The next turn starts from the restored files")
    }

    func testARevertIsRefusedWhileWorkInTheFolderMayChangeItsFiles() async throws {
        let working = ScriptFlag(true)
        let fixture = try await fixture(working: working)
        // An agent the idle parent started still runs in the background.
        let runtime = try XCTUnwrap(fixture.runtimes.value.first)
        runtime.callback(.subagents([AgentSubagent(id: "a1", toolUseID: "task", description: "Edit in the background", background: true)]))
        _ = try await settle(fixture.sessions, fixture.id) { $0.subagents?.first?.status == .running }
        await assertRefused(fixture, "This conversation's agents are still running and may change these files. Wait for them or stop them first.")
        runtime.callback(.subagents([AgentSubagent(id: "a1", toolUseID: "task", description: "Edit in the background",
                                                   background: true, status: .completed)]))
        _ = try await settle(fixture.sessions, fixture.id) { $0.subagents?.first?.status == .completed }

        // A second conversation works in the same folder.
        let other = SessionId()
        _ = try await fixture.sessions.handle(.create(session: other, project: ProjectId(), provider: .claude))
        _ = try await fixture.sessions.handle(.send(session: other, text: "Work", model: nil))
        _ = try await settle(fixture.sessions, other) { $0.status == .working }
        await assertRefused(fixture, "An agent in another conversation is working in this folder. Wait for it to finish or stop it first.")
        _ = try await fixture.sessions.handle(.interrupt(session: other))
        _ = try await settle(fixture.sessions, other) { $0.status == .idle && $0.turns?.last?.checkpointStatus?.state == .ready }

        // The conversation's own turn works.
        _ = try await fixture.sessions.handle(.send(session: fixture.id, text: "Keep working", model: nil))
        _ = try await settle(fixture.sessions, fixture.id) { $0.status == .working }
        await assertRefused(fixture, "Stop the agent first: it may be changing these files.")
    }

    func testAConversationInAnotherFolderDoesNotHoldARevert() async throws {
        let working = ScriptFlag(true)
        let storage = try agentStorage()
        let repo = try GitTestRepo(commit: false), elsewhere = try GitTestRepo(commit: true)
        try repo.write("file.txt", "before\n")
        try repo.commit("initial")
        let directory = repo.path, otherDirectory = elsewhere.path, counter = ScriptCounter()
        let projects = ScriptFlag<[ProjectId: String]>([:])
        let sessions = try AgentSessions(root: storage, projectDirectory: { projects.value[$0] ?? directory }, factory: { _, folder, _, callback in
            ScriptedAgentRuntime(callback, counter: counter) { number, _ in
                guard folder == directory else { return working.value ? nil : .idle }
                try "turn \(number)\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                return .idle
            }
        })
        defer { sessions.shutdown() }
        let id = SessionId(), other = SessionId(), otherProject = ProjectId()
        projects.value[otherProject] = otherDirectory
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude))
        _ = try await sessions.handle(.send(session: id, text: "Change it", model: nil))
        let done = try await settle(sessions, id) { $0.turns?.first?.checkpoint != nil }
        _ = try await sessions.handle(.create(session: other, project: otherProject, provider: .claude))
        _ = try await sessions.handle(.send(session: other, text: "Work elsewhere", model: nil))
        _ = try await settle(sessions, other) { $0.status == .working }
        guard case .revert(let reply) = try await sessions.conversation(.revert(session: id, checkpoint: try XCTUnwrap(done.turns?.first?.checkpoint?.id),
                                                                              paths: nil, force: false)) else { return XCTFail("Unexpected reply") }
        XCTAssertEqual(reply.reverted, ["file.txt"])
    }

    func testCompetingRestoresFromTwoClientsApplyOnce() async throws {
        let gate = ScriptGate()
        var store = AgentCheckpointStore()
        store.willRestore = { _ in gate.wait() }
        let fixture = try await fixture(store: store)
        defer { gate.release() }
        let first = Task { try await self.revert(fixture) }
        try await waitUntilTrue { gate.reached }
        // The second client confirmed the same revert meanwhile.
        await assertRefused(fixture, "Another revert is being applied in this folder. Try again when it finishes.")
        gate.release()
        let applied = try await first.value
        XCTAssertEqual(applied.reverted, ["file.txt"])
        // Or it confirmed after: its files are already as it asked, so nothing changes.
        let second = try await revert(fixture, force: false)
        XCTAssertEqual(second.reverted, [])
        XCTAssertEqual(second.conflicts, [])
        XCTAssertEqual(second.unchanged, ["file.txt"])
        XCTAssertEqual(contents(fixture.repo.path, "file.txt"), "before\n")
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = try await fixture.sessions.handle(.read(session: fixture.id))
        XCTAssertEqual(snapshot.items.filter { $0.kind == .notice && $0.text.hasPrefix("Reverted") }.count, 1, "Recorded once")
    }

    func testShutdownFinishesARestoreUnderWayAndRefusesLaterOnes() async throws {
        let gate = ScriptGate()
        var store = AgentCheckpointStore()
        store.willRestore = { _ in gate.wait() }
        let fixture = try await fixture(store: store)
        let revert = Task { try await self.revert(fixture) }
        try await waitUntilTrue { gate.reached }
        let stopped = DispatchSemaphore(value: 0)
        Thread.detachNewThread { fixture.sessions.shutdown(); stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.3), .timedOut, "Shutdown waits for the restore under way")
        gate.release()
        XCTAssertEqual(stopped.wait(timeout: .now() + 10), .success)
        let applied = try await revert.value
        XCTAssertEqual(applied.reverted, ["file.txt"])
        let saved = try String(contentsOf: fixture.storage.appendingPathComponent(fixture.id.description + ".json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("Reverted 1 file to before a turn."), "Recorded before shutdown returned")
        try "edited later\n".write(toFile: fixture.repo.path + "/file.txt", atomically: true, encoding: .utf8)
        await assertRefused(fixture, "The server is stopping")
    }

    func testARefusedRestoreChangesNothingAndASuccessfulOneOnlyItsFiles() async throws {
        let fixture = try await fixture()
        try fixture.repo.write("staged.txt", "in the index\n")
        try fixture.repo.run("add", "staged.txt")
        let index = try gitIndex(fixture.repo)
        try "my edit\n".write(toFile: fixture.repo.path + "/file.txt", atomically: true, encoding: .utf8)
        try "changed later\n".write(toFile: fixture.repo.path + "/unrelated.txt", atomically: true, encoding: .utf8)
        let refused = try await revert(fixture, force: false)
        XCTAssertEqual(refused.conflicts, ["file.txt"])
        XCTAssertEqual(contents(fixture.repo.path, "file.txt"), "my edit\n", "A refused restore changes no files")
        let forced = try await revert(fixture, force: true)
        XCTAssertEqual(forced.reverted, ["file.txt"])
        XCTAssertEqual(contents(fixture.repo.path, "file.txt"), "before\n")
        XCTAssertEqual(contents(fixture.repo.path, "unrelated.txt"), "changed later\n", "Unrelated files stay")
        XCTAssertEqual(try gitIndex(fixture.repo), index, "The real Git index is untouched")
        XCTAssertEqual(try fixture.repo.run("show", ":staged.txt"), "in the index\n")
    }

    func testAFailureMidRestorePutsBackWhatChangedAndSaysSo() throws {
        let repo = try GitTestRepo(commit: false)
        for name in ["a.txt", "b.txt", "c.txt"] { try repo.write(name, "original \(name)\n") }
        try repo.commit("initial")
        let index = try gitIndex(repo)
        var store = AgentCheckpointStore()
        let before = try store.capture(directory: repo.path)
        try repo.write("a.txt", "agent a\n")
        try FileManager.default.removeItem(atPath: repo.path + "/b.txt")
        try repo.write("c.txt", "agent c\n")
        try repo.write("new.txt", "added\n")
        let after = try store.capture(directory: repo.path)
        addTeardownBlock { try? AgentCheckpointStore().remove(before); try? AgentCheckpointStore().remove(after) }
        let paths = try store.files(from: before, to: after).map(\.path)
        XCTAssertEqual(Set(paths), ["a.txt", "b.txt", "c.txt", "new.txt"])
        store.willRestore = { path in if path == "new.txt" { throw AgentRuntimeError("disk full") } }
        XCTAssertThrowsError(try store.restore(before, paths: ["a.txt", "b.txt", "c.txt", "new.txt"])) { error in
            let failure = error as? AgentRestoreFailure
            XCTAssertEqual(failure?.path, "new.txt")
            XCTAssertEqual(failure?.rolledBack, ["a.txt", "b.txt", "c.txt"])
            XCTAssertEqual(failure?.changed, [])
            XCTAssertEqual(error.localizedDescription, "Couldn't restore new.txt: disk full No files were changed.")
        }
        XCTAssertEqual(contents(repo.path, "a.txt"), "agent a\n", "Every file is as it was before the restore")
        XCTAssertNil(contents(repo.path, "b.txt"))
        XCTAssertEqual(contents(repo.path, "c.txt"), "agent c\n")
        XCTAssertEqual(contents(repo.path, "new.txt"), "added\n")
        XCTAssertEqual(try gitIndex(repo), index)
        store.willRestore = nil
        try store.restore(before, paths: paths)
        XCTAssertEqual(contents(repo.path, "b.txt"), "original b.txt\n")
        XCTAssertNil(contents(repo.path, "new.txt"))
    }

    func testAConversationRevertThatFailsMidwayChangesNothingAndRecordsNothing() async throws {
        let fail = ScriptFlag(true)
        var store = AgentCheckpointStore()
        store.willRestore = { _ in if fail.value { throw AgentRuntimeError("permission denied") } }
        let fixture = try await fixture(store: store)
        await assertRefused(fixture, "Couldn't restore file.txt: permission denied No files were changed.")
        let snapshot = try await fixture.sessions.handle(.read(session: fixture.id))
        XCTAssertFalse(snapshot.items.contains { $0.text.hasPrefix("Reverted") })
        fail.value = false
        let applied = try await revert(fixture)
        XCTAssertEqual(applied.reverted, ["file.txt"], "The reservation was released")
    }
}

/// Edit from Here rewinds a conversation in place, keeping the whole of it as an archive,
/// and restores the removed turns' files only when asked and only from valid checkpoints.
final class AgentRewindTests: XCTestCase {
    /// Each repository is removed when released, so the test keeps them.
    private var repositories: [GitTestRepo] = []

    private func conversation(store: AgentCheckpointStore = AgentCheckpointStore(), provider: AgentChatProvider = .claude,
                              git: Bool = true, turns: Int = 3) async throws
        -> (sessions: AgentSessions, id: SessionId, directory: String, repo: GitTestRepo?, runtimes: ScriptFlag<[ScriptedAgentRuntime]>) {
        let storage = try agentStorage()
        var repo: GitTestRepo?
        let directory: String
        if git {
            let made = try GitTestRepo(commit: false)
            try made.write("file.txt", "before\n")
            try made.commit("initial")
            repo = made
            directory = made.path
            repositories.append(made)
        } else {
            directory = try agentStorage().path
            try "before\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
        }
        let counter = ScriptCounter(), runtimes = ScriptFlag<[ScriptedAgentRuntime]>([])
        let sessions = try AgentSessions(root: storage, projectDirectory: { _ in directory }, checkpointStore: store, factory: { _, _, resume, callback in
            let runtime = ScriptedAgentRuntime(callback, counter: counter) { number, runtime in
                try "turn \(number)\n".write(toFile: directory + "/file.txt", atomically: true, encoding: .utf8)
                try "turn \(number)\n".write(toFile: directory + "/turn-\(number).txt", atomically: true, encoding: .utf8)
                runtime.callback(.providerSession(resume ?? "provider"))
                runtime.callback(.providerMessage("message-\(number)"))
                runtime.callback(.item(AgentChatItem(id: "answer-\(number)", kind: .assistant, text: "Answer \(number)")))
                return .idle
            }
            runtimes.value.append(runtime)
            return runtime
        })
        addTeardownBlock { sessions.shutdown() }
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: provider))
        for number in 1...turns {
            _ = try await sessions.handle(.send(session: id, text: "Message \(number)", model: nil))
            _ = try await settle(sessions, id) { $0.status == .idle && $0.turns?.count == number
                && $0.turns?.last?.checkpointStatus?.state != .capturing }
        }
        return (sessions, id, directory, repo, runtimes)
    }

    private func rewind(_ sessions: AgentSessions, _ id: SessionId, to text: String, restoreFiles: Bool,
                        force: Bool = false, archive: SessionId = SessionId(), revision: UInt64? = nil) async throws -> AgentRewindReply {
        let snapshot = try await sessions.handle(.read(session: id))
        let item = try XCTUnwrap(snapshot.items.first { $0.text == text })
        guard case .rewound(let reply) = try await sessions.conversation(.rewind(session: id, at: item.id, archive: archive,
                revision: revision ?? snapshot.revision, restoreFiles: restoreFiles, force: force)) else {
            throw AgentRuntimeError("Unexpected reply")
        }
        return reply
    }

    func testRewindKeepingFilesArchivesTheWholeConversationAndContinuesBeforeTheMessage() async throws {
        let (sessions, id, directory, _, runtimes) = try await conversation()
        let original = try await sessions.handle(.read(session: id))
        XCTAssertEqual(original.turns?.map { $0.rewindable }, [true, true, true])
        let archive = SessionId()
        let reply = try await rewind(sessions, id, to: "Message 2", restoreFiles: false, archive: archive)
        let rewound = try XCTUnwrap(reply.snapshot)
        XCTAssertEqual(rewound.items.filter { $0.kind != .notice }.map(\.text), ["Message 1", "Answer 1"])
        XCTAssertEqual(rewound.turns?.count, 1)
        XCTAssertNotNil(rewound.turns?.first?.checkpoint, "Earlier turns keep their checkpoints")
        XCTAssertEqual(contents(directory, "file.txt"), "turn 3\n", "Files are kept")
        let kept = try await sessions.handle(.read(session: archive))
        XCTAssertEqual(kept.items.map(\.text), original.items.map(\.text), "The whole conversation stays recoverable")
        XCTAssertEqual(kept.status, .closed)
        XCTAssertEqual(kept.turns?.compactMap { $0.checkpoint }.count, 2, "The archive owns the removed turns' checkpoints")
        let removed = try XCTUnwrap(kept.turns?.last?.checkpoint?.id)
        let diff = try await sessions.checkpoint(.init(session: archive, checkpoint: removed, path: "file.txt"))
        XCTAssertTrue(diff.diff?.rows.contains { $0.text == "+turn 3" } == true)

        _ = try await sessions.handle(.send(session: id, text: "Message 2, differently", model: nil))
        _ = try await settle(sessions, id) { $0.status == .idle && $0.turns?.count == 2 }
        let launch = try XCTUnwrap(runtimes.value.last?.launches.first)
        XCTAssertEqual(launch.forkSource, "provider")
        XCTAssertEqual(launch.forkPoint, "message-1", "The provider continues after the first turn")
        // A stale rewind, as from a second client that saw the old conversation, is refused.
        do {
            _ = try await rewind(sessions, id, to: "Message 1", restoreFiles: false, revision: original.revision)
            XCTFail("Refused against a stale revision")
        } catch {
            XCTAssertEqual(agentMessage(error), "The conversation changed. Review it before editing from here.")
        }
    }

    func testRewindRestoringFilesPutsBackEveryRemovedTurnsFilesOrRefusesOnLaterEdits() async throws {
        let (sessions, id, directory, repo, _) = try await conversation()
        let index = try gitIndex(try XCTUnwrap(repo))
        try "my edit\n".write(toFile: directory + "/turn-3.txt", atomically: true, encoding: .utf8)
        let before = try await sessions.handle(.read(session: id))
        let refused = try await rewind(sessions, id, to: "Message 2", restoreFiles: true)
        XCTAssertNil(refused.snapshot)
        XCTAssertEqual(refused.files.conflicts, ["turn-3.txt"])
        let unchanged = try await sessions.handle(.read(session: id))
        XCTAssertEqual(unchanged.items, before.items, "A refusal rewinds nothing")
        XCTAssertEqual(contents(directory, "file.txt"), "turn 3\n", "and changes no files")

        let reply = try await rewind(sessions, id, to: "Message 2", restoreFiles: true, force: true)
        XCTAssertEqual(Set(reply.files.reverted), ["file.txt", "turn-2.txt", "turn-3.txt"])
        XCTAssertNotNil(reply.snapshot)
        XCTAssertEqual(contents(directory, "file.txt"), "turn 1\n", "As it was before the message's turn")
        XCTAssertEqual(contents(directory, "turn-1.txt"), "turn 1\n")
        XCTAssertNil(contents(directory, "turn-2.txt"))
        XCTAssertNil(contents(directory, "turn-3.txt"))
        XCTAssertEqual(try gitIndex(try XCTUnwrap(repo)), index)
    }

    func testRewindIsCapabilityGatedAndNeedsCheckpointsToRestoreFiles() async throws {
        let codex = try await conversation(provider: .codex, turns: 2)
        let codexSnapshot = try await codex.sessions.handle(.read(session: codex.id))
        XCTAssertEqual(codexSnapshot.turns?.map { $0.rewindable }, [false, false])
        do {
            _ = try await rewind(codex.sessions, codex.id, to: "Message 2", restoreFiles: false)
            XCTFail("Codex can't continue from an earlier message")
        } catch {
            XCTAssertTrue(agentMessage(error).hasPrefix("Codex can't continue from an earlier message"))
        }

        let plain = try await conversation(git: false, turns: 2)
        let snapshot = try await plain.sessions.handle(.read(session: plain.id))
        XCTAssertEqual(snapshot.turns?.map { $0.checkpointStatus?.state }, [.untracked, .untracked])
        do {
            _ = try await rewind(plain.sessions, plain.id, to: "Message 2", restoreFiles: true)
            XCTFail("No checkpoint to restore from")
        } catch {
            XCTAssertEqual(agentMessage(error), "Turn 2 has no recorded file changes, so files can't be restored. Rewind and keep the files instead.")
        }
        XCTAssertEqual(contents(plain.directory, "file.txt"), "turn 2\n")
        let kept = try await rewind(plain.sessions, plain.id, to: "Message 2", restoreFiles: false)
        XCTAssertEqual(kept.snapshot?.items.filter { $0.kind != .notice }.map(\.text), ["Message 1", "Answer 1"])
    }

    func testAFailureDuringARewindsRestoreLeavesTranscriptAndFilesAsTheyWere() async throws {
        let fail = ScriptFlag(false)
        var store = AgentCheckpointStore()
        store.willRestore = { path in if fail.value, path == "turn-3.txt" { throw AgentRuntimeError("read-only volume") } }
        let (sessions, id, directory, _, _) = try await conversation(store: store)
        fail.value = true
        let before = try await sessions.handle(.read(session: id))
        do {
            _ = try await rewind(sessions, id, to: "Message 2", restoreFiles: true)
            XCTFail("The restore failed")
        } catch {
            XCTAssertEqual(agentMessage(error), "Couldn't restore turn-3.txt: read-only volume No files were changed.")
        }
        let after = try await sessions.handle(.read(session: id))
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.revision, before.revision, "Nothing was rewound")
        XCTAssertEqual(contents(directory, "file.txt"), "turn 3\n")
        XCTAssertEqual(contents(directory, "turn-2.txt"), "turn 2\n")
        fail.value = false
        let reply = try await rewind(sessions, id, to: "Message 2", restoreFiles: true)
        XCTAssertNotNil(reply.snapshot, "The reservation was released")
    }
}
