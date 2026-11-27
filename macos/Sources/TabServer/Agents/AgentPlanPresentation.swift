import Foundation
import TabProtocol

/// These are presentation-only rows derived from observed provider inputs. Plan
/// bodies remain in the existing bounded detail payload, not unbounded metadata.
internal func agentClaudePlanItem(nativeID: String, name: String, input: Any?) -> AgentChatItem? {
    var value = input as? [String: Any]
    if value?["type"] as? String == "record" { value = value?["value"] as? [String: Any] }
    if name == "TodoWrite" {
        let todos = value?["todos"] as? [Any] ?? []
        let steps: [[String: String]] = todos.enumerated().compactMap { index, raw in
            guard let todo = raw as? [String: Any], let rawText = todo["content"] as? String else { return nil }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let status = todo["status"] as? String
            return ["id": "todo-\(index)", "text": text, "status": status == "completed" ? "completed" : status == "in_progress" ? "running" : "pending"]
        }
        return AgentChatItem(id: "todo_list:" + nativeID, kind: .tool, text: "Updated plan",
            detail: agentRuntimeJSON(["steps": steps]),
            workContext: .init(itemType: "todo_list", sourceStatus: "completed", planStatus: steps.allSatisfy { $0["status"] == "completed" } ? "completed" : "active"))
    }
    if name == "ExitPlanMode", let raw = value?["plan"] as? String {
        let markdown = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        return AgentChatItem(id: "proposed_plan:" + nativeID, kind: .tool, text: "Proposed plan", detail: markdown,
            workContext: .init(itemType: "proposed_plan", sourceStatus: "completed", planStatus: "active"))
    }
    return nil
}

internal func agentCodexTodoItem(_ params: [String: Any]) -> AgentChatItem? {
    guard let turnID = params["turnId"] as? String, let plan = params["plan"] as? [[String: Any]] else { return nil }
    var steps: [[String: String]] = []
    for (index, entry) in plan.enumerated() {
        guard let raw = entry["step"] as? String, let status = entry["status"] as? String,
              ["pending", "inProgress", "completed"].contains(status) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        steps.append(["id": "step-\(index + 1)", "text": text.isEmpty ? "Step \(index + 1)" : text,
                      "status": status == "inProgress" ? "running" : status])
    }
    var data: [String: Any] = ["steps": steps]
    if let raw = params["explanation"] as? String {
        let explanation = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explanation.isEmpty { data["explanation"] = explanation }
    }
    return AgentChatItem(id: "turn-plan:" + turnID, kind: .tool, text: "Updated plan", detail: agentRuntimeJSON(data), isComplete: false,
        workContext: .init(providerTurnID: turnID, itemType: "todo_list", sourceStatus: "running", planStatus: "active"))
}
