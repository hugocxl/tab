import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentReasoningCompactionTests: XCTestCase {
    func testCodexIndexedSummaryAndContentReplaceDeltasWithoutBecomingAnswers() throws {
        let recorder = WorkRecorder()
        let codex = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        codex.receive(["method": "item/reasoning/summaryTextDelta", "params": ["turnId": "turn", "itemId": "reason", "summaryIndex": 0, "delta": "Draft"]])
        codex.receive(["method": "item/reasoning/textDelta", "params": ["turnId": "turn", "itemId": "reason", "contentIndex": 1, "delta": "Content draft"]])
        codex.receive(["method": "item/completed", "params": ["turnId": "turn", "item": ["id": "reason", "type": "reasoning", "summary": ["Final summary", "Second summary"], "content": ["First content", "Final content"]]]])
        let expected = ["[\"turn\",\"reason\",\"summary\",0]": "Final summary", "[\"turn\",\"reason\",\"summary\",1]": "Second summary",
                        "[\"turn\",\"reason\",\"content\",0]": "First content", "[\"turn\",\"reason\",\"content\",1]": "Final content"]
        XCTAssertEqual(recorder.items.count, 4)
        for (id, text) in expected {
            let item = try XCTUnwrap(recorder.items[id])
            XCTAssertEqual(item.kind, .tool); XCTAssertEqual(item.detail, text)
            XCTAssertEqual(item.workContext?.itemType, "reasoning")
            XCTAssertEqual(item.workContext?.providerTurnID, "turn")
            XCTAssertEqual(item.workContext?.sourceStatus, "completed")
            XCTAssertTrue(item.isComplete)
        }
        XCTAssertEqual(recorder.order.prefix(2), ["[\"turn\",\"reason\",\"summary\",0]", "[\"turn\",\"reason\",\"content\",1]"])
    }

    func testCodexFailedTurnStopsUnfinishedReasoningAndLateCompletionKeepsStoppedState() throws {
        let recorder = WorkRecorder()
        let runtime = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(["method": "item/reasoning/summaryTextDelta", "params": ["turnId": "failed-turn", "itemId": "reason", "summaryIndex": 0, "delta": "Partial"]])
        runtime.receive(["method": "turn/completed", "params": ["turn": ["id": "failed-turn", "status": "failed"]]])
        XCTAssertEqual(recorder.items.values.first?.workContext?.sourceStatus, "interrupted")
        runtime.receive(["method": "item/completed", "params": ["turnId": "failed-turn", "item": ["id": "reason", "type": "reasoning", "summary": ["Final after stop"]]]])
        XCTAssertEqual(recorder.items.values.first?.detail, "Final after stop")
        XCTAssertEqual(recorder.items.values.first?.workContext?.sourceStatus, "interrupted")
    }

    func testClaudeThinkingSnapshotReusesStreamedBlocksAndDeduplicatesSDKUUIDs() throws {
        let recorder = WorkRecorder()
        let claude = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        claude.beginTurn()
        claude.receive(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "message"]]])
        claude.receive(["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "Let"]]])
        claude.receive(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": " me think"]]])
        claude.receive(["type": "stream_event", "event": ["type": "content_block_stop", "index": 0]])
        let snapshot: [String: Any] = ["type": "assistant", "uuid": "snapshot-one", "message": ["id": "message", "content": [["type": "thinking", "thinking": "Let me think."]]]]
        claude.receive(snapshot); claude.receive(snapshot)
        claude.receive(["type": "assistant", "uuid": "snapshot-two", "message": ["id": "message", "content": [["type": "thinking", "thinking": "Second block"]]]])
        XCTAssertEqual(recorder.items.count, 2)
        XCTAssertEqual(recorder.items["message:thinking:0"]?.detail, "Let me think.")
        XCTAssertEqual(recorder.items["message:thinking:1"]?.detail, "Second block")
        XCTAssertTrue(recorder.items.values.allSatisfy { $0.kind == .tool && $0.isComplete && $0.workContext?.itemType == "reasoning" })
        claude.receive(["type": "result", "is_error": true])
        XCTAssertTrue(recorder.items.values.allSatisfy { $0.workContext?.sourceStatus == "completed" })
    }

    func testClaudeCompactionUsesObservedLifecycleAndActualCounts() throws {
        let recorder = WorkRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(["type": "system", "subtype": "status", "uuid": "compact-start", "status": "compacting"])
        runtime.receive(["type": "system", "subtype": "status", "uuid": "duplicate-start", "status": "compacting"])
        XCTAssertEqual(recorder.items.count, 1)
        XCTAssertFalse(try XCTUnwrap(recorder.items["compact-start"]).isComplete)
        runtime.receive(["type": "system", "subtype": "compact_boundary", "uuid": "compact-end", "compact_metadata": ["pre_tokens": 12000, "post_tokens": 5800.6]])
        let completed = try XCTUnwrap(recorder.items["compact-start"])
        XCTAssertTrue(completed.isComplete)
        XCTAssertEqual(completed.workContext?.sourceStatus, "completed")
        XCTAssertEqual(completed.workContext?.beforeTokenCount, 12000)
        XCTAssertEqual(completed.workContext?.afterTokenCount, 5801)
        runtime.receive(["type": "system", "subtype": "compact_boundary", "uuid": "next-boundary", "compact_metadata": ["post_tokens": true]])
        XCTAssertNotNil(recorder.items["next-boundary"], "A later boundary must not reuse a finished compaction identity")
        XCTAssertNil(recorder.items["next-boundary"]?.workContext?.beforeTokenCount)
        XCTAssertNil(recorder.items["next-boundary"]?.workContext?.afterTokenCount)
    }

    func testClaudeOnlySupportedModelsExposeSecondConsecutiveThinkingAsPreToolUpdate() throws {
        let cases: [(String, AgentChatItem.Kind)] = [("claude-sonnet-5-5", .assistant), ("claude-opus-5-0", .tool), ("unknown", .tool)]
        for (model, expected) in cases {
            let recorder = WorkRecorder()
            let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
            let blocks: [(String, [String: Any])] = [("one", ["type": "thinking", "thinking": "Private reasoning"]),
                ("two", ["type": "thinking", "thinking": "I will inspect the file."]),
                ("three", ["type": "tool_use", "id": "read", "name": "Read", "input": [:]])]
            for (uuid, block) in blocks {
                runtime.receive(["type": "assistant", "uuid": uuid, "message": ["id": "message", "model": model, "content": [block]]])
            }
            XCTAssertEqual(recorder.items["message:thinking:0"]?.kind, .tool)
            XCTAssertEqual(recorder.items["message:thinking:1"]?.kind, expected, model)
            runtime.receive(["type": "result", "is_error": false])
            XCTAssertEqual(recorder.items["message:thinking:1"]?.kind, expected, "Terminalization must not revert the source classification")
        }
    }

    func testUnconfirmedClaudeCompactionFailsAndCodexCompactionRetainsProviderTimes() throws {
        let recorder = WorkRecorder()
        let claude = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        claude.receive(["type": "system", "subtype": "status", "uuid": "unfinished", "status": "compacting"])
        claude.receive(["type": "result", "subtype": "success", "result": "Compaction could not finish.", "is_error": false])
        XCTAssertEqual(recorder.items["unfinished"]?.workContext?.sourceStatus, "failed")
        XCTAssertEqual(recorder.items["unfinished"]?.detail, "Compaction could not finish.")
        let codex = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        codex.receive(["method": "item/started", "params": ["turnId": "turn", "startedAtMs": 100000.0, "item": ["id": "compact", "type": "contextCompaction"]]])
        codex.receive(["method": "item/completed", "params": ["turnId": "turn", "completedAtMs": 102000.0, "item": ["id": "compact", "type": "contextCompaction"]]])
        let item = try XCTUnwrap(recorder.items["compact"])
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(item.updatedAt, Date(timeIntervalSince1970: 102))
        XCTAssertEqual(item.workContext?.providerTurnID, "turn")
        XCTAssertEqual(item.workContext?.itemType, "compaction")
        XCTAssertNil(item.workContext?.beforeTokenCount)
        XCTAssertTrue(item.isComplete)
    }
}

private final class WorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AgentChatItem] = []
    func receive(_ event: AgentRuntimeEvent) {
        guard case .item(let item) = event else { return }
        lock.lock(); recorded.append(item); lock.unlock()
    }
    var items: [String: AgentChatItem] {
        lock.lock(); defer { lock.unlock() }
        return Dictionary(recorded.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }
    var order: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded.reduce(into: []) { ids, item in if !ids.contains(item.id) { ids.append(item.id) } }
    }
}
