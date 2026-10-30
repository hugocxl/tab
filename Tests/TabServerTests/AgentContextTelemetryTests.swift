import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentContextTelemetryTests: XCTestCase {
    func testClaudeSystemInitReportsResolvedModelWithoutInventingUsage() throws {
        let recorder = ContextUsageRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(try json(#"{"type":"system","subtype":"init","model":"claude-sonnet-4-6"}"#))
        XCTAssertEqual(recorder.models, ["claude-sonnet-4-6"])
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testClaudeLatestRootInputIncludesBothCachesAndResultOnlyAddsCapacity() throws {
        let recorder = ContextUsageRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(try json(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"first","model":"claude-sonnet-4-6","usage":{"input_tokens":4,"cache_read_input_tokens":67023,"cache_creation_input_tokens":13058,"output_tokens":1}}},"parent_tool_use_id":null}"#))
        XCTAssertEqual(recorder.values.last, .init(usedTokens: 80_085))
        runtime.receive(try json(#"{"type":"stream_event","parent_tool_use_id":"subagent","event":{"type":"message_start","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":999999}}}}"#))
        XCTAssertEqual(recorder.values.count, 1)
        // A tool continuation is a fresh context measurement, not an increment.
        runtime.receive(try json(#"{"type":"assistant","message":{"id":"second","model":"claude-sonnet-4-6","content":[],"usage":{"input_tokens":3,"cache_read_input_tokens":40369,"cache_creation_input_tokens":444}}}"#))
        XCTAssertEqual(recorder.values.last, .init(usedTokens: 40_816))
        // Recorded T3 background-wake modelUsage is cumulative, unlike message usage.
        runtime.receive(try json(#"{"type":"result","modelUsage":{"claude-sonnet-4-6":{"inputTokens":17,"cacheReadInputTokens":163318,"cacheCreationInputTokens":26790,"contextWindow":200000},"claude-haiku-4-5":{"inputTokens":999999,"contextWindow":1000000}}}"#))
        XCTAssertEqual(recorder.values.last, .init(usedTokens: 40_816, contextWindow: 200_000))
        runtime.beginTurn()
        runtime.receive(try json(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"third","model":"claude-sonnet-4-6","usage":{"input_tokens":500}}}}"#))
        XCTAssertEqual(recorder.values.last, .init(usedTokens: 500, contextWindow: 200_000))
        runtime.receive(try json(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"fourth","model":"custom","usage":{"input_tokens":600}}}}"#))
        XCTAssertEqual(recorder.values.last, .init(usedTokens: 600), "Another model must not inherit a capacity")
    }

    func testClaudeResultWithoutMessageUsageNeverInventsCurrentUsage() throws {
        let recorder = ContextUsageRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(try json(#"{"type":"result","usage":{"input_tokens":1234},"modelUsage":{"claude-sonnet-4-6":{"inputTokens":5678,"contextWindow":200000}}}"#))
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testCodexUsesLastRequestNotLifetimeTotalsAndDoesNotDoubleCountCaches() throws {
        let recorder = ContextUsageRecorder()
        let runtime = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        // T3 proposed_plan notification shape, with intentionally different lifetime usage.
        runtime.receive(try json(#"{"method":"thread/tokenUsage/updated","params":{"threadId":"root","tokenUsage":{"total":{"totalTokens":900000,"inputTokens":800000},"last":{"totalTokens":21575,"inputTokens":21310,"cachedInputTokens":6912,"outputTokens":265},"modelContextWindow":258400}}}"#))
        XCTAssertEqual(recorder.values.last, .init(usedTokens: 21_575, contextWindow: 258_400))
        runtime.receive(try json(#"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"totalTokens":999999},"last":{"inputTokens":1234},"modelContextWindow":null}}}"#))
        XCTAssertEqual(recorder.values.last, .init(usedTokens: 1234))
        runtime.receive(try json(#"{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"totalTokens":999999},"modelContextWindow":200000}}}"#))
        XCTAssertEqual(recorder.values.count, 2, "Lifetime-only usage is not current context")
    }

    func testMalformedCountsAndOverflowAreIgnoredWithoutFailingTranscript() throws {
        let recorder = ContextUsageRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        for input in ["-1", "true", "1.5", "\"100\"", "null"] {
            runtime.receive(try json("{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":\(input)}}}"))
        }
        runtime.receive(["type": "assistant", "message": ["usage": ["input_tokens": Int.max, "cache_read_input_tokens": 1]]])
        XCTAssertTrue(recorder.values.isEmpty)
        runtime.receive(try json(#"{"type":"assistant","message":{"usage":{"input_tokens":0}}}"#))
        XCTAssertEqual(recorder.values, [.init(usedTokens: 0)])
    }

    private func json(_ source: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
    }
}

private final class ContextUsageRecorder: @unchecked Sendable {
    var values: [AgentContextUsage] = []
    var models: [String] = []
    func receive(_ event: AgentRuntimeEvent) {
        if case .contextUsage(let usage) = event { values.append(usage) }
        if case .resolvedModel(let model) = event { models.append(model) }
    }
}
