import Foundation
import TabProtocol

// Behavioral reference: T3 Code 6fc9144a60c4a5f45089316ddd5f7371bafd3bf2,
// apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts (item notifications,
// requestApproval, ensureInitialized, startNativeTurn) and
// packages/effect-codex-app-server/test/fixtures/codex-app-server-mock-peer.ts
// (LF framing, numeric/string RPC IDs, independent stderr drain).
internal final class CodexAgentRuntime {
    private let onEvent: @Sendable (AgentRuntimeEvent) -> Void
    private var items: [String: AgentChatItem] = [:]

    init(onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.onEvent = onEvent }

    func receive(_ message: [String: Any]) {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        switch method {
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? [String: Any],
                  let last = usage["last"] as? [String: Any],
                  let tokens = agentTokenCount(last["totalTokens"]) ?? agentTokenCount(last["inputTokens"]) else { return }
            // `total` is lifetime billed usage; `last` is the latest model request.
            // Cached input is already included, and must never be added again.
            onEvent(.contextUsage(AgentContextUsage(usedTokens: tokens,
                contextWindow: agentContextWindow(usage["modelContextWindow"]))))
        case "item/agentMessage/delta":
            guard let id = params["itemId"] as? String, let text = params["delta"] as? String else { return }
            if items[id] == nil {
                items[id] = AgentChatItem(id: id, kind: .assistant, text: "", isComplete: false)
                if let item = items[id] { onEvent(.item(item)) }
            }
            items[id]?.text += text
            onEvent(.textDelta(id: id, text: text))
        case "item/commandExecution/outputDelta":
            guard let id = params["itemId"] as? String, let text = params["delta"] as? String else { return }
            var item = items[id] ?? AgentChatItem(id: id, kind: .tool, text: "Command", isComplete: false)
            item.detail = (item.detail ?? "") + text
            var activity = item.tool ?? agentToolActivity(name: "commandExecution", input: nil)
            activity.output = (activity.output ?? "") + text
            item.tool = activity
            items[id] = item
            onEvent(.item(item))
        case "item/started", "item/completed":
            guard let native = params["item"] as? [String: Any], let id = native["id"] as? String,
                  let type = native["type"] as? String else { return }
            let complete = method == "item/completed"
            var item: AgentChatItem
            switch type {
            case "agentMessage":
                // A completion replaces accumulated deltas, not an append of the full text.
                item = AgentChatItem(id: id, kind: .assistant,
                                     text: native["text"] as? String ?? items[id]?.text ?? "", isComplete: complete)
            case "commandExecution":
                let output = native["aggregatedOutput"] as? String ?? items[id]?.detail
                let exit = (native["exitCode"] as? Int).map { "\nExit code: \($0)" } ?? ""
                item = AgentChatItem(id: id, kind: .tool, text: native["command"] as? String ?? "Command",
                                     detail: (output ?? "") + exit, isComplete: complete)
            case "fileChange":
                item = AgentChatItem(id: id, kind: .tool, text: "File changes",
                                     detail: agentRuntimeJSON(native["changes"]), isComplete: complete)
            case "mcpToolCall", "dynamicToolCall", "webSearch":
                item = AgentChatItem(id: id, kind: .tool, text: native["tool"] as? String ?? type,
                                      detail: agentRuntimeJSON(native), isComplete: complete)
            case "collabAgentToolCall":
                item = AgentChatItem(id: id, kind: .tool, text: native["tool"] as? String ?? "Agent",
                                     detail: agentRuntimeJSON(native["agentsStates"]), isComplete: complete)
            default: return // Reasoning and internal context are not chat messages.
            }
            if item.kind == .tool {
                let name = native["tool"] as? String ?? type
                var activity = agentToolActivity(name: name, input: nil, previous: items[id]?.tool)
                if complete && items[id] == nil { activity.startedAt = nil }
                activity.category = type == "commandExecution" ? .command
                    : type == "fileChange" ? .edit : type == "webSearch" ? .web
                    : type == "collabAgentToolCall" ? .subagent : AgentToolActivity.category(for: name)
                if let milliseconds = params["startedAtMs"] as? Double {
                    activity.startedAt = Date(timeIntervalSince1970: milliseconds / 1000)
                }
                switch type {
                case "commandExecution":
                    if let command = native["command"] as? String { activity.input = command }
                    activity.output = native["aggregatedOutput"] as? String ?? activity.output
                    activity.exitCode = native["exitCode"] as? Int
                    let actions = native["commandActions"] as? [[String: Any]] ?? []
                    let actionTypes = Set(actions.compactMap { $0["type"] as? String })
                    if actionTypes == ["read"] { activity.category = .read }
                    else if actionTypes == ["search"] || actionTypes == ["listFiles"] { activity.category = .search }
                    let paths = actions.compactMap { $0["path"] as? String }
                    if !paths.isEmpty { activity.filePaths = paths }
                case "fileChange":
                    let changes = native["changes"] as? [[String: Any]] ?? []
                    activity.fileChanges = changes.compactMap { change in
                        guard let path = change["path"] as? String else { return nil }
                        let kind = (change["kind"] as? [String: Any])?["type"] as? String ?? change["kind"] as? String
                        return .init(path: path, diff: change["diff"] as? String, kind: kind)
                    }
                    activity.filePaths = activity.fileChanges?.map(\.path)
                    activity.input = agentRuntimeJSON(native["changes"])
                case "webSearch":
                    activity.input = agentRuntimeJSON(native["action"]) ?? native["query"] as? String
                    if let action = native["action"] as? [String: Any], let url = action["url"] as? String {
                        activity.urls = [url]
                    }
                case "collabAgentToolCall":
                    activity.input = native["prompt"] as? String
                    if let states = native["agentsStates"] as? [String: [String: Any]] {
                        activity.output = states.keys.sorted().map { id in
                            let state = states[id] ?? [:]
                            let status = state["status"] as? String
                            let message = state["message"] as? String
                            return id + (status.map { " · " + $0 } ?? "") + (message.map { "\n" + $0 } ?? "")
                        }.joined(separator: "\n\n")
                    } else { activity.output = agentToolOutput(native["agentsStates"]) }
                default:
                    activity.input = agentRuntimeJSON(native["arguments"]) ?? activity.input
                    activity.output = agentToolOutput(native["result"]) ?? activity.output
                }
                let status = native["status"] as? String
                let error = native["error"]
                let hasError = error != nil && !(error is NSNull)
                if status == "declined" || status == "denied" { activity.status = .denied }
                else if status == "interrupted" || status == "cancelled" { activity.status = .interrupted }
                else if status == "failed" || hasError || native["isError"] as? Bool == true
                    || (native["result"] as? [String: Any])?["isError"] as? Bool == true
                    || native["success"] as? Bool == false || (activity.exitCode ?? 0) != 0 {
                    activity.status = .failed
                    if hasError { activity.output = agentRuntimeJSON(error) }
                } else { activity.status = complete ? .completed : .running }
                if complete {
                    activity.completedAt = (params["completedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                }
                item.tool = activity
            }
            items[id] = item
            onEvent(.item(item))
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            for (id, var item) in items where !item.isComplete {
                item.isComplete = true
                if item.tool != nil {
                    item.tool?.status = turn?["status"] as? String == "interrupted" ? .interrupted
                        : turn?["status"] as? String == "failed" ? .failed : .completed
                    item.tool?.completedAt = Date()
                }
                items[id] = item
                onEvent(.item(item))
            }
            items.removeAll()
        default: break
        }
    }
}
