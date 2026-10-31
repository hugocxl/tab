import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// Offline excerpts from the provider source 6fc9144a60c4a5f45089316ddd5f7371bafd3bf2 (MIT).
/// Source root: apps/server/src/orchestration-v2/testkit/fixtures/.
/// Only normalization-relevant fields are retained; IDs, text, block boundaries,
/// delta boundaries and event order are from the recordings, not invented wire data.
/// Claude `emit_inbound.frame` is the SDK message, not the query.open wrapper.
/// SDK permission callbacks are deliberately excluded: they are not CLI control frames.
final class AgentProviderReplayTests: XCTestCase {
    func testTypedSearchDataFlowsThroughProviderEvents() throws {
        let transcript = ProviderReplayTranscript()
        let claude = ClaudeAgentRuntime(onEvent: { transcript.receive($0) })
        claude.beginTurn()
        claude.receive(["type": "assistant", "message": ["id": "assistant", "content": [
            ["type": "tool_use", "id": "search", "name": "WebSearch", "input": ["query": "Swift docs"]],
        ]]])
        claude.receive(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "search", "content": "Search completed"],
        ]], "tool_use_result": ["query": "Swift docs", "durationSeconds": 0.5, "results": [
            ["content": [["title": "Guide", "url": "https://example.com/docs"]]],
        ]]])
        let result = try XCTUnwrap(transcript.items["search"]?.tool)
        XCTAssertEqual(result.presentation, .webSearch)
        XCTAssertEqual(result.searchPatterns, ["Swift docs"])
        XCTAssertEqual(result.webResults, [.init(title: "Guide", url: "https://example.com/docs")])

        let codex = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        codex.receive(["method": "item/completed", "params": ["item": [
            "id": "codex-search", "type": "webSearch", "query": "Swift docs",
            "action": ["type": "search", "queries": ["AppKit", "TextKit"]],
        ]]])
        XCTAssertEqual(transcript.items["codex-search"]?.tool?.searchPatterns, ["AppKit", "TextKit", "Swift docs"])
        XCTAssertEqual(transcript.items["codex-search"]?.tool?.presentation, .webSearch)
    }

    func testCodexDynamicResultsKeepNamespacesBlocksAndMcpErrorContext() throws {
        let transcript = ProviderReplayTranscript()
        let codex = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        func receive(_ item: [String: Any]) { codex.receive(["method": "item/completed", "params": ["item": item]]) }
        receive(["id": "repl", "type": "dynamicToolCall", "namespace": " node_repl ", "tool": "js",
                 "arguments": ["code": "1 + 1"], "success": true, "contentItems": [
                    ["type": "text", "text": "2"], ["type": "resource_link", "uri": "file:///tmp/result"],
                 ]])
        let repl = try XCTUnwrap(transcript.items["repl"]?.tool)
        XCTAssertEqual(repl.name, "node_repl.js")
        XCTAssertEqual(repl.presentation, .dynamicTool)
        XCTAssertEqual(repl.outputIsJSON, true)
        let blocks = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(repl.output).utf8)) as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last?["uri"] as? String, "file:///tmp/result")
        receive(["id": "mcp", "type": "mcpToolCall", "server": "docs", "tool": "read", "arguments": [:],
                 "result": ["content": [["type": "text", "text": "plain fallback"]], "structuredContent": ["answer": 42]],
                 "error": ["message": "Partial failure"], "status": "failed"])
        let mcp = try XCTUnwrap(transcript.items["mcp"]?.tool)
        XCTAssertEqual(mcp.name, "docs.read")
        XCTAssertEqual(mcp.status, .failed)
        let output = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(mcp.output).utf8)) as? [String: Any])
        XCTAssertEqual(output["error"] as? String, "Partial failure")
        XCTAssertEqual((output["result"] as? [String: Any])?["answer"] as? Int, 42)
        receive(["id": "failed", "type": "dynamicToolCall", "tool": "custom", "success": false, "contentItems": NSNull()])
        XCTAssertEqual(transcript.items["failed"]?.tool?.output, #"{"success":false}"#)
        XCTAssertEqual(transcript.items["failed"]?.tool?.status, .failed)
        let restored = try JSONDecoder().decode(AgentToolActivity.self, from: JSONEncoder().encode(repl))
        XCTAssertEqual(restored, repl)
    }

    func testTypedFileChangesRetainMovesAndRecordedPatch() throws {
        let transcript = ProviderReplayTranscript()
        let codex = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        codex.receive(["method": "item/completed", "params": ["item": [
            "id": "moved-file", "type": "fileChange", "status": "completed", "changes": [
                ["path": "old.swift", "kind": ["type": "update", "move_path": "new.swift"], "diff": "-before\n+after"],
            ],
        ]]])
        let tool = try XCTUnwrap(transcript.items["moved-file"]?.tool)
        XCTAssertEqual(tool.presentation, .fileChange)
        XCTAssertEqual(tool.fileChangeDetails?.fileName, "old.swift")
        XCTAssertEqual(tool.fileChangeDetails?.diff, "-before\n+after")
        XCTAssertEqual(tool.fileChangeDetails?.operations, [.init(operation: "update", path: "new.swift", oldPath: "old.swift")])
        XCTAssertNil(tool.fileChangeDetails?.additions)
        let claude = ClaudeAgentRuntime(onEvent: { transcript.receive($0) })
        claude.beginTurn()
        claude.receive(["type": "assistant", "message": ["id": "edit-message", "content": [
            ["type": "tool_use", "id": "edit", "name": "Edit", "input": ["file_path": "file.txt"]],
        ]]])
        claude.receive(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "edit", "content": "Updated"],
        ]], "tool_use_result": ["filePath": "file.txt", "structuredPatch": [
            ["oldStart": 1, "oldLines": 1, "newStart": 1, "newLines": 1, "lines": ["-before", "+after"]],
        ]]])
        XCTAssertEqual(transcript.items["edit"]?.tool?.fileChangeDetails?.diff, "--- file.txt\n+++ file.txt\n@@ -1,1 +1,1 @@\n-before\n+after\n")
    }

    func testCommandInspectorIdentitySurvivesSemanticReadCategoryAndPersistence() throws {
        let transcript = ProviderReplayTranscript()
        let normalizer = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        normalizer.receive(["method": "item/completed", "params": ["item": [
            "id": "read-command", "type": "commandExecution", "command": "cat README.md",
            "status": "completed", "exitCode": 0, "aggregatedOutput": "Read me",
            "commandActions": [["type": "read", "path": "README.md"]],
        ]]])
        let tool = try XCTUnwrap(transcript.items["read-command"]?.tool)
        XCTAssertEqual(tool.category, .read)
        XCTAssertEqual(tool.presentation, .command)
        XCTAssertTrue(tool.presentsCommand)
        let restored = try JSONDecoder().decode(AgentToolActivity.self, from: JSONEncoder().encode(tool))
        XCTAssertEqual(restored, tool)
        XCTAssertTrue(restored.presentsCommand)
        let legacy = try JSONDecoder().decode(AgentToolActivity.self, from: Data(#"{"category":"command"}"#.utf8))
        XCTAssertTrue(legacy.presentsCommand)
        XCTAssertFalse(agentToolOutputIsJSON("null"))
        XCTAssertFalse(agentToolOutputIsJSON(["content": [["type": "text", "text": "{}"]]]))
        XCTAssertTrue(agentToolOutputIsJSON(["result": [1, 2, 3]]))
    }

    func testClaudeRecordedMultiTurnKeepsFreshMessageIdentity() throws {
        let transcript = ProviderReplayTranscript()
        let normalizer = ClaudeAgentRuntime(onEvent: { transcript.receive($0) })
        let frames = try decode(Self.claudeMultiTurn)
        normalizer.beginTurn()
        frames.prefix(2).forEach(normalizer.receive)
        XCTAssertEqual(transcript.items["msg_018QDgm81Jgo5XonK3Bm8dEc"]?.text, "first fixture turn complete")
        normalizer.beginTurn()
        frames.suffix(2).forEach(normalizer.receive)
        XCTAssertEqual(transcript.assistantTexts, ["first fixture turn complete", "second fixture turn complete"])
        XCTAssertTrue(transcript.items.values.allSatisfy(\.isComplete))
        XCTAssertTrue(transcript.deltas.isEmpty, "This SDK recording contains assembled messages only")
    }

    func testClaudeRecordedCommandPreservesBlocksToolOutputAndDistinctAnswer() throws {
        let transcript = ProviderReplayTranscript()
        let normalizer = ClaudeAgentRuntime(onEvent: { transcript.receive($0) })
        normalizer.beginTurn()
        let frames = try decode(Self.claudeCommand)
        for frame in frames {
            normalizer.receive(frame)
            if frame["type"] as? String == "assistant" {
                // A tool-only assistant frame shares the prose message ID.
                XCTAssertEqual(transcript.items["msg_011CfefxsSL5BaoUrPAkdYT6"]?.text, "Running the specified command now.")
            }
        }
        XCTAssertEqual(transcript.assistantTexts, ["Running the specified command now.", "command output fixture complete"])
        XCTAssertEqual(transcript.deltas["msg_011CfefxsSL5BaoUrPAkdYT6"], "Running the specified command now.")
        XCTAssertEqual(transcript.deltas["msg_011CfefyTbebJFTYTaoceKGP"], "command output fixture complete")
        let tool = try XCTUnwrap(transcript.items["toolu_01CJnQSvsvh3iZtmvSWQVVvg"])
        XCTAssertEqual(tool.kind, .tool)
        XCTAssertEqual(tool.text, "Bash")
        XCTAssertEqual(tool.detail, "\u{1b}[32mstream line 1\u{1b}[0m\n\u{1b}[32mstream line 2\u{1b}[0m\n\u{1b}[32mstream line 3\u{1b}[0m\n\u{1b}[32mstream line 4\u{1b}[0m\nprogress 50%\rprogress 100%")
        XCTAssertTrue(tool.isComplete)
        XCTAssertEqual(transcript.items.count, 3, "Thinking and SDK result must not add chat rows")
    }

    func testClaudeRecordedRestrictedToolCompletesUnderNativeToolID() throws {
        let transcript = ProviderReplayTranscript()
        let normalizer = ClaudeAgentRuntime(onEvent: { transcript.receive($0) })
        normalizer.beginTurn()
        let frames = try decode(Self.claudeRestricted)
        normalizer.receive(frames[0])
        let id = "toolu_01Ayxc73fyGSj2frmw8XLmJn"
        XCTAssertEqual(transcript.items[id]?.isComplete, false)
        XCTAssertTrue(transcript.items[id]?.detail?.contains(".codex-probe-write-action.txt") == true)
        frames.dropFirst().forEach(normalizer.receive)
        XCTAssertEqual(transcript.items[id]?.detail, "(Bash completed with no output)")
        XCTAssertEqual(transcript.items[id]?.isComplete, true)
        XCTAssertEqual(transcript.assistantTexts, [Self.claudeRestrictedAnswer])
        XCTAssertEqual(transcript.items.count, 2)
    }

    func testCodexRecordedMultiTurnDoesNotAppendCompletedTextTwice() throws {
        let transcript = ProviderReplayTranscript()
        let normalizer = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        try decode(Self.codexMultiTurn).forEach(normalizer.receive)
        XCTAssertEqual(transcript.assistantTexts, ["first fixture turn complete", "second fixture turn complete"])
        XCTAssertEqual(transcript.deltas["msg_06900ecb02a780a6016ab5bdbcd76887d0ba52ca8fee9da2e1"], "first fixture turn complete")
        XCTAssertEqual(transcript.deltas["msg_06900ecb02a780a6016ab5bdbf08a087d08c1dafcd3f15697a"], "second fixture turn complete")
        XCTAssertTrue(transcript.items.values.allSatisfy(\.isComplete))
    }

    func testCodexRecordedCommandReplacesOutputAggregateAndRetainsCommentary() throws {
        let transcript = ProviderReplayTranscript()
        let normalizer = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        let frames = try decode(Self.codexCommand)
        let id = "exec-1a2dcd5e-1591-48a8-bb8e-47cb40883d2c"
        var streamedOutput = ""
        for frame in frames {
            normalizer.receive(frame)
            if frame["method"] as? String == "item/commandExecution/outputDelta" {
                let params = try XCTUnwrap(frame["params"] as? [String: Any])
                streamedOutput += try XCTUnwrap(params["delta"] as? String)
                XCTAssertEqual(transcript.items[id]?.detail, streamedOutput, "Output must be visible before item/completed")
                XCTAssertEqual(transcript.items[id]?.isComplete, false)
            }
        }
        // The recording itself starts output at line 2; do not fabricate a missing line 1.
        XCTAssertEqual(transcript.items[id]?.detail, "\u{1b}[32mstream line 2\u{1b}[0m\n\u{1b}[32mstream line 3\u{1b}[0m\n\u{1b}[32mstream line 4\u{1b}[0m\nprogress 50%\rprogress 100%\n\nExit code: 0")
        XCTAssertEqual(transcript.items[id]?.isComplete, true)
        XCTAssertEqual(transcript.assistantTexts, ["I’ll run the command in the foreground and wait for it to finish.", "command output fixture complete"])
        XCTAssertEqual(transcript.deltas["msg_0038d12d01b50ff0016ac0842a975c87d2bf566b8ae1f7e5f3"], "command output fixture complete")
        XCTAssertEqual(transcript.items.count, 3)
    }

    func testCodexRecordedRestrictedFileChangeRetainsDiffAndSeparateMessages() throws {
        let transcript = ProviderReplayTranscript()
        let normalizer = CodexAgentRuntime(onEvent: { transcript.receive($0) })
        let frames = try decode(Self.codexRestricted)
        let id = "exec-114e8eef-018a-444d-8542-aa0232ff1f38"
        for frame in frames {
            normalizer.receive(frame)
            if frame["method"] as? String == "item/fileChange/requestApproval" {
                XCTAssertEqual(transcript.items[id]?.isComplete, false)
            }
        }
        let tool = try XCTUnwrap(transcript.items[id])
        XCTAssertTrue(tool.isComplete)
        let changes = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((tool.detail ?? "").utf8)) as? [[String: Any]])
        XCTAssertEqual(changes.first?["path"] as? String, "/home/replay-user/conversation/packages/effect-codex-app-server/.codex-probe-write-action.txt")
        XCTAssertEqual(changes.first?["diff"] as? String, "codex app-server approval fixture.\n")
        XCTAssertEqual(transcript.assistantTexts, ["Created `.codex-probe-write-action.txt` with exactly:\n\n```text\ncodex app-server approval fixture.\n```", "I’ll create the requested fixture file locally with that exact single-line content."])
        XCTAssertEqual(transcript.items.count, 3, "Reasoning and approval RPC are not additional transcript items")
    }

    private func decode(_ jsonl: String) throws -> [[String: Any]] {
        try jsonl.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    // multi_turn/claude_transcript.ndjson:7,9,12,13. Usage/session metadata omitted.
    private static let claudeMultiTurn = #"""
    {"type":"assistant","message":{"id":"msg_018QDgm81Jgo5XonK3Bm8dEc","content":[{"type":"text","text":"first fixture turn complete"}]},"parent_tool_use_id":null}
    {"type":"result","subtype":"success","is_error":false,"result":"first fixture turn complete"}
    {"type":"assistant","message":{"id":"msg_01PifXzuLoccLsnMjRC9hXJ8","content":[{"type":"text","text":"second fixture turn complete"}]},"parent_tool_use_id":null}
    {"type":"result","subtype":"success","is_error":false,"result":"second fixture turn complete"}
    """#

    // command_output_streaming/claude_transcript.ndjson:10,32–38,60,63,66,68–76.
    // Tool input fragments (39–59) and thinking/usage metadata omitted, not synthesized.
    private static let claudeCommand = #"""
    {"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_011CfefxsSL5BaoUrPAkdYT6","content":[]}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Running"}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" the specified"}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" command now."}},"parent_tool_use_id":null}
    {"type":"assistant","message":{"id":"msg_011CfefxsSL5BaoUrPAkdYT6","content":[{"type":"text","text":"Running the specified command now."}]},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_stop","index":1},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01CJnQSvsvh3iZtmvSWQVVvg","name":"Bash","input":{},"caller":{"type":"direct"}}},"parent_tool_use_id":null}
    {"type":"assistant","message":{"id":"msg_011CfefxsSL5BaoUrPAkdYT6","content":[{"type":"tool_use","id":"toolu_01CJnQSvsvh3iZtmvSWQVVvg","name":"Bash","input":{"command":"for i in 1 2 3 4; do printf '\\033[32mstream line %s\\033[0m\\n' $i; sleep 1; done; printf 'progress 50%%\\rprogress 100%%\\n'"},"caller":{"type":"direct"}}]},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"message_stop"},"parent_tool_use_id":null}
    {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01CJnQSvsvh3iZtmvSWQVVvg","type":"tool_result","content":"\u001b[32mstream line 1\u001b[0m\n\u001b[32mstream line 2\u001b[0m\n\u001b[32mstream line 3\u001b[0m\n\u001b[32mstream line 4\u001b[0m\nprogress 50%\rprogress 100%","is_error":false}]},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_011CfefyTbebJFTYTaoceKGP","content":[]}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"command"}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" output fixture complete"}},"parent_tool_use_id":null}
    {"type":"assistant","message":{"id":"msg_011CfefyTbebJFTYTaoceKGP","content":[{"type":"text","text":"command output fixture complete"}]},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_stop","index":0},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"message_stop"},"parent_tool_use_id":null}
    {"type":"result","subtype":"success","is_error":false,"result":"command output fixture complete"}
    """#

    private static let claudeRestrictedAnswer = "Done. The file `.codex-probe-write-action.txt` was created (or overwritten) in the current directory with the exact content `codex app-server approval fixture` — no trailing newline, no extra characters."

    // tool_call_restricted_granular/claude_transcript.ndjson:8,12–14.
    private static let claudeRestricted = #"""
    {"type":"assistant","message":{"id":"msg_01DbHDhWivNDrjU961RBEG9p","content":[{"type":"tool_use","id":"toolu_01Ayxc73fyGSj2frmw8XLmJn","name":"Bash","input":{"command":"printf 'codex app-server approval fixture' > .codex-probe-write-action.txt","description":"Write exact text to .codex-probe-write-action.txt"},"caller":{"type":"direct"}}]},"parent_tool_use_id":null}
    {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01Ayxc73fyGSj2frmw8XLmJn","type":"tool_result","content":"(Bash completed with no output)","is_error":false}]},"parent_tool_use_id":null}
    {"type":"assistant","message":{"id":"msg_014BHCrtTfAbEdhQ3oBkZUAZ","content":[{"type":"text","text":"Done. The file `.codex-probe-write-action.txt` was created (or overwritten) in the current directory with the exact content `codex app-server approval fixture` — no trailing newline, no extra characters."}]},"parent_tool_use_id":null}
    {"type":"result","subtype":"success","is_error":false,"result":"Done. The file `.codex-probe-write-action.txt` was created (or overwritten) in the current directory with the exact content `codex app-server approval fixture` — no trailing newline, no extra characters."}
    """#

    // multi_turn/codex_transcript.ndjson:21–26,29,37–42,45. Routing/timing metadata omitted.
    private static let codexMultiTurn = #"""
    {"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_06900ecb02a780a6016ab5bdbcd76887d0ba52ca8fee9da2e1","text":"","phase":"final_answer"}}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_06900ecb02a780a6016ab5bdbcd76887d0ba52ca8fee9da2e1","delta":"first"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_06900ecb02a780a6016ab5bdbcd76887d0ba52ca8fee9da2e1","delta":" fixture"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_06900ecb02a780a6016ab5bdbcd76887d0ba52ca8fee9da2e1","delta":" turn"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_06900ecb02a780a6016ab5bdbcd76887d0ba52ca8fee9da2e1","delta":" complete"}}
    {"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_06900ecb02a780a6016ab5bdbcd76887d0ba52ca8fee9da2e1","text":"first fixture turn complete","phase":"final_answer"}}}
    {"method":"turn/completed","params":{"turn":{"id":"01a0d5ed-1957-7a22-8399-d0172af342fd","status":"completed","error":null}}}
    {"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_06900ecb02a780a6016ab5bdbf08a087d08c1dafcd3f15697a","text":"","phase":"final_answer"}}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_06900ecb02a780a6016ab5bdbf08a087d08c1dafcd3f15697a","delta":"second"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_06900ecb02a780a6016ab5bdbf08a087d08c1dafcd3f15697a","delta":" fixture"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_06900ecb02a780a6016ab5bdbf08a087d08c1dafcd3f15697a","delta":" turn"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_06900ecb02a780a6016ab5bdbf08a087d08c1dafcd3f15697a","delta":" complete"}}
    {"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_06900ecb02a780a6016ab5bdbf08a087d08c1dafcd3f15697a","text":"second fixture turn complete","phase":"final_answer"}}}
    {"method":"turn/completed","params":{"turn":{"id":"01a0d5ed-2b29-7353-a6d5-7745731173b7","status":"completed","error":null}}}
    """#

    // command_output_streaming/codex_transcript.ndjson:46–52,55–60,64.
    // Commentary deltas 31–45 omitted; the completed commentary is retained verbatim.
    private static let codexCommand = #"""
    {"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_0038d12d01b50ff0016ac08420563087d2af7fb28a3cee1956","text":"I’ll run the command in the foreground and wait for it to finish.","phase":"commentary"}}}
    {"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-1a2dcd5e-1591-48a8-bb8e-47cb40883d2c","command":"/bin/zsh -lc \"for i in 1 2 3 4; do printf '\\\\033[32mstream line %s\\\\033[0m\\\\n' \"'$i; sleep 1; done; printf '\"'progress 50%%\\\\rprogress 100%%\\\\n'\"","aggregatedOutput":null,"exitCode":null,"status":"inProgress"}}}
    {"method":"item/commandExecution/outputDelta","params":{"itemId":"exec-1a2dcd5e-1591-48a8-bb8e-47cb40883d2c","delta":"\u001b[32mstream line 2\u001b[0m\n"}}
    {"method":"item/commandExecution/outputDelta","params":{"itemId":"exec-1a2dcd5e-1591-48a8-bb8e-47cb40883d2c","delta":"\u001b[32mstream line 3\u001b[0m\n"}}
    {"method":"item/commandExecution/outputDelta","params":{"itemId":"exec-1a2dcd5e-1591-48a8-bb8e-47cb40883d2c","delta":"\u001b[32mstream line 4\u001b[0m\n"}}
    {"method":"item/commandExecution/outputDelta","params":{"itemId":"exec-1a2dcd5e-1591-48a8-bb8e-47cb40883d2c","delta":"progress 50%\rprogress 100%\n"}}
    {"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-1a2dcd5e-1591-48a8-bb8e-47cb40883d2c","command":"/bin/zsh -lc \"for i in 1 2 3 4; do printf '\\\\033[32mstream line %s\\\\033[0m\\\\n' \"'$i; sleep 1; done; printf '\"'progress 50%%\\\\rprogress 100%%\\\\n'\"","aggregatedOutput":"\u001b[32mstream line 2\u001b[0m\n\u001b[32mstream line 3\u001b[0m\n\u001b[32mstream line 4\u001b[0m\nprogress 50%\rprogress 100%\n","exitCode":0,"status":"completed"}}}
    {"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_0038d12d01b50ff0016ac0842a975c87d2bf566b8ae1f7e5f3","text":"","phase":"final_answer"}}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_0038d12d01b50ff0016ac0842a975c87d2bf566b8ae1f7e5f3","delta":"command"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_0038d12d01b50ff0016ac0842a975c87d2bf566b8ae1f7e5f3","delta":" output"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_0038d12d01b50ff0016ac0842a975c87d2bf566b8ae1f7e5f3","delta":" fixture"}}
    {"method":"item/agentMessage/delta","params":{"itemId":"msg_0038d12d01b50ff0016ac0842a975c87d2bf566b8ae1f7e5f3","delta":" complete"}}
    {"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_0038d12d01b50ff0016ac0842a975c87d2bf566b8ae1f7e5f3","text":"command output fixture complete","phase":"final_answer"}}}
    {"method":"turn/completed","params":{"turn":{"id":"01a10004-0b1b-78f0-a41c-b253bded078e","status":"completed","error":null}}}
    """#

    // tool_call_restricted_granular/codex_transcript.ndjson:21,25,42,43,45,49,76,79.
    // Assembled messages retained; their deltas omitted. Numeric approval ID 0 is native.
    private static let codexRestricted = #"""
    {"method":"item/started","params":{"item":{"type":"reasoning","id":"rs_08bfce1a588b6283016ab5c3b2f48487d08c265fbb08c31486","summary":[],"content":[]}}}
    {"method":"item/completed","params":{"item":{"type":"reasoning","id":"rs_08bfce1a588b6283016ab5c3b2f48487d08c265fbb08c31486","summary":["**Planning patch application despite sandbox restrictions**"],"content":[]}}}
    {"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_08bfce1a588b6283016ab5c3b41e5c87d0badb0d609ab7ddf4","text":"I’ll create the requested fixture file locally with that exact single-line content.","phase":"commentary"}}}
    {"method":"item/started","params":{"item":{"type":"fileChange","id":"exec-114e8eef-018a-444d-8542-aa0232ff1f38","changes":[{"path":"/home/replay-user/conversation/packages/effect-codex-app-server/.codex-probe-write-action.txt","kind":{"type":"add"},"diff":"codex app-server approval fixture.\n"}],"status":"inProgress"}}}
    {"method":"item/fileChange/requestApproval","id":0,"params":{"itemId":"exec-114e8eef-018a-444d-8542-aa0232ff1f38","reason":null,"grantRoot":null}}
    {"method":"item/completed","params":{"item":{"type":"fileChange","id":"exec-114e8eef-018a-444d-8542-aa0232ff1f38","changes":[{"path":"/home/replay-user/conversation/packages/effect-codex-app-server/.codex-probe-write-action.txt","kind":{"type":"add"},"diff":"codex app-server approval fixture.\n"}],"status":"completed"}}}
    {"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_08bfce1a588b6283016ab5c3b7ef0c87d096aba0299c914020","text":"Created `.codex-probe-write-action.txt` with exactly:\n\n```text\ncodex app-server approval fixture.\n```","phase":"final_answer"}}}
    {"method":"turn/completed","params":{"turn":{"id":"01a0d604-6358-72f1-bb89-7361cce0045c","status":"completed","error":null}}}
    """#
}

/// Applies the same replacement/delta semantics as AgentSessions without a provider process.
private final class ProviderReplayTranscript: @unchecked Sendable {
    private(set) var items: [String: AgentChatItem] = [:]
    private(set) var deltas: [String: String] = [:]

    var assistantTexts: [String] {
        items.values.filter { $0.kind == .assistant }.map(\.text).sorted()
    }

    func receive(_ event: AgentRuntimeEvent) {
        switch event {
        case .item(let item), .toolItem(let item, _): items[item.id] = item
        case .textDelta(let id, let text):
            items[id]?.text += text
            deltas[id, default: ""] += text
        default: break
        }
    }
}
