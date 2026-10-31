import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentPlanPresentationTests: XCTestCase {
    func testCodexStreamedProposalReplacesFinalTextAndRemainsAnActiveProposal() throws {
        let recorder = PlanRecorder()
        let runtime = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(["method": "item/plan/delta", "params": ["turnId": "turn", "itemId": "proposal", "delta": "Draft "]])
        runtime.receive(["method": "item/plan/delta", "params": ["turnId": "turn", "itemId": "proposal", "delta": "plan"]])
        XCTAssertEqual(recorder.items["proposal"]?.detail, "Draft plan")
        XCTAssertFalse(try XCTUnwrap(recorder.items["proposal"]).isComplete)
        runtime.receive(["method": "item/completed", "params": ["turnId": "turn", "item": ["id": "proposal", "type": "plan", "text": "## Final plan\n\nInspect and verify."]]])
        let proposal = try XCTUnwrap(recorder.items["proposal"])
        XCTAssertEqual(proposal.detail, "## Final plan\n\nInspect and verify.")
        XCTAssertEqual(proposal.workContext?.itemType, "proposed_plan")
        XCTAssertEqual(proposal.workContext?.planStatus, "active", "Finishing the proposal does not mean it was implemented")
        XCTAssertTrue(proposal.isComplete)
        XCTAssertEqual(recorder.items.count, 1)
    }

    func testCodexTodoUpdatesKeepSourceStepIDsStatusesAndExplanation() throws {
        let recorder = PlanRecorder()
        let runtime = CodexAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.receive(["method": "turn/plan/updated", "params": ["turnId": "turn", "explanation": "  Next steps  ", "plan": [["step": " ", "status": "pending"], ["step": "  Verify  ", "status": "inProgress"]]]])
        let item = try XCTUnwrap(recorder.items["turn-plan:turn"])
        let detail = try json(item)
        let steps = try XCTUnwrap(detail["steps"] as? [[String: String]])
        XCTAssertEqual(steps, [["id": "step-1", "text": "Step 1", "status": "pending"], ["id": "step-2", "text": "Verify", "status": "running"]])
        XCTAssertEqual(detail["explanation"] as? String, "Next steps")
        XCTAssertEqual(item.workContext?.sourceStatus, "running")
        runtime.receive(["method": "turn/plan/updated", "params": ["turnId": "turn", "plan": [["step": "Done", "status": "completed"]]]])
        let updated = try XCTUnwrap(recorder.items[item.id])
        XCTAssertEqual(updated.workContext?.planStatus, "active", "Pinned Codex plan artifact stays active until separately consumed")
        let before = updated.detail
        runtime.receive(["method": "turn/plan/updated", "params": ["turnId": "turn", "plan": [["step": "Invalid", "status": "invented"]]]])
        XCTAssertEqual(recorder.items[item.id]?.detail, before)
    }

    func testClaudeTodoWritePreservesOriginalIndicesAndKnownStatusMapping() throws {
        let recorder = PlanRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        let input: [String: Any] = ["todos": [["content": " First ", "status": "completed"], ["content": "  ", "status": "pending"], ["content": "Next", "status": "in_progress"], ["content": "Later", "status": "future"]]]
        runtime.receive(["type": "assistant", "message": ["id": "message", "content": [["type": "tool_use", "id": "todo", "name": "TodoWrite", "input": input]]]])
        let plan = try XCTUnwrap(recorder.items["todo_list:todo"])
        let steps = try XCTUnwrap(try json(plan)["steps"] as? [[String: String]])
        XCTAssertEqual(steps.map { $0["id"]! }, ["todo-0", "todo-2", "todo-3"])
        XCTAssertEqual(steps.map { $0["status"]! }, ["completed", "running", "pending"])
        XCTAssertEqual(plan.workContext?.planStatus, "active")
        XCTAssertEqual(plan.workContext?.sourceStatus, "completed")
        XCTAssertNotNil(recorder.items["todo"]?.tool, "The source retains the ordinary tool call alongside the plan projection")
        XCTAssertNil(agentClaudePlanItem(nativeID: "alias", name: "todo_write", input: input))
        let empty = try XCTUnwrap(agentClaudePlanItem(nativeID: "clear", name: "TodoWrite", input: ["todos": []]))
        XCTAssertEqual(empty.workContext?.planStatus, "completed")
    }

    func testClaudeExitPlanModeCapturesOnlyActuallySuppliedMarkdownWithoutChangingApprovals() throws {
        let recorder = PlanRecorder()
        let runtime = ClaudeAgentRuntime(onEvent: { recorder.receive($0) })
        runtime.capturePlan(nativeID: "exit", name: "ExitPlanMode", input: ["plan": "  # Proposal\n\nInspect the code.  "])
        let item = try XCTUnwrap(recorder.items["proposed_plan:exit"])
        XCTAssertEqual(item.detail, "# Proposal\n\nInspect the code.")
        XCTAssertEqual(item.workContext?.planStatus, "active")
        XCTAssertEqual(item.workContext?.itemType, "proposed_plan")
        XCTAssertNil(agentClaudePlanItem(nativeID: "missing", name: "ExitPlanMode", input: ["planFilePath": "/not-read.md"]))
        XCTAssertNil(agentClaudePlanItem(nativeID: "empty", name: "ExitPlanMode", input: ["plan": " \n "]))
    }

    private func json(_ item: AgentChatItem) throws -> [String: Any] {
        let detail = try XCTUnwrap(item.detail).data(using: .utf8)!
        return try XCTUnwrap(JSONSerialization.jsonObject(with: detail) as? [String: Any])
    }
}
private final class PlanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: AgentChatItem] = [:]
    func receive(_ event: AgentRuntimeEvent) {
        guard case .item(let item) = event else { return }
        lock.lock(); value[item.id] = item; lock.unlock()
    }
    var items: [String: AgentChatItem] { lock.lock(); defer { lock.unlock() }; return value }
}
