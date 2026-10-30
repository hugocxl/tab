import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// Only synthetic subprocesses: these tests never execute an installed provider.
final class AgentAccessTests: XCTestCase {
    func testDefaultAutoAllowsOnlyReadAndWebToolCallbacksWithoutWaiting() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        for tool in Read Glob Grep WebSearch WebFetch; do
          emit "{\"type\":\"control_request\",\"request_id\":\"request-$tool\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"$tool\",\"tool_use_id\":\"tool-$tool\",\"input\":{\"query\":\"requested by user\"}}}"
          take
        done
        emit '{"type":"result","subtype":"success","is_error":false}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "all safe tools completed without UI approval")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "Search the web", model: nil)
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertFalse(recorder.statuses.contains(.waiting))
        let responses = try fixture.messages().compactMap { $0["response"] as? [String: Any] }
        XCTAssertEqual(responses.count, 5)
        for tool in ["Read", "Glob", "Grep", "WebSearch", "WebFetch"] {
            let response = try XCTUnwrap(responses.first { $0["request_id"] as? String == "request-\(tool)" })
            let permission = try XCTUnwrap(response["response"] as? [String: Any])
            XCTAssertEqual(permission["behavior"] as? String, "allow")
            XCTAssertEqual(permission["toolUseID"] as? String, "tool-\(tool)")
            XCTAssertEqual((permission["updatedInput"] as? [String: Any])?["query"] as? String, "requested by user")
        }
    }

    func testAskModeKeepsWebSearchPendingUntilExplicitApproval() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"control_request","request_id":"ask-search","request":{"subtype":"can_use_tool","tool_name":"WebSearch","input":{"query":"weather"}}}'
        take
        emit '{"type":"result","subtype":"success","is_error":false}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let waiting = expectation(description: "search asks")
        let idle = expectation(description: "search approved")
        recorder.observe = { event in
            if case .status(.waiting) = event { waiting.fulfill() }
            if case .status(.idle) = event { idle.fulfill() }
        }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.setAccess(.ask)
        try await runtime.send(text: "Search", model: nil)
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(recorder.transcript["ask-search"]?.isComplete, false)
        XCTAssertEqual(try fixture.messages().count, 2, "Ask mode must not send an automatic permission response")
        try await runtime.approve(request: "ask-search", allow: true)
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(recorder.transcript["ask-search"]?.text, "Approved")
    }

    func testExplicitFullAccessAllowsWritesButNeverAnswersStructuredQuestions() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"control_request","request_id":"write","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/project/example","content":"hello"}}}'
        take
        emit '{"type":"control_request","request_id":"question","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[]}}}'
        take
        emit '{"type":"result","subtype":"success","is_error":false}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "write allowed, question denied")
        recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.setAccess(.fullAccess)
        try await runtime.send(text: "Write", model: nil)
        await fulfillment(of: [idle], timeout: 5)
        let responses = try fixture.messages().compactMap { $0["response"] as? [String: Any] }
        let write = try XCTUnwrap(responses.first { $0["request_id"] as? String == "write" }?["response"] as? [String: Any])
        let question = try XCTUnwrap(responses.first { $0["request_id"] as? String == "question" }?["response"] as? [String: Any])
        XCTAssertEqual(write["behavior"] as? String, "allow")
        XCTAssertEqual((write["updatedInput"] as? [String: Any])?["content"] as? String, "hello")
        XCTAssertEqual(question["behavior"] as? String, "deny")
        XCTAssertFalse(recorder.statuses.contains(.waiting))
        XCTAssertTrue(recorder.transcript.values.contains { $0.kind == .notice && $0.text.contains("structured question") })
    }

    func testChangingPendingAskToAutoResolvesSearchButLeavesCommandWaiting() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"control_request","request_id":"a-search","request":{"subtype":"can_use_tool","tool_name":"WebSearch","input":{"query":"weather"}}}'
        emit '{"type":"control_request","request_id":"b-command","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch /project/example"}}}'
        take
        take
        emit '{"type":"result","subtype":"success","is_error":false}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let pending = expectation(description: "both permissions pending")
        let idle = expectation(description: "explicit full access resolves command")
        recorder.observe = { event in
            if case .item(let item) = event, item.id == "b-command", !item.isComplete { pending.fulfill() }
            if case .status(.idle) = event { idle.fulfill() }
        }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.setAccess(.ask)
        try await runtime.send(text: "Search and change a file", model: nil)
        await fulfillment(of: [pending], timeout: 5)
        try await runtime.setAccess(.standard)
        XCTAssertEqual(recorder.transcript["a-search"]?.isComplete, true)
        XCTAssertEqual(recorder.transcript["b-command"]?.isComplete, false)
        XCTAssertEqual(recorder.statuses.last, .waiting)
        XCTAssertFalse(recorder.statuses.dropFirst().contains(.working), "Do not clear waiting while another permission is pending")
        try await runtime.approve(request: "a-search", allow: true)
        XCTAssertEqual(recorder.statuses.last, .waiting, "A late UI response must not fail or reopen an automatically answered permission")
        try await runtime.setAccess(.fullAccess)
        await fulfillment(of: [idle], timeout: 5)
        let ids = try fixture.messages().compactMap { ($0["response"] as? [String: Any])?["request_id"] as? String }
        XCTAssertEqual(ids, ["a-search", "b-command"])
        XCTAssertEqual(try fixture.launches().count, 1, "Access changes must not restart an active turn")
    }

    func testCodexFullAccessIsExplicitAndSafePoliciesAreRestoredOnNextTurns() async throws {
        let fixture = try AgentRuntimeFixture(#"""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread"}}}'
        take
        emit '{"id":3,"result":{"turn":{"id":"one"}}}'
        emit '{"id":0,"method":"item/fileChange/requestApproval","params":{"reason":"write file","availableDecisions":["accept","decline"]}}'
        take
        emit '{"method":"turn/completed","params":{"turn":{"id":"one","status":"completed"}}}'
        take
        emit '{"id":4,"result":{"turn":{"id":"two"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"two","status":"completed"}}}'
        take
        emit '{"id":5,"result":{"turn":{"id":"three"}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"three","status":"completed"}}}'
        hold
        """#)
        defer { fixture.remove() }
        let recorder = AgentRuntimeRecorder()
        let runtime = fixture.runtime(.codex, recorder: recorder)
        defer { runtime.stop() }
        for mode in [AgentAccessMode.fullAccess, .standard, .ask] {
            let idle = expectation(description: "\(mode.title) turn")
            recorder.observe = { event in if case .status(.idle) = event { idle.fulfill() } }
            try await runtime.setAccess(mode)
            try await runtime.send(text: "continue", model: nil)
            await fulfillment(of: [idle], timeout: 5)
        }
        let messages = try fixture.messages()
        let turns = messages.filter { $0["method"] as? String == "turn/start" }.compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(turns.count, 3)
        guard turns.count == 3 else { return }
        for (index, policy) in ["never", "on-request", "untrusted"].enumerated() {
            XCTAssertEqual(turns[index]["approvalPolicy"] as? String, policy)
        }
        for (index, sandbox) in ["dangerFullAccess", "workspaceWrite", "readOnly"].enumerated() {
            XCTAssertEqual((turns[index]["sandboxPolicy"] as? [String: Any])?["type"] as? String, sandbox)
        }
        let response = try XCTUnwrap(messages.first { $0["id"] as? Int == 0 })
        XCTAssertEqual((response["result"] as? [String: Any])?["decision"] as? String, "accept")
        XCTAssertFalse(recorder.statuses.contains(.waiting))
    }
}
