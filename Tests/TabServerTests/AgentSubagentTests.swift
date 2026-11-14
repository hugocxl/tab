import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// Claude Code 2.x stream-json task messages, recorded from a foreground and a background Agent call.
final class AgentSubagentTests: XCTestCase {
    func testForegroundAndBackgroundAgentsStayVisibleUntilTheyFinish() throws {
        let recorder = SubagentRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(try json(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_fg","name":"Agent","input":{"description":"fg probe","prompt":"ls"}}]}}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"task_started","task_id":"a_fg","tool_use_id":"toolu_fg","description":"fg probe","subagent_type":"general-purpose","is_backgrounded":false,"task_type":"local_agent"}"#))
        runtime.receive(try json(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_bg","name":"Agent","input":{"description":"bg probe","prompt":"sleep","run_in_background":true}}]}}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"task_started","task_id":"a_bg","tool_use_id":"toolu_bg","description":"bg probe","subagent_type":"general-purpose","is_backgrounded":true,"task_type":"local_agent"}"#))
        runtime.receive(try json(#"{"type":"user","message":{"content":[{"tool_use_id":"toolu_bg","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]}}"#))
        XCTAssertEqual(recorder.running.map(\.id), ["a_fg", "a_bg"])
        XCTAssertEqual(recorder.running.map(\.background), [false, true])

        runtime.receive(try json(#"{"type":"system","subtype":"task_progress","task_id":"a_bg","tool_use_id":"toolu_bg","description":"Running Sleep 3 seconds","usage":{"total_tokens":17585,"tool_uses":1,"duration_ms":992},"last_tool_name":"Bash"}"#))
        XCTAssertEqual(recorder.latest.last?.activity, "Running Sleep 3 seconds")
        XCTAssertEqual(recorder.latest.last?.toolUses, 1)
        XCTAssertEqual(recorder.latest.last?.tokens, 17585)

        // A subagent's own shell task is not an agent.
        runtime.receive(try json(#"{"type":"system","subtype":"task_started","task_id":"b_sh","owned_by_subagent":true,"tool_use_id":"toolu_sh","description":"Sleep","parent_task_id":"a_bg","task_type":"local_bash"}"#))
        XCTAssertEqual(recorder.running.count, 2)

        runtime.receive(try json(#"{"type":"system","subtype":"task_updated","task_id":"a_fg","patch":{"status":"completed"}}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"task_notification","task_id":"a_fg","tool_use_id":"toolu_fg","status":"completed","summary":"DONE"}"#))
        XCTAssertEqual(recorder.running.map(\.id), ["a_bg"])
        // A finished agent stays listed with its outcome until the next prompt.
        XCTAssertEqual(recorder.latest.first { $0.id == "a_fg" }?.status, .completed)
        XCTAssertEqual(recorder.latest.first { $0.id == "a_fg" }?.activity, "DONE")
        XCTAssertNotNil(recorder.latest.first { $0.id == "a_fg" }?.finishedAt)

        // The turn ends while the background agent works on.
        runtime.receive(try json(#"{"type":"result","subtype":"success"}"#))
        XCTAssertEqual(recorder.running.map(\.id), ["a_bg"])

        runtime.receive(try json(#"{"type":"system","subtype":"task_updated","task_id":"a_bg","patch":{"status":"completed"}}"#))
        XCTAssertTrue(recorder.running.isEmpty)
        runtime.receive(try json(#"{"type":"system","subtype":"task_notification","task_id":"a_bg","tool_use_id":"toolu_bg","status":"completed","summary":"BG finished"}"#))
        let row = try XCTUnwrap(recorder.items.last { $0.id == "toolu_bg" })
        XCTAssertEqual(row.tool?.output, "BG finished", "The background agent's report replaces its launch note")
        XCTAssertEqual(row.tool?.status, .completed)
    }

    func testEndingTheProcessClearsRunningAgents() throws {
        let recorder = SubagentRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(try json(#"{"type":"system","subtype":"task_started","task_id":"a_bg","tool_use_id":"toolu_bg","description":"bg","is_backgrounded":true,"task_type":"local_agent"}"#))
        XCTAssertEqual(recorder.latest.count, 1)
        XCTAssertEqual(runtime.endProcess(), 1, "The caller is told how many agents stopped")
        XCTAssertTrue(recorder.latest.isEmpty)
    }

    func testSnapshotFromAnOlderServerDecodesWithoutSubagents() throws {
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertNil(object["subagents"])
        object["subagents"] = [["id": "a", "description": "Review", "status": "paused", "future": 1]]
        let decoded = try JSONDecoder().decode(AgentChatSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.subagents?.first?.status, .completed, "An unknown status reads as finished")
    }

    /// The order Claude Code 2.1.311 sends a background agent in, hand-copied from a real
    /// capture with identifying fields removed.
    func testRecordedBackgroundAgentSequenceShowsTheAgentAndItsSteps() throws {
        let recorder = SubagentRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        let lines = [
            #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"description":"bg probe","prompt":"Run the shell command: sleep 4. Then reply DONE.","subagent_type":"general-purpose","run_in_background":true}}]},"parent_tool_use_id":null}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a97","run_id":"r1","task_type":"local_agent","subagent_type":"general-purpose","description":"bg probe"}]}"#,
            #"{"type":"system","subtype":"task_started","task_id":"a97","run_id":"r1","tool_use_id":"toolu_agent","description":"bg probe","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent","prompt":"Run the shell command: sleep 4. Then reply DONE."}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_agent","type":"tool_result","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"parent_tool_use_id":null}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"LAUNCHED"}"#,
            #"{"type":"assistant","message":{"id":"msg_c1","content":[{"type":"tool_use","id":"toolu_sleep","name":"Bash","input":{"command":"sleep 4","description":"Sleep for 4 seconds"}}]},"parent_tool_use_id":"toolu_agent","agent_id":"a97"}"#,
            #"{"type":"system","subtype":"task_progress","task_id":"a97","run_id":"r1","tool_use_id":"toolu_agent","description":"Running Sleep for 4 seconds","subagent_type":"general-purpose","usage":{"total_tokens":12706,"tool_uses":1,"duration_ms":983},"last_tool_name":"Bash"}"#,
            #"{"type":"system","subtype":"task_started","task_id":"bsh","run_id":"r2","owned_by_subagent":true,"tool_use_id":"toolu_sleep","description":"Sleep for 4 seconds","is_backgrounded":false,"parent_task_id":"a97","task_type":"local_bash"}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"bsh","run_id":"r2","tool_use_id":"toolu_sleep","status":"completed","output_file":"","summary":"Sleep for 4 seconds"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_sleep","type":"tool_result","content":"(Bash completed with no output)","is_error":false}]},"parent_tool_use_id":"toolu_agent","agent_id":"a97"}"#,
            #"{"type":"assistant","message":{"id":"msg_c2","content":[{"type":"text","text":"DONE"}]},"parent_tool_use_id":"toolu_agent","agent_id":"a97"}"#,
        ]
        for (index, line) in lines.enumerated() {
            runtime.receive(try json(line))
            if index == 1 {
                XCTAssertEqual(recorder.running.map(\.id), ["a97"], "The background task list alone shows the agent")
                XCTAssertTrue(recorder.running.first?.background == true)
            }
            if index == 2 { XCTAssertEqual(recorder.running.first?.toolUseID, "toolu_agent", "task_started links its tool") }
        }
        XCTAssertEqual(recorder.running.map(\.id), ["a97"], "The agent's own shell is not an agent")
        XCTAssertEqual(recorder.running.first?.activity, "Running Sleep for 4 seconds")
        let steps = try XCTUnwrap(recorder.steps["toolu_agent"])
        XCTAssertEqual(steps.map(\.id), ["toolu_sleep", "msg_c2"])
        XCTAssertEqual(steps.first?.tool?.status, .completed)
        XCTAssertEqual(steps.last?.text, "DONE")
        XCTAssertFalse(recorder.items.contains { $0.id == "msg_c2" }, "The agent's text stays out of the conversation")

        runtime.receive(try json(#"{"type":"system","subtype":"task_updated","task_id":"a97","run_id":"r1","patch":{"status":"completed","end_time":1794575987512}}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"task_notification","task_id":"a97","run_id":"r1","tool_use_id":"toolu_agent","status":"completed","output_file":"/tmp/x.output","summary":"DONE","usage":{"total_tokens":13991,"tool_uses":1,"duration_ms":6172}}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#))
        XCTAssertTrue(recorder.running.isEmpty)
        XCTAssertEqual(recorder.latest.map(\.status), [.completed])
        XCTAssertEqual(runtime.lastFinishedBackground?.description, "bg probe")
        runtime.clearFinishedSubagents()
        XCTAssertTrue(recorder.latest.isEmpty, "The next prompt clears finished agents")
    }

    func testBackgroundAgentMissingFromTheTaskListIsFinished() throws {
        let recorder = SubagentRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(try json(#"{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"t1","description":"one","is_backgrounded":true,"task_type":"local_agent"}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"task_started","task_id":"a2","tool_use_id":"t2","description":"two","is_backgrounded":true,"task_type":"local_agent"}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a2","task_type":"local_agent","description":"two"},{"task_id":"s1","task_type":"local_bash","description":"shell"}]}"#))
        XCTAssertEqual(recorder.running.map(\.id), ["a2"], "Shell tasks in the list are not agents")
        XCTAssertEqual(recorder.latest.first { $0.id == "a1" }?.status, .completed)
    }

    /// A tool's input used to arrive only when its block ended; while Claude wrote a large
    /// file the row was a bare name. The path is sent as soon as it is complete.
    func testToolInputPathIsSentBeforeTheBlockEnds() throws {
        let recorder = SubagentRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.beginTurn()
        runtime.receive(try json(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"}}}"#))
        runtime.receive(try json(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"w","name":"Write","input":{}}}}"#))
        runtime.receive(try json(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\":\"/repo/Sour"}}}"#))
        XCTAssertNil(recorder.items.last { $0.id == "w" }?.tool?.filePaths, "Half a path is not sent")
        runtime.receive(try json(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"ces/Big.swift\",\"content\":\"line 1\\n"}}}"#))
        XCTAssertEqual(recorder.items.last { $0.id == "w" }?.tool?.filePaths, ["/repo/Sources/Big.swift"])
        let sent = recorder.items.filter { $0.id == "w" }.count
        runtime.receive(try json(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"line 2\\n"}}}"#))
        XCTAssertEqual(recorder.items.filter { $0.id == "w" }.count, sent, "Each field is sent once, not per fragment")
    }

    private func json(_ source: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    }
}

private final class SubagentRecorder: @unchecked Sendable {
    var latest: [AgentSubagent] = []
    var items: [AgentChatItem] = []
    var steps: [String: [AgentChatItem]] = [:]
    var running: [AgentSubagent] { latest.filter { $0.status == .running } }
    func receive(_ event: AgentRuntimeEvent) {
        if case .subagents(let subagents) = event { latest = subagents }
        if case .item(let item) = event { items.append(item) }
        if case .subagentSteps(let id, let list) = event { steps[id] = list }
    }
}
