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
        XCTAssertEqual(recorder.latest.map(\.id), ["a_fg", "a_bg"])
        XCTAssertEqual(recorder.latest.map(\.background), [false, true])

        runtime.receive(try json(#"{"type":"system","subtype":"task_progress","task_id":"a_bg","tool_use_id":"toolu_bg","description":"Running Sleep 3 seconds","usage":{"total_tokens":17585,"tool_uses":1,"duration_ms":992},"last_tool_name":"Bash"}"#))
        XCTAssertEqual(recorder.latest.last?.activity, "Running Sleep 3 seconds")
        XCTAssertEqual(recorder.latest.last?.toolUses, 1)
        XCTAssertEqual(recorder.latest.last?.tokens, 17585)

        // A subagent's own shell task is not an agent.
        runtime.receive(try json(#"{"type":"system","subtype":"task_started","task_id":"b_sh","owned_by_subagent":true,"tool_use_id":"toolu_sh","description":"Sleep","parent_task_id":"a_bg","task_type":"local_bash"}"#))
        XCTAssertEqual(recorder.latest.count, 2)

        runtime.receive(try json(#"{"type":"system","subtype":"task_updated","task_id":"a_fg","patch":{"status":"completed"}}"#))
        runtime.receive(try json(#"{"type":"system","subtype":"task_notification","task_id":"a_fg","tool_use_id":"toolu_fg","status":"completed","summary":"DONE"}"#))
        XCTAssertEqual(recorder.latest.map(\.id), ["a_bg"])

        // The turn ends while the background agent works on.
        runtime.receive(try json(#"{"type":"result","subtype":"success"}"#))
        XCTAssertEqual(recorder.latest.map(\.id), ["a_bg"])

        runtime.receive(try json(#"{"type":"system","subtype":"task_updated","task_id":"a_bg","patch":{"status":"completed"}}"#))
        XCTAssertTrue(recorder.latest.isEmpty)
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
        runtime.endProcess()
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

    private func json(_ source: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    }
}

private final class SubagentRecorder: @unchecked Sendable {
    var latest: [AgentSubagent] = []
    var items: [AgentChatItem] = []
    func receive(_ event: AgentRuntimeEvent) {
        if case .subagents(let subagents) = event { latest = subagents }
        if case .item(let item) = event { items.append(item) }
    }
}
