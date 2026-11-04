import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentHistoryTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var history: AgentHistory!
    private let claudeSession = "3de6746e-518a-4660-9c84-a6a4bd87917c"
    private let codexSession = "01a190d2-3c4e-7890-94e2-b9340531c38d"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-history-" + UUID().uuidString)
        project = root.appendingPathComponent("work/my app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        history = AgentHistory(claude: root.appendingPathComponent("claude"), codex: root.appendingPathComponent("codex"))
        let cwd = project.path

        let claude = root.appendingPathComponent("claude/projects")
            .appendingPathComponent(AgentHistory.claudeFolderName(cwd))
        try write(claude.appendingPathComponent(claudeSession + ".jsonl"), [
            ["type": "queue-operation", "operation": "enqueue"],
            ["type": "user", "uuid": "u1", "cwd": cwd, "isMeta": true,
             "message": ["role": "user", "content": "<local-command-caveat>Ignore</local-command-caveat>"]],
            ["type": "user", "uuid": "u2", "cwd": cwd, "timestamp": "2026-11-04T10:00:00.000Z",
             "message": ["role": "user", "content": "Fix the login bug\nIt fails on Safari"]],
            ["type": "attachment", "cwd": cwd, "attachment": ["type": "anything"]],
            ["type": "assistant", "uuid": "a1", "cwd": cwd,
             "message": ["id": "m1", "model": "claude-opus-5-5", "content": [["type": "thinking", "thinking": "Hmm"]]]],
            ["type": "assistant", "uuid": "a2", "cwd": cwd,
             "message": ["id": "m1", "model": "claude-opus-5-5", "content": [["type": "text", "text": "Looking."]]]],
            ["type": "assistant", "uuid": "a3", "cwd": cwd,
             "message": ["id": "m1", "model": "claude-opus-5-5",
                         "content": [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "swift test"]]]]],
            ["type": "user", "uuid": "u3", "cwd": cwd,
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "1 failure",
                                                      "is_error": true]]]],
            ["type": "assistant", "uuid": "a4", "cwd": cwd, "isSidechain": true,
             "message": ["id": "m2", "content": [["type": "text", "text": "A subagent's work"]]]],
            ["type": "assistant", "uuid": "a5", "cwd": cwd,
             "message": ["id": "m3", "model": "claude-opus-5-5", "content": [["type": "text", "text": "Fixed it."]]]],
            ["type": "user", "uuid": "u4", "cwd": cwd,
             "message": ["role": "user", "content": "<command-name>/review</command-name>\n<command-args>login</command-args>"]],
            ["type": "ai-title", "aiTitle": "Login bug on Safari"],
            ["type": "custom-title", "customTitle": "Safari login"],
        ], trailing: "{\"type\":\"user\", cut off")
        // The same folder name can stand for another path, such as `work/my-app`.
        try write(claude.appendingPathComponent("6b1c2a33-0000-4000-8000-000000000000.jsonl"), [
            ["type": "user", "uuid": "x", "cwd": root.appendingPathComponent("work/my-app").path,
             "message": ["role": "user", "content": "Someone else's folder"]],
        ])

        let day = root.appendingPathComponent("codex/sessions/2026/11/04")
        try write(day.appendingPathComponent("rollout-2026-11-04T10-00-00-\(codexSession).jsonl"), [
            ["type": "session_meta", "payload": ["id": codexSession, "cwd": cwd, "source": "vscode",
                                                 "base_instructions": ["text": String(repeating: "x", count: 4000)]]],
            ["type": "turn_context", "payload": ["model": "gpt-6.1"]],
            codexMessage("developer", "input_text", "You are Codex"),
            codexMessage("user", "input_text", "<environment_context>\n  <cwd>\(cwd)</cwd>\n</environment_context>"),
            codexMessage("user", "input_text", "Tighten the header spacing"),
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Tighten the header spacing"]],
            codexMessage("assistant", "output_text", "I'll look at the header."),
            ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "call_id": "call_1",
                                                  "arguments": "{\"cmd\":\"rg header\"}"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "call_1", "output": "Header.swift"]],
            codexMessage("assistant", "output_text", "Done."),
        ])
        try write(day.appendingPathComponent("rollout-2026-11-04T11-00-00-01a190d2-0000-7000-8000-000000000001.jsonl"), [
            ["type": "session_meta", "payload": ["id": "01a190d2-0000-7000-8000-000000000001", "cwd": "/elsewhere"]],
            codexMessage("user", "input_text", "Another project"),
        ])
        try write(day.appendingPathComponent("rollout-2026-11-04T12-00-00-01a190d2-0000-7000-8000-000000000002.jsonl"), [
            ["type": "session_meta", "payload": ["id": "01a190d2-0000-7000-8000-000000000002", "cwd": cwd,
                                                 "source": ["subagent": ["parent": codexSession]]]],
            codexMessage("user", "input_text", "A subagent's task"),
        ])
        try write(root.appendingPathComponent("codex/session_index.jsonl"), [
            ["id": codexSession, "thread_name": "Header spacing"],
            ["id": codexSession, "thread_name": "Server header spacing"],
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListsOnlyThisFoldersConversationsWithTheirTitles() {
        let reply = history.list(directory: project.path, excluding: [])
        XCTAssertEqual(Set(reply.entries.map(\.providerSession)), [claudeSession, codexSession])
        XCTAssertEqual(reply.entries.first { $0.provider == .claude }?.title, "Safari login")
        XCTAssertEqual(reply.entries.first { $0.provider == .codex }?.title, "Server header spacing")
        XCTAssertNoThrow(try reply.validate())

        let open = history.list(directory: project.path, excluding: [codexSession])
        XCTAssertEqual(open.entries.map(\.providerSession), [claudeSession], "Conversations Tab already continues are left out")
    }

    func testClaudeTranscriptKeepsWhatWasSaidAndDone() throws {
        let transcript = try history.transcript(provider: .claude, session: claudeSession, directory: project.path)
        XCTAssertEqual(transcript.items.map(\.kind), [.user, .assistant, .tool, .assistant, .user])
        XCTAssertEqual(transcript.items.map(\.text), ["Fix the login bug\nIt fails on Safari", "Looking.", "Bash", "Fixed it.",
                                                     "/review login"])
        XCTAssertEqual(transcript.items[2].tool?.output, "1 failure")
        XCTAssertEqual(transcript.items[2].tool?.status, .failed)
        XCTAssertEqual(transcript.items[2].tool?.category, .command)
        XCTAssertNotNil(transcript.items[0].createdAt)
        XCTAssertEqual(transcript.resolvedModel, "claude-opus-5-5")
        XCTAssertEqual(Set(transcript.items.map(\.id)).count, transcript.items.count)
    }

    func testCodexTranscriptKeepsWhatWasSaidAndDone() throws {
        let transcript = try history.transcript(provider: .codex, session: codexSession, directory: project.path)
        XCTAssertEqual(transcript.items.map(\.kind), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(transcript.items.first?.text, "Tighten the header spacing")
        XCTAssertEqual(transcript.items[2].tool?.output, "Header.swift")
        XCTAssertEqual(transcript.items[2].tool?.presentsCommand, true)
        XCTAssertEqual(transcript.resolvedModel, "gpt-6.1")
    }

    func testRefusesConversationsFromAnotherFolder() {
        XCTAssertThrowsError(try history.transcript(provider: .codex, session: "01a190d2-0000-7000-8000-000000000001",
                                                    directory: project.path))
        XCTAssertThrowsError(try history.transcript(provider: .claude, session: claudeSession,
                                                    directory: root.appendingPathComponent("work").path))
        XCTAssertThrowsError(try history.transcript(provider: .claude, session: "../" + claudeSession, directory: project.path))
    }

    func testLeavesOutContextTheCLIsAddToPrompts() {
        XCTAssertNil(AgentHistory.prompt("<system-reminder>\nBe brief.\n</system-reminder>"))
        XCTAssertNil(AgentHistory.prompt("# AGENTS.md instructions for /repo\n\n<INSTRUCTIONS>…</INSTRUCTIONS>"))
        XCTAssertEqual(AgentHistory.prompt("<div> is misaligned"), "<div> is misaligned")
        XCTAssertEqual(AgentHistory.prompt("  Rename it  "), "Rename it")
    }

    private func codexMessage(_ role: String, _ type: String, _ text: String) -> [String: Any] {
        ["type": "response_item", "payload": ["type": "message", "role": role, "content": [["type": type, "text": text]]]]
    }

    private func write(_ file: URL, _ records: [[String: Any]], trailing: String = "") throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n" + trailing).write(to: file, atomically: true, encoding: .utf8)
    }
}
