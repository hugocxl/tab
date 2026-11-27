import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentProviderJSONTests: XCTestCase {
    func testSelectiveReplacementPreservesBytesAndRemovesShadowedDuplicateValues() {
        let source = AgentProviderJSON(data: Data(#"{"output":{"z":1,"content":[{"type":"image","data":"secret"},{"last":2,"first":1}],"a":2}}"#.utf8))
        let replacements: [AgentProviderJSON.Replacement] = [.init(path: [.key("content"), .index(0)], json: #"{"type":"text","text":""}"#)]
        XCTAssertEqual(source.value(at: [.key("output")], replacing: replacements), #"{"z":1,"content":[{"type":"text","text":""},{"last":2,"first":1}],"a":2}"#)
        XCTAssertNil(source.value(at: [.key("output")], replacing: [.init(path: [.key("missing")], json: "null")]))
        let duplicate = AgentProviderJSON(data: Data(#"{"content":[{"data":"old blob"}],"content":[{"data":"new blob"}]}"#.utf8))
        XCTAssertEqual(duplicate.value(at: [], replacing: replacements), #"{"content":null,"content":[{"type":"text","text":""}]}"#)
    }

    func testBatchReplacementDoesNotRescanEveryArrayPrefix() {
        let count = 10_000
        let json = "[" + Array(repeating: #"{"data":"encoded"}"#, count: count).joined(separator: ",") + "]"
        let replacements = (0..<count).map { AgentProviderJSON.Replacement(path: [.index($0)], json: "null") }
        let start = Date()
        let output = AgentProviderJSON(data: Data(json.utf8)).value(at: [], replacing: replacements)
        XCTAssertEqual(output, "[" + Array(repeating: "null", count: count).joined(separator: ",") + "]")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testMixedImageResultKeepsProviderObjectOrderForBothProviders() throws {
        let recorder = AgentRuntimeRecorder()
        let codex = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        let claude = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        claude.receive(["type": "assistant", "message": ["id": "m", "content": [
            ["type": "tool_use", "id": "mixed", "name": "custom", "input": [:]],
        ]]])
        let content = #"{"z":1,"content":[{"type":"image","mimeType":"image/png","data":"c2VjcmV0"},{"last":2,"first":1}],"a":2}"#
        let expected = #"{"z":1,"content":[{"type":"text","text":""},{"last":2,"first":1}],"a":2}"#
        for provider in ["claude", "codex"] {
            let text = provider == "claude"
                ? "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"mixed\",\"content\":\(content)}]}}"
                : "{\"method\":\"item/completed\",\"params\":{\"item\":{\"id\":\"mixed\",\"type\":\"mcpToolCall\",\"tool\":\"custom\",\"result\":{\"structuredContent\":\(content)}}}}"
            let data = Data(text.utf8)
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if provider == "claude" { claude.receive(message, source: .init(data: data)) }
            else { codex.receive(message, source: .init(data: data)) }
            XCTAssertEqual(recorder.transcript["mixed"]?.tool?.output, expected, provider)
            XCTAssertEqual(recorder.transcript["mixed"]?.attachments?.count, 1)
        }
    }

    func testImagesBeyondDisplayLimitAreAlsoRemovedFromOriginalJSON() throws {
        let blocks = Array(repeating: #"{"type":"image","mimeType":"image/png","data":"c2VjcmV0"}"#, count: 10)
        let text = "[" + blocks.joined(separator: ",") + "]"
        let data = Data(text.utf8)
        let original = try JSONSerialization.jsonObject(with: data)
        let projected = AgentToolImages.project(original)
        XCTAssertEqual(projected.images.count, 8)
        XCTAssertEqual(projected.replacements.count, 10)
        let output = try XCTUnwrap(AgentProviderJSON(data: data).value(at: [], replacing: projected.replacements))
        XCTAssertFalse(output.contains("c2VjcmV0"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        XCTAssertEqual(decoded.count, 10)
        XCTAssertEqual(decoded.last?["type"] as? String, "image")
        XCTAssertNil(decoded.last?["data"])
    }

    func testClaudeStructuredResultObjectsAndScalarsKeepOriginalValues() throws {
        let recorder = AgentRuntimeRecorder()
        let claude = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        for value in [#"{"z":1,"a":{"last":2,"first":1}}"#, "42", "false"] {
            let data = Data((#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"result","content":"# + value + "}]}}").utf8)
            claude.receive(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]), source: AgentProviderJSON(data: data))
            XCTAssertEqual(recorder.transcript["result"]?.tool?.output, value)
            XCTAssertEqual(recorder.transcript["result"]?.tool?.outputIsJSON, true)
        }
    }

    func testStructuredResultOrderAndScalarsSurviveCodexProjection() throws {
        let recorder = AgentRuntimeRecorder()
        let codex = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        func receive(_ fields: String) throws -> String? {
            let data = Data((#"{"method":"item/completed","params":{"item":{"id":"result","type":"mcpToolCall","tool":"read","# + fields + "}}}").utf8)
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            codex.receive(message, source: AgentProviderJSON(data: data))
            return recorder.transcript["result"]?.tool?.output
        }
        let value = #"{"z":1,"a":{"last":2,"first":1}}"#
        XCTAssertEqual(try receive("\"result\":{\"structuredContent\":\(value),\"content\":[]}"), value)
        XCTAssertEqual(try receive("\"result\":{\"structuredContent\":\(value)},\"error\":{\"message\":\"Partial failure\"}"), "{\"error\":\"Partial failure\",\"result\":\(value)}")
        XCTAssertEqual(try receive(#""result":{"structuredContent":42}"#), "42")
        XCTAssertEqual(try receive(#""result":{"structuredContent":false}"#), "false")
        XCTAssertEqual(agentRuntimeStructuredJSON(42), "42")
        XCTAssertEqual(agentRuntimeStructuredJSON(false), "false")
        XCTAssertEqual(agentRuntimeStructuredJSON(NSNull()), "null")
    }

    func testImageProjectionDoesNotRestoreOriginalBlobWhilePreservingOtherRawResults() throws {
        let recorder = AgentRuntimeRecorder()
        let codex = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        let data = Data(#"{"method":"item/completed","params":{"item":{"id":"images","type":"dynamicToolCall","tool":"capture","contentItems":[{"type":"image","mimeType":"image/png","data":"c2VjcmV0"},{"type":"text","text":"Done"}]}}}"#.utf8)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        codex.receive(message, source: AgentProviderJSON(data: data))
        let output = try XCTUnwrap(recorder.transcript["images"]?.tool?.output)
        XCTAssertFalse(output.contains("c2VjcmV0"))
        XCTAssertEqual(recorder.transcript["images"]?.attachments?.count, 1)
        let plain = Data(#"{"method":"item/completed","params":{"item":{"id":"ordered","type":"dynamicToolCall","tool":"custom","contentItems":[{"type":"resource_link","uri":"file:///tmp/result","name":"Result"}]}}}"#.utf8)
        codex.receive(try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any]), source: AgentProviderJSON(data: plain))
        XCTAssertEqual(recorder.transcript["ordered"]?.tool?.output, #"[{"type":"resource_link","uri":"file:///tmp/result","name":"Result"}]"#)
    }

    func testSelectsEscapedKeysArraysAndLastDuplicateWithoutSortingNestedValues() throws {
        let json = #"{"ignored":"escaped \" } [ text","params":{"item":{"arguments":{"old":1}}},"params":{"item":{"arg\u0075ments":{"z":1,"a":{"second":2,"first":1},"list":[{"y":2,"x":1}]}}}}"#
        let source = AgentProviderJSON(data: Data(json.utf8))
        let path: [AgentProviderJSON.Component] = [.key("params"), .key("item"), .key("arguments")]
        XCTAssertEqual(source.value(at: path), #"{"z":1,"a":{"second":2,"first":1},"list":[{"y":2,"x":1}]}"#)
        XCTAssertEqual(source.value(at: path + [.key("list"), .index(0)]), #"{"y":2,"x":1}"#)
        XCTAssertNil(source.value(at: path + [.key("list"), .index(1)]))
        XCTAssertNil(source.value(at: [.key("absent")]))
        let slashes = AgentProviderJSON(data: Data(#"{"skip":"ends with slash\\","input":{"code":"say(\"hello\")","title":"é 😀"}}"#.utf8))
        XCTAssertEqual(slashes.value(at: [.key("input"), .key("title")]), #""é 😀""#)
    }

    func testLargeImageStringIsSkippedWithoutSecondDecode() {
        let prefix = #"{"params":{"item":{"contentItems":[{"type":"image","data":""#
        let suffix = #""}],"arguments":{"z":1,"a":2}}}}"#
        var bytes = Data(prefix.utf8)
        bytes.append(Data(repeating: 65, count: 18 * 1024 * 1024)); bytes.append(Data(suffix.utf8))
        let start = Date()
        XCTAssertEqual(AgentProviderJSON(data: bytes).value(at: [.key("params"), .key("item"), .key("arguments")]), #"{"z":1,"a":2}"#)
        XCTAssertEqual(AgentProviderJSON(data: bytes).value(at: [.key("params"), .key("item")], replacing: [
            .init(path: [.key("contentItems"), .index(0)], json: "null"),
        ]), #"{"contentItems":[null],"arguments":{"z":1,"a":2}}"#)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "Large unrelated payloads must be scanned, not decoded into another object graph")
    }

    func testClaudeStreamAndAssembledAndCodexArgumentsKeepWireOrder() throws {
        let recorder = AgentRuntimeRecorder()
        let claude = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        let codex = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        let arguments = #"{"timeout":30,"code":"1+1","title":"Run","nested":{"z":1,"a":2}}"#
        func feed(_ text: String, claudeProvider: Bool) throws {
            let data = Data(text.utf8)
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if claudeProvider { claude.receive(message, source: AgentProviderJSON(data: data)) }
            else { codex.receive(message, source: AgentProviderJSON(data: data)) }
        }
        try feed("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"id\":\"c\",\"type\":\"tool_use\",\"name\":\"js\",\"input\":\(arguments)}}}", claudeProvider: true)
        XCTAssertEqual(recorder.transcript["c"]?.tool?.input, arguments)
        try feed("{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"content\":[{\"type\":\"text\",\"text\":\"Before\"},{\"id\":\"c\",\"type\":\"tool_use\",\"name\":\"js\",\"input\":\(arguments)}]}}", claudeProvider: true)
        XCTAssertEqual(recorder.transcript["c"]?.tool?.input, arguments)
        for method in ["item/started", "item/completed"] {
            try feed("{\"method\":\"\(method)\",\"params\":{\"item\":{\"id\":\"d\",\"type\":\"dynamicToolCall\",\"tool\":\"js\",\"arguments\":\(arguments)}}}", claudeProvider: false)
            XCTAssertEqual(recorder.transcript["d"]?.tool?.input, arguments)
        }
        let item = try XCTUnwrap(recorder.transcript["d"])
        let restored = try JSONDecoder().decode(AgentChatItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.tool?.input, arguments)
    }

    func testRawProcessTransportPreservesArgumentOrder() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "turn complete")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{}}}'
        take
        emit '{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"ordered","name":"js","input":{"timeout":30,"code":"1+1","title":"Run"}}]}}'
        emit '{"type":"result","is_error":false}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.claude, recorder: recorder)
        defer { runtime.stop() }
        try await runtime.send(text: "fixture", model: nil)
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(recorder.transcript["ordered"]?.tool?.input, #"{"timeout":30,"code":"1+1","title":"Run"}"#)
    }

    func testCodexRawProcessTransportPreservesArgumentOrder() async throws {
        let recorder = AgentRuntimeRecorder()
        let idle = expectation(description: "Codex turn complete")
        recorder.observe = { if case .status(.idle) = $0 { idle.fulfill() } }
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"thread":{"id":"thread-1"}}}'
        take
        emit '{"id":3,"result":{"config":{}}}'
        take
        emit '{"id":4,"result":{"data":[{"id":"test-model","model":"test-model","isDefault":true,"defaultReasoningEffort":"medium"}]}}'
        take
        emit '{"id":5,"result":{"turn":{"id":"turn-1"}}}'
        emit '{"method":"item/completed","params":{"item":{"id":"ordered","type":"dynamicToolCall","tool":"js","arguments":{"timeout":30,"code":"1+1","title":"Run"}}}}'
        emit '{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}'
        hold
        """)
        defer { fixture.remove() }
        let runtime = fixture.runtime(.codex, recorder: recorder, resume: "prior-thread")
        defer { runtime.stop() }
        try await runtime.send(text: "fixture", model: "test-model")
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertEqual(recorder.transcript["ordered"]?.tool?.input, #"{"timeout":30,"code":"1+1","title":"Run"}"#)
    }
}
