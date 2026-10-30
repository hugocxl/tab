import Foundation
import TabProtocol

// Behavioral reference: T3 Code 6fc9144a60c4a5f45089316ddd5f7371bafd3bf2,
// apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts (partial messages,
// permissionResultFromDecision, interruptTurn) and ClaudeAdapterV2.test.ts:2366–2402
// (raw CLI control envelopes). SDK recordings are not raw stdio wire fixtures.
internal final class ClaudeAgentRuntime {
    private let onEvent: @Sendable (AgentRuntimeEvent) -> Void
    private(set) var sessionID: String?
    private var messageID: String?
    private var texts: [String: String] = [:]
    private var streamedIDs: Set<String> = []
    private var tools: [String: AgentChatItem] = [:]
    private var blocks: [Int: String] = [:]
    private var partialInputs: [String: String] = [:]
    private var contextUsage: AgentContextUsage?
    private var contextModel: String?
    private var contextWindows: [String: Int] = [:]

    init(onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.onEvent = onEvent }

    func beginTurn() { messageID = nil; blocks.removeAll(); partialInputs.removeAll() }

    func receive(_ message: [String: Any]) {
        if let session = message["session_id"] as? String, session != sessionID {
            sessionID = session
            onEvent(.providerSession(session))
        }
        // Subagent messages belong to their tool, not the root assistant stream.
        if let parent = message["parent_tool_use_id"], !(parent is NSNull) { return }
        switch message["type"] as? String {
        case "system":
            if message["subtype"] as? String == "init", let model = message["model"] as? String {
                onEvent(.resolvedModel(model))
            }
        case "stream_event":
            guard let event = message["event"] as? [String: Any] else { return }
            stream(event)
        case "assistant":
            if let assistant = message["message"] as? [String: Any] { recordContext(assistant) }
            guard let assistant = message["message"] as? [String: Any],
                  let id = assistant["id"] as? String,
                  let content = assistant["content"] as? [[String: Any]] else { return }
            let text = content.compactMap { block -> String? in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }.joined()
            if !text.isEmpty {
                // The SDK can emit one assistant frame per content block with the
                // SAME message ID. A tool-only frame must not erase prior prose,
                // and a later text block must not replace the streamed aggregate.
                if !streamedIDs.contains(id) { texts[id, default: ""] += text }
                // Replacement, never an additional delta: SDK emits the assembled message too.
                onEvent(.item(AgentChatItem(id: id, kind: .assistant, text: texts[id] ?? text)))
            }
            for block in content where block["type"] as? String == "tool_use" { tool(block) }
        case "user":
            guard let user = message["message"] as? [String: Any],
                  let content = user["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                var item = tools[id] ?? AgentChatItem(id: id, kind: .tool, text: "Tool")
                let content = block["content"]
                let output = (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    ?? content as? String ?? agentRuntimeJSON(content)
                item.detail = output
                item.isComplete = true
                var activity = item.tool ?? AgentToolActivity(name: item.text)
                activity.output = output
                let failed = block["is_error"] as? Bool == true
                let denied = (message["tool_result_meta"] as? [[String: Any]])?.contains {
                    $0["id"] as? String == id && $0["non_execution_kind"] as? String == "permission-rule"
                } == true
                activity.status = failed ? (denied || agentToolDenied(output)
                    || agentToolDenied(message["tool_use_result"] as? String) ? .denied : .failed) : .completed
                activity.completedAt = agentToolObservedDate(message["timestamp"]) ?? Date()
                item.tool = activity
                tools[id] = item
                onEvent(.item(item))
            }
        case "result":
            // modelUsage aggregates billed input across requests (and possibly subagents).
            // Only its capacity is usable as context telemetry.
            if let models = message["modelUsage"] as? [String: [String: Any]] {
                for (model, usage) in models {
                    if let window = agentContextWindow(usage["contextWindow"]) { contextWindows[model] = window }
                }
                if let model = contextModel, var usage = contextUsage,
                   let window = contextWindows[model], usage.contextWindow != window {
                    usage.contextWindow = window
                    contextUsage = usage
                    onEvent(.contextUsage(usage))
                }
            }
            // The result string repeats the final assistant answer. Never append it again.
            for (id, text) in texts { onEvent(.item(AgentChatItem(id: id, kind: .assistant, text: text))) }
            for (_, var item) in tools where !item.isComplete {
                item.isComplete = true
                let denied = (message["permission_denials"] as? [[String: Any]])?.contains {
                    $0["tool_use_id"] as? String == item.id
                } == true
                item.tool?.status = denied ? .denied : message["is_error"] as? Bool == true ? .failed : .completed
                item.tool?.completedAt = Date()
                onEvent(.item(item))
            }
            texts.removeAll()
            tools.removeAll()
            streamedIDs.removeAll()
        default: break
        }
    }

    private func stream(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            messageID = message?["id"] as? String
            if let message { recordContext(message) }
            blocks.removeAll()
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any], let index = event["index"] as? Int else { return }
            if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                blocks[index] = id
                tool(block)
            } else if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                append(text)
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return }
            if delta["type"] as? String == "text_delta", let text = delta["text"] as? String { append(text) }
            if delta["type"] as? String == "input_json_delta", let index = event["index"] as? Int,
               let id = blocks[index], let fragment = delta["partial_json"] as? String {
                partialInputs[id, default: ""] += fragment
            }
        case "content_block_stop":
            if let index = event["index"] as? Int, let id = blocks[index], var item = tools[id], let input = partialInputs[id] {
                item.detail = input
                item.tool = agentToolActivity(name: item.text, input: input, previous: item.tool)
                tools[id] = item
                onEvent(.item(item))
            }
        default: break
        }
    }

    private func recordContext(_ message: [String: Any]) {
        guard let usage = message["usage"] as? [String: Any],
              let input = agentTokenCount(usage["input_tokens"]) else { return }
        var tokens = input
        for key in ["cache_read_input_tokens", "cache_creation_input_tokens"] {
            let count: Int
            if let value = usage[key] {
                guard let parsed = agentTokenCount(value) else { return }
                count = parsed
            } else { count = 0 }
            let sum = tokens.addingReportingOverflow(count)
            guard !sum.overflow else { return }
            tokens = sum.partialValue
        }
        let model = message["model"] as? String
        let current = AgentContextUsage(usedTokens: tokens, contextWindow: model.flatMap { contextWindows[$0] })
        contextModel = model
        guard current != contextUsage else { return }
        contextUsage = current
        onEvent(.contextUsage(current))
    }

    private func append(_ text: String) {
        guard let id = messageID, !text.isEmpty else { return }
        if texts[id] == nil {
            texts[id] = ""
            onEvent(.item(AgentChatItem(id: id, kind: .assistant, text: "", isComplete: false)))
        }
        texts[id, default: ""] += text
        streamedIDs.insert(id)
        onEvent(.textDelta(id: id, text: text))
    }

    private func tool(_ block: [String: Any]) {
        guard let id = block["id"] as? String else { return }
        var item = tools[id] ?? AgentChatItem(id: id, kind: .tool, text: block["name"] as? String ?? "Tool",
                                            isComplete: false)
        let input = agentRuntimeJSON(block["input"])
        item.detail = item.tool?.output ?? input
        item.tool = agentToolActivity(name: item.text, input: input, previous: item.tool)
        tools[id] = item
        onEvent(.item(item))
    }
}

/// Shared provider presentation extraction; raw input is always retained alongside its output.
internal func agentToolActivity(name: String, input: String?, previous: AgentToolActivity? = nil) -> AgentToolActivity {
    var activity = previous ?? AgentToolActivity(name: name, category: AgentToolActivity.category(for: name),
                                                status: .running, startedAt: Date())
    activity.name = name
    activity.category = AgentToolActivity.category(for: name)
    if let input { activity.input = input }
    guard let data = input?.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return activity }
    let paths = ["file_path", "path", "filePath"].compactMap { object[$0] as? String }
    if !paths.isEmpty { activity.filePaths = Array(Set(paths)).sorted() }
    if let url = object["url"] as? String { activity.urls = [url] }
    if activity.category == .edit, let path = paths.first {
        if let old = object["old_string"] as? String, let new = object["new_string"] as? String {
            let diff = old.components(separatedBy: "\n").map { "-" + $0 }.joined(separator: "\n")
                + "\n" + new.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
            activity.fileChanges = [.init(path: path, diff: diff, kind: "update")]
        } else if let content = object["content"] as? String {
            activity.fileChanges = [.init(path: path, diff: content.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n"), kind: "write")]
        }
    }
    return activity
}

internal func agentToolDenied(_ output: String?) -> Bool {
    let output = (output ?? "").lowercased()
    return output.contains("permission denied") || output.contains("user denied") || output.contains("user rejected")
        || output.contains("user declined tool execution")
        || output.contains("tool use was rejected")
}

internal func agentToolOutput(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let object = value as? [String: Any], let content = object["content"] {
        return agentToolOutput(content)
    }
    if let content = value as? [[String: Any]] {
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if !text.isEmpty { return text }
    }
    return agentRuntimeJSON(value)
}

internal func agentToolObservedDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}
