import Foundation
import TabProtocol

// Behavioral reference: the provider source 6fc9144a60c4a5f45089316ddd5f7371bafd3bf2,
// apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts (item notifications,
// requestApproval, ensureInitialized, startNativeTurn) and
// packages/effect-codex-app-server/test/fixtures/codex-app-server-mock-peer.ts
// (LF framing, numeric/string RPC IDs, independent stderr drain).
internal final class CodexAgentRuntime {
    private let onEvent: @Sendable (AgentRuntimeEvent) -> Void
    private var items: [String: AgentChatItem] = [:]
    private struct ReasoningPart {
        var turnID: String
        var nativeID: String
        var stream: String
        var index: Int
    }
    private var reasoningParts: [String: ReasoningPart] = [:]
    private var terminalReasoningStatuses: [String: String] = [:]
    private var terminalReasoningOrder: [String] = []

    init(onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.onEvent = onEvent }

    func receive(_ message: [String: Any]) { receive(message, source: nil) }

    func receive(_ message: [String: Any], source: AgentProviderJSON?) {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        switch method {
        case "item/plan/delta":
            guard let id = params["itemId"] as? String, let turnID = params["turnId"] as? String,
                  let delta = params["delta"] as? String, !delta.isEmpty else { return }
            var item = items[id] ?? AgentChatItem(id: id, kind: .tool, text: "Proposed plan", detail: "", isComplete: false,
                workContext: .init(providerTurnID: turnID, itemType: "proposed_plan", sourceStatus: "running", planStatus: "active"))
            item.detail = (item.detail ?? "") + delta
            items[id] = item; onEvent(.item(item))
        case "turn/plan/updated":
            if let item = agentCodexTodoItem(params) { items[item.id] = item; onEvent(.item(item)) }
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            let stream = method == "item/reasoning/summaryTextDelta" ? "summary" : "content"
            guard let turnID = params["turnId"] as? String, let nativeID = params["itemId"] as? String,
                  let index = params[stream == "summary" ? "summaryIndex" : "contentIndex"] as? Int, index >= 0,
                  let delta = params["delta"] as? String, !delta.isEmpty else { return }
            let id = reasoningID(turnID: turnID, nativeID: nativeID, stream: stream, index: index)
            var item = items[id] ?? AgentChatItem(id: id, kind: .tool, text: "Thinking", detail: "", isComplete: false,
                workContext: .init(providerTurnID: turnID, itemType: "reasoning", sourceStatus: "running"))
            item.detail = (item.detail ?? "") + delta
            items[id] = item
            onEvent(.item(item))
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
                items[id] = AgentChatItem(id: id, kind: .assistant, text: "", isComplete: false,
                                          workContext: .init(providerTurnID: params["turnId"] as? String))
                if let item = items[id] { onEvent(.item(item)) }
            }
            items[id]?.text += text
            onEvent(.textDelta(id: id, text: text))
        case "item/commandExecution/outputDelta":
            guard let id = params["itemId"] as? String, let text = params["delta"] as? String else { return }
            var item = items[id] ?? AgentChatItem(id: id, kind: .tool, text: "Command", isComplete: false)
            if item.workContext == nil { item.workContext = .init(providerTurnID: params["turnId"] as? String) }
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
            if type == "reasoning" {
                if complete, let turnID = params["turnId"] as? String { completeReasoning(native, turnID: turnID) }
                return
            }
            if type == "plan" {
                guard complete, let turnID = params["turnId"] as? String else { return }
                let final = (native["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? items[id]?.detail ?? ""
                guard !final.isEmpty else { return }
                let completed = terminalReasoningStatuses[turnID] != "interrupted"
                let item = AgentChatItem(id: id, kind: .tool, text: "Proposed plan", detail: final, isComplete: completed,
                    workContext: .init(providerTurnID: turnID, itemType: "proposed_plan", sourceStatus: completed ? "completed" : "running", planStatus: "active"))
                items[id] = item; onEvent(.item(item))
                return
            }
            if type == "contextCompaction" {
                let now = Date()
                let observedStart = (params["startedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                let updated = ((params[complete ? "completedAtMs" : "startedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }) ?? now
                let item = AgentChatItem(id: id, kind: .tool, text: complete ? "Context compacted" : "Compacting context", isComplete: complete,
                    createdAt: items[id]?.createdAt ?? observedStart ?? updated, updatedAt: updated,
                    workContext: .init(providerTurnID: params["turnId"] as? String, itemType: "compaction", sourceStatus: complete ? "completed" : "running"))
                items[id] = item; onEvent(.item(item))
                return
            }
            var item: AgentChatItem
            var toolImages: [AgentChatAttachment] = []
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
                                      detail: type == "webSearch" ? agentRuntimeJSON(native) : nil, isComplete: complete)
            case "collabAgentToolCall":
                item = AgentChatItem(id: id, kind: .tool, text: native["tool"] as? String ?? "Agent",
                                     detail: agentRuntimeJSON(native["agentsStates"]), isComplete: complete)
            default: return // Reasoning and internal context are not chat messages.
            }
            if item.kind == .tool {
                let isDynamic = type == "mcpToolCall" || type == "dynamicToolCall"
                let name = isDynamic ? agentCodexDynamicToolName(native) : native["tool"] as? String ?? type
                if isDynamic { item.text = name }
                var activity = agentToolActivity(name: name, input: nil, previous: items[id]?.tool)
                switch type {
                case "commandExecution": activity.presentation = .command
                case "fileChange": activity.presentation = .fileChange
                case "webSearch": activity.presentation = .webSearch
                case "collabAgentToolCall": activity.presentation = .subagent
                default: activity.presentation = .dynamicTool
                }
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
                    if let first = changes.first, let path = first["path"] as? String {
                        activity.fileChangeDetails = .init(fileName: path, diff: first["diff"] as? String,
                            operations: changes.compactMap { change in
                                guard let path = change["path"] as? String else { return nil }
                                let kind = change["kind"] as? [String: Any]
                                let operation = kind?["type"] as? String ?? change["kind"] as? String ?? "update"
                                let move = operation == "update" ? kind?["move_path"] as? String : nil
                                return .init(operation: operation, path: move ?? path, oldPath: move == nil ? nil : path)
                            })
                    }
                case "webSearch":
                    activity.input = agentRuntimeJSON(native["action"]) ?? native["query"] as? String
                    activity.searchPatterns = agentCodexWebSearchPatterns(native)
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
                case "mcpToolCall", "dynamicToolCall":
                    activity.input = agentRuntimeJSON(native["arguments"], originalJSON: source?.value(at: [.key("params"), .key("item"), .key("arguments")])) ?? activity.input
                    let media = AgentToolImages.project(agentCodexDynamicToolOutput(native))
                    toolImages = media.images
                    if let output = media.output {
                        let original = agentCodexDynamicToolOutputJSON(native, source: source, replacements: media.replacements)
                        activity.output = output as? String ?? original ?? agentRuntimeStructuredJSON(output)
                        activity.outputIsJSON = !(output is String)
                    } else { activity.output = nil; activity.outputIsJSON = nil }
                    if !toolImages.isEmpty { item.attachments = toolImages.map(\.descriptor) }
                    item.detail = activity.output
                default:
                    activity.input = agentRuntimeJSON(native["arguments"], originalJSON: source?.value(at: [.key("params"), .key("item"), .key("arguments")])) ?? activity.input
                    activity.output = agentToolOutput(native["result"]) ?? activity.output
                    if let result = native["result"] { activity.outputIsJSON = agentToolOutputIsJSON(result) }
                }
                let status = native["status"] as? String
                var context = AgentChatWorkContext(providerTurnID: params["turnId"] as? String)
                switch status {
                case "inProgress": context.sourceStatus = "running"
                case "completed", "failed": context.sourceStatus = status
                case "declined", "denied": context.sourceStatus = "cancelled"
                case "interrupted", "cancelled": context.sourceStatus = status
                default: break
                }
                item.workContext = context
                let error = native["error"]
                let hasError = error != nil && !(error is NSNull)
                if status == "declined" || status == "denied" { activity.status = .denied }
                else if status == "interrupted" || status == "cancelled" { activity.status = .interrupted }
                else if status == "failed" || hasError || native["isError"] as? Bool == true
                    || (native["result"] as? [String: Any])?["isError"] as? Bool == true
                    || native["success"] as? Bool == false || (activity.exitCode ?? 0) != 0 {
                    activity.status = .failed
                    if hasError && !isDynamic { activity.output = agentRuntimeJSON(error); activity.outputIsJSON = !(error is String) }
                } else { activity.status = complete ? .completed : .running }
                if complete {
                    activity.completedAt = (params["completedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                }
                item.tool = activity
            }
            if item.workContext == nil { item.workContext = .init(providerTurnID: params["turnId"] as? String) }
            items[id] = item
            onEvent(toolImages.isEmpty ? .item(item) : .toolItem(item, images: toolImages))
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            if let turnID = turn?["id"] as? String, let status = turn?["status"] as? String,
               ["completed", "failed", "interrupted", "cancelled"].contains(status) {
                terminalReasoningStatuses[turnID] = status == "completed" ? "completed" : "interrupted"
                terminalReasoningOrder.removeAll { $0 == turnID }; terminalReasoningOrder.append(turnID)
                if terminalReasoningOrder.count > 64 { terminalReasoningStatuses.removeValue(forKey: terminalReasoningOrder.removeFirst()) }
            }
            for (id, var item) in items where !item.isComplete {
                item.isComplete = true
                if item.workContext?.itemType == "proposed_plan" {
                    let completed = turn?["status"] as? String == "completed"
                    item.isComplete = completed
                    item.workContext?.sourceStatus = completed ? "completed" : "running"
                }
                if item.workContext?.itemType == "reasoning" || item.workContext?.itemType == "compaction" {
                    let status = turn?["status"] as? String == "interrupted" ? "interrupted" : turn?["status"] as? String == "failed" ? "failed" : "completed"
                    let isReasoning = item.workContext?.itemType == "reasoning"
                    item.workContext?.sourceStatus = isReasoning && status != "completed" ? "interrupted" : status
                    item.updatedAt = Date()
                    if item.workContext?.itemType == "compaction" {
                        item.text = status == "completed" ? "Context compacted" : status == "failed" ? "Context compaction failed" : "Context compaction stopped"
                    }
                }
                if item.tool != nil {
                    item.tool?.status = turn?["status"] as? String == "interrupted" ? .interrupted
                        : turn?["status"] as? String == "failed" ? .failed : .completed
                    item.tool?.completedAt = Date()
                    var context = item.workContext ?? AgentChatWorkContext()
                    context.sourceStatus = turn?["status"] as? String == "interrupted" ? "interrupted"
                        : turn?["status"] as? String == "failed" ? "failed" : "completed"
                    item.workContext = context
                }
                items[id] = item
                onEvent(.item(item))
            }
            items.removeAll()
            reasoningParts.removeAll()
        default: break
        }
    }

    private func reasoningID(turnID: String, nativeID: String, stream: String, index: Int) -> String {
        // This is the exact pinned Codex adapter part identity. Summary/content
        // streams and each indexed block must remain independent.
        let data = try! JSONSerialization.data(withJSONObject: [turnID, nativeID, stream, index], options: [.withoutEscapingSlashes])
        let id = String(decoding: data, as: UTF8.self)
        reasoningParts[id] = ReasoningPart(turnID: turnID, nativeID: nativeID, stream: stream, index: index)
        return id
    }

    private func completeReasoning(_ native: [String: Any], turnID: String) {
        guard let nativeID = native["id"] as? String else { return }
        for stream in ["summary", "content"] {
            for index in (native[stream] as? [String] ?? []).indices {
                _ = reasoningID(turnID: turnID, nativeID: nativeID, stream: stream, index: index)
            }
        }
        // Keep reserved insertion order for streamed parts; append any parts
        // that arrived only in the provider's completion snapshot afterwards.
        let matching = reasoningParts.filter { $0.value.turnID == turnID && $0.value.nativeID == nativeID }
            .sorted { lhs, rhs in
                let left = lhs.value, right = rhs.value
                if left.stream != right.stream { return left.stream == "summary" }
                return left.index < right.index
            }
        for (id, part) in matching {
            let final = (native[part.stream] as? [String]).flatMap { $0.indices.contains(part.index) ? $0[part.index] : nil }
            let text = final.flatMap { $0.isEmpty ? nil : $0 } ?? items[id]?.detail ?? ""
            reasoningParts.removeValue(forKey: id)
            guard !text.isEmpty else { continue }
            var item = items[id] ?? AgentChatItem(id: id, kind: .tool, text: "Thinking",
                workContext: .init(providerTurnID: turnID, itemType: "reasoning"))
            item.detail = text; item.isComplete = true; item.workContext?.sourceStatus = terminalReasoningStatuses[turnID] ?? "completed"
            items[id] = item; onEvent(.item(item))
        }
    }
}
