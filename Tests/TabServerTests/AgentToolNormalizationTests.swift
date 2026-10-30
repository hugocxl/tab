import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentToolNormalizationTests: XCTestCase {
    // T3 tool_call_restricted_granular/claude_transcript.ndjson:8,12.
    func testClaudeRecordedToolKeepsInputAfterResultAndTimestamp() throws {
        let transcript = ToolNormalizationRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { transcript.receive($0) })
        runtime.receive(try json(#"{"type":"assistant","message":{"id":"msg_01DbHDhWivNDrjU961RBEG9p","content":[{"type":"tool_use","id":"toolu_01Ayxc73fyGSj2frmw8XLmJn","name":"Bash","input":{"command":"printf 'codex app-server approval fixture' > .codex-probe-write-action.txt","description":"Write exact text to .codex-probe-write-action.txt"}}]},"parent_tool_use_id":null}"#))
        let started = try XCTUnwrap(transcript.item?.tool?.startedAt)
        runtime.receive(try json(#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_01Ayxc73fyGSj2frmw8XLmJn","type":"tool_result","content":"(Bash completed with no output)","is_error":false}]},"parent_tool_use_id":null,"timestamp":"2026-05-07T01:41:04.458Z"}"#))
        let tool = try XCTUnwrap(transcript.item?.tool)
        XCTAssertEqual(tool.category, .command)
        XCTAssertTrue(tool.input?.contains("printf") == true)
        XCTAssertEqual(tool.output, "(Bash completed with no output)")
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(tool.startedAt, started)
        XCTAssertEqual(tool.completedAt?.timeIntervalSince1970 ?? 0, 1778118064.458, accuracy: 0.001)
        XCTAssertTrue(tool.summary.hasPrefix("printf"))
    }

    // T3 tool_call_denied_write/claude_transcript.ndjson:76. This is a denial, not a tool crash.
    func testClaudeRecordedDeclinedResultIsDenied() throws {
        let transcript = ToolNormalizationRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { transcript.receive($0) })
        runtime.receive(try json(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"User declined tool execution.","is_error":true,"tool_use_id":"toolu_016StH6rgvnkDxU2MWt46gYE"}]},"parent_tool_use_id":null,"timestamp":"2026-09-14T18:53:09.168Z","tool_result_meta":[{"id":"toolu_016StH6rgvnkDxU2MWt46gYE","non_execution_kind":"permission-rule"}]}"#))
        XCTAssertEqual(transcript.item?.tool?.status, .denied)
        XCTAssertEqual(transcript.item?.tool?.output, "User declined tool execution.")
        XCTAssertTrue(transcript.item?.isComplete == true)
        XCTAssertNil(transcript.item?.tool?.startedAt, "A result without its start must not fabricate a start time")
    }

    // T3 command_output_streaming/codex_transcript.ndjson:47–52, selected fields.
    func testCodexRecordedCommandKeepsInputAndReplacesAggregate() throws {
        let transcript = ToolNormalizationRecorder()
        let runtime = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        let id = "exec-1a2dcd5e-1591-48a8-bb8e-47cb40883d2c"
        let command = #"/bin/zsh -lc "for i in 1 2 3 4; do printf '\\033[32mstream line %s\\033[0m\\n' "'$i; sleep 1; done; printf '"'progress 50%%\\rprogress 100%%\\n'""#
        runtime.receive(["method": "item/started", "params": ["startedAtMs": 1791001635941.0, "item": ["id": id, "type": "commandExecution", "command": command, "aggregatedOutput": NSNull(), "exitCode": NSNull()]]])
        let input = transcript.item?.tool?.input
        let output = "\u{1b}[32mstream line 2\u{1b}[0m\n"
        runtime.receive(["method": "item/commandExecution/outputDelta", "params": ["itemId": id, "delta": output]])
        XCTAssertEqual(transcript.item?.tool?.output, output)
        XCTAssertEqual(transcript.item?.tool?.status, .running)
        // Replay a completion with the recorded aggregate's first line to isolate replacement semantics.
        runtime.receive(["method": "item/completed", "params": ["completedAtMs": 1791001639846.0, "item": ["id": id, "type": "commandExecution", "command": command, "aggregatedOutput": output, "exitCode": 0, "status": "completed"]]])
        let tool = try XCTUnwrap(transcript.item?.tool)
        XCTAssertEqual(tool.input, input)
        XCTAssertEqual(tool.output, output)
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(tool.exitCode, 0)
        XCTAssertEqual(tool.startedAt?.timeIntervalSince1970 ?? 0, 1791001635.941, accuracy: 0.001)
        XCTAssertEqual(tool.completedAt?.timeIntervalSince1970 ?? 0, 1791001639.846, accuracy: 0.001)
    }

    // T3 tool_call_restricted_granular/codex_transcript.ndjson:49.
    func testCodexRecordedFileChangeKeepsActualDiffAndPath() throws {
        let transcript = ToolNormalizationRecorder()
        let runtime = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        runtime.receive(try json(#"{"method":"item/completed","params":{"item":{"type":"fileChange","id":"exec-114e8eef-018a-444d-8542-aa0232ff1f38","changes":[{"path":"/home/replay-user/t3code/packages/effect-codex-app-server/.codex-probe-write-action.txt","kind":{"type":"add"},"diff":"codex app-server approval fixture.\n"}],"status":"completed"},"completedAtMs":1790297014355}}"#))
        let tool = try XCTUnwrap(transcript.item?.tool)
        XCTAssertEqual(tool.category, .edit)
        XCTAssertEqual(tool.fileChanges?.first?.kind, "add")
        XCTAssertEqual(tool.fileChanges?.first?.diff, "codex app-server approval fixture.\n")
        XCTAssertEqual(tool.filePaths?.first, tool.fileChanges?.first?.path)
        XCTAssertEqual(tool.summary, tool.filePaths?.first)
        XCTAssertNil(tool.startedAt)
    }

    // T3 thread_rollback_to_stopped_turn/codex_transcript.ndjson:66.
    func testCodexRecordedFailedCommandIsNotPresentedAsSuccessful() throws {
        let transcript = ToolNormalizationRecorder()
        let runtime = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        runtime.receive(try json(#"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-6964412e-1d91-47b5-8a37-7a669b30c03e","command":"/bin/bash -lc \"node -e \\\"console.log('interrupt fixture tool started'); setTimeout(() => {}, 30000)\\\"\"","status":"failed","aggregatedOutput":null,"exitCode":-1,"durationMs":22},"completedAtMs":1790459903901}}"#))
        XCTAssertEqual(transcript.item?.tool?.status, .failed)
        XCTAssertEqual(transcript.item?.tool?.exitCode, -1)
        XCTAssertTrue(transcript.item?.isComplete == true)
        XCTAssertNil(transcript.item?.tool?.output, "No output was supplied by the provider")
    }

    private func json(_ source: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    }
}

private final class ToolNormalizationRecorder: @unchecked Sendable {
    var item: AgentChatItem?
    func receive(_ event: AgentRuntimeEvent) {
        if case .item(let item) = event { self.item = item }
    }
}
