import Foundation
import TabProtocol

// Behavioral reference: the provider source 6fc9144a60c4a5f45089316ddd5f7371bafd3bf2,
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
    private var reasoning: [String: AgentChatItem] = [:]
    private var reasoningStreamBlocks: [Int: String] = [:]
    private var nextReasoningBlock: [String: Int] = [:]
    private var snapshotReasoningBlock: [String: Int] = [:]
    private var reasoningSnapshots: Set<String> = []
    private struct ThinkingUpdate {
        var messageID: String
        var itemID: String
        var text: String
        var followsThinking: Bool
    }
    private var lastThinking: ThinkingUpdate?
    private var compaction: AgentChatItem?

    init(onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.onEvent = onEvent }

    func beginTurn() {
        messageID = nil; blocks.removeAll(); partialInputs.removeAll()
        reasoning.removeAll(); reasoningStreamBlocks.removeAll()
        nextReasoningBlock.removeAll(); snapshotReasoningBlock.removeAll(); reasoningSnapshots.removeAll()
        lastThinking = nil
        compaction = nil
    }

    func receive(_ message: [String: Any]) { receive(message, source: nil) }

    func receive(_ message: [String: Any], source: AgentProviderJSON?) {
        if let session = message["session_id"] as? String, session != sessionID {
            sessionID = session
            onEvent(.providerSession(session))
        }
        // Subagent messages belong to their tool, not the root assistant stream.
        if let parent = message["parent_tool_use_id"], !(parent is NSNull) { return }
        switch message["type"] as? String {
        case "system":
            receiveCompaction(message)
            if message["subtype"] as? String == "init", let commands = message["slash_commands"] as? [String] {
                onEvent(.commands(commands))
            }
            if message["subtype"] as? String == "init", let model = message["model"] as? String {
                onEvent(.resolvedModel(model))
            }
        case "stream_event":
            guard let event = message["event"] as? [String: Any] else { return }
            stream(event, source: source)
        case "assistant":
            if let assistant = message["message"] as? [String: Any] { recordContext(assistant) }
            guard let assistant = message["message"] as? [String: Any],
                  let id = assistant["id"] as? String,
                  let content = assistant["content"] as? [[String: Any]] else { return }
            receiveReasoningSnapshot(message, messageID: id, model: assistant["model"] as? String, content: content)
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
            for (index, block) in content.enumerated() where block["type"] as? String == "tool_use" {
                capturePlan(nativeID: block["id"] as? String, name: block["name"] as? String, input: block["input"])
                tool(block, originalInput: source?.value(at: [.key("message"), .key("content"), .index(index), .key("input")]))
            }
        case "user":
            guard let user = message["message"] as? [String: Any],
                  let content = user["content"] as? [[String: Any]] else { return }
            for (index, block) in content.enumerated() where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                var item = tools[id] ?? AgentChatItem(id: id, kind: .tool, text: "Tool")
                let content = block["content"]
                let output = (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    ?? content as? String ?? content.flatMap { value in
                        source?.value(at: [.key("message"), .key("content"), .index(index), .key("content")])
                            ?? agentRuntimeStructuredJSON(value)
                    }
                item.detail = output
                item.isComplete = true
                var activity = item.tool ?? AgentToolActivity(name: item.text)
                activity.output = output
                activity.outputIsJSON = agentToolOutputIsJSON(content)
                agentUpdateClaudeWebSearch(&activity, result: message["tool_use_result"])
                agentUpdateClaudeFileChange(&activity, result: message["tool_use_result"])
                let failed = block["is_error"] as? Bool == true
                let nonExecutionKind = (message["tool_result_meta"] as? [[String: Any]])?
                    .first(where: { $0["id"] as? String == id })?["non_execution_kind"] as? String
                var context = item.workContext ?? AgentChatWorkContext()
                context.sourceStatus = nonExecutionKind == "cancelled" ? "cancelled" : failed ? "failed" : "completed"
                context.toolNonExecutionKind = nonExecutionKind
                item.workContext = context
                let denied = (message["tool_result_meta"] as? [[String: Any]])?.contains {
                    $0["id"] as? String == id && $0["non_execution_kind"] as? String == "permission-rule"
                } == true
                activity.status = failed ? (denied || agentToolDenied(output)
                    || agentToolDenied(message["tool_use_result"] as? String) ? .denied : .failed) : .completed
                activity.completedAt = agentToolObservedDate(message["timestamp"]) ?? Date()
                let media = activity.presentation == .dynamicTool ? AgentToolImages.project(content) : .init(output: content, images: [])
                if !media.images.isEmpty {
                    activity.output = source?.value(at: [.key("message"), .key("content"), .index(index), .key("content")], replacing: media.replacements)
                        ?? agentRuntimeJSON(media.output)
                    activity.outputIsJSON = true
                    item.detail = activity.output
                    item.attachments = media.images.map(\.descriptor)
                }
                item.tool = activity
                tools[id] = item
                onEvent(media.images.isEmpty ? .item(item) : .toolItem(item, images: media.images))
            }
        case "result":
            for (id, var item) in reasoning where !item.isComplete {
                item.isComplete = true
                // Source flushTurn completes delivered reasoning independently
                // of a later provider failure; it is not a failed tool call.
                item.workContext?.sourceStatus = "completed"
                item.updatedAt = Date()
                reasoning[id] = item
                if !(item.detail ?? "").isEmpty { onEvent(.item(item)) }
            }
            if var item = compaction, !item.isComplete {
                item.isComplete = true
                // A result without compact_boundary/compact_result success does
                // not establish successful compaction (pinned finalizeActiveTurn).
                item.workContext?.sourceStatus = "failed"
                item.text = "Context compaction failed"
                if message["subtype"] as? String == "success", let reason = message["result"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    item.detail = reason
                }
                item.updatedAt = Date(); compaction = item; onEvent(.item(item))
            }
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
                var context = item.workContext ?? AgentChatWorkContext()
                context.sourceStatus = denied || message["is_error"] as? Bool == true ? "failed" : "completed"
                if denied { context.toolNonExecutionKind = "permission-rule" }
                item.workContext = context
                item.tool?.completedAt = Date()
                onEvent(.item(item))
            }
            texts.removeAll()
            tools.removeAll()
            streamedIDs.removeAll()
            reasoning.removeAll(); reasoningStreamBlocks.removeAll()
            nextReasoningBlock.removeAll(); snapshotReasoningBlock.removeAll(); reasoningSnapshots.removeAll()
            lastThinking = nil
            compaction = nil
        default: break
        }
    }

    func capturePlan(nativeID: String?, name: String?, input: Any?) {
        guard let nativeID, let name, let item = agentClaudePlanItem(nativeID: nativeID, name: name, input: input) else { return }
        onEvent(.item(item))
    }

    private func stream(_ event: [String: Any], source: AgentProviderJSON?) {
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            messageID = message?["id"] as? String
            if let message { recordContext(message) }
            blocks.removeAll()
            reasoningStreamBlocks.removeAll()
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any], let index = event["index"] as? Int else { return }
            if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                blocks[index] = id
                tool(block, originalInput: source?.value(at: [.key("event"), .key("content_block"), .key("input")]))
            } else if block["type"] as? String == "thinking", let messageID {
                let ordinal = nextReasoningBlock[messageID, default: 0]
                nextReasoningBlock[messageID] = ordinal + 1
                let id = "\(messageID):thinking:\(ordinal)"
                reasoningStreamBlocks[index] = id
                updateReasoning(id: id, text: block["thinking"] as? String ?? "", complete: false, append: true)
            } else if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                append(text)
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return }
            if delta["type"] as? String == "text_delta", let text = delta["text"] as? String { append(text) }
            if delta["type"] as? String == "thinking_delta", let index = event["index"] as? Int,
               let id = reasoningStreamBlocks[index], let text = delta["thinking"] as? String {
                updateReasoning(id: id, text: text, complete: false, append: true)
            }
            if delta["type"] as? String == "input_json_delta", let index = event["index"] as? Int,
               let id = blocks[index], let fragment = delta["partial_json"] as? String {
                partialInputs[id, default: ""] += fragment
            }
        case "content_block_stop":
            if let index = event["index"] as? Int, let id = reasoningStreamBlocks.removeValue(forKey: index) {
                updateReasoning(id: id, text: "", complete: true, append: true)
            }
            if let index = event["index"] as? Int, let id = blocks[index], var item = tools[id], let input = partialInputs[id] {
                item.detail = input
                item.tool = agentToolActivity(name: item.text, input: input, previous: item.tool)
                tools[id] = item
                onEvent(.item(item))
            }
        default: break
        }
    }

    private func updateReasoning(id: String, text: String, complete: Bool, append: Bool) {
        var item = reasoning[id] ?? AgentChatItem(id: id, kind: .tool, text: "Thinking", detail: "", isComplete: false,
            workContext: .init(itemType: "reasoning", sourceStatus: "running"))
        item.detail = append ? (item.detail ?? "") + text : text
        item.isComplete = complete; item.updatedAt = Date()
        item.workContext?.sourceStatus = complete ? "completed" : "running"
        reasoning[id] = item
        if !(item.detail ?? "").isEmpty { onEvent(.item(item)) }
    }

    private func receiveReasoningSnapshot(_ message: [String: Any], messageID: String, model: String?, content: [[String: Any]]) {
        if let uuid = message["uuid"] as? String, !reasoningSnapshots.insert(uuid).inserted { return }
        for block in content {
            guard block["type"] as? String == "thinking" else {
                let update = lastThinking
                lastThinking = nil
                // Pinned Claude 5.1+ behavior: only the second consecutive
                // thinking block immediately before a tool is a prose update.
                if block["type"] as? String == "tool_use", let update,
                   update.messageID == messageID, update.followsThinking,
                   model.map(agentClaudeWritesUpdatesAsThinking) == true {
                    reasoning.removeValue(forKey: update.itemID)
                    texts[update.itemID] = update.text
                    onEvent(.item(AgentChatItem(id: update.itemID, kind: .assistant, text: update.text,
                        workContext: .init(itemType: "assistant_message", sourceStatus: "completed"))))
                }
                continue
            }
            let ordinal = snapshotReasoningBlock[messageID, default: 0]
            snapshotReasoningBlock[messageID] = ordinal + 1
            let id = "\(messageID):thinking:\(ordinal)"
            let text = (block["thinking"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? reasoning[id]?.detail ?? ""
            updateReasoning(id: id, text: text, complete: true, append: false)
            let previous = lastThinking
            lastThinking = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
                : ThinkingUpdate(messageID: messageID, itemID: id, text: text, followsThinking: previous?.messageID == messageID)
        }
    }

    private func receiveCompaction(_ message: [String: Any]) {
        let subtype = message["subtype"] as? String
        if subtype == "status", var item = compaction, !item.isComplete,
           message["compact_result"] != nil || (message["status"] is NSNull && message["permissionMode"] == nil) {
            let result = message["compact_result"] as? String
            let status = result == "success" ? "completed" : result == "failed" ? "failed" : "interrupted"
            item.isComplete = true; item.updatedAt = Date(); item.workContext?.sourceStatus = status
            item.text = status == "completed" ? "Context compacted" : status == "failed" ? "Context compaction failed" : "Context compaction stopped"
            if status == "failed" { item.detail = message["compact_error"] as? String }
            compaction = status == "completed" ? item : nil
            onEvent(.item(item))
        }
        guard subtype == "compact_boundary" || (subtype == "status" && message["status"] as? String == "compacting") else { return }
        if subtype == "status", compaction?.isComplete == false { return }
        guard let id = (subtype == "compact_boundary" ? compaction?.id : nil) ?? message["uuid"] as? String else { return }
        let now = Date(), completed = subtype == "compact_boundary"
        var item = (completed ? compaction : nil) ?? AgentChatItem(id: id, kind: .tool, text: "Compacting context", isComplete: false,
            createdAt: now, workContext: .init(itemType: "compaction", sourceStatus: "running"))
        item.isComplete = completed; item.updatedAt = now
        item.text = completed ? "Context compacted" : "Compacting context"
        item.workContext?.sourceStatus = completed ? "completed" : "running"
        if completed, let metadata = message["compact_metadata"] as? [String: Any] {
            item.workContext?.beforeTokenCount = agentTokenCount(metadata["pre_tokens"]).flatMap { $0 <= 9_007_199_254_740_991 ? $0 : nil }
            item.workContext?.afterTokenCount = agentCompactionAfterTokens(metadata["post_tokens"])
        }
        compaction = completed ? nil : item; onEvent(.item(item))
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

    private func tool(_ block: [String: Any], originalInput: String?) {
        guard let id = block["id"] as? String else { return }
        var item = tools[id] ?? AgentChatItem(id: id, kind: .tool, text: block["name"] as? String ?? "Tool",
                                            isComplete: false)
        let input = agentRuntimeJSON(block["input"], originalJSON: originalInput)
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
    activity.presentation = agentClaudeToolPresentation(name)
    let normalizedCategory = AgentToolActivity.category(for: agentNormalizedClaudeToolName(name))
    if normalizedCategory != .other { activity.category = normalizedCategory }
    if activity.presentation == .fileChange, activity.fileChangeDetails == nil {
        activity.fileChangeDetails = .init(fileName: "\(name) result")
    }
    if let input { activity.input = input }
    guard let data = input?.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return activity }
    let paths = ["file_path", "notebook_path", "path", "filename", "fileName", "filePath"].compactMap { object[$0] as? String }
    if !paths.isEmpty { activity.filePaths = Array(Set(paths)).sorted() }
    if let url = object["url"] as? String { activity.urls = [url] }
    if activity.presentation == .webSearch { agentUpdateClaudeWebSearch(&activity, result: nil) }
    if activity.presentation == .fileChange {
        activity.fileChangeDetails = .init(fileName: paths.first ?? "\(name) result", diff: activity.fileChangeDetails?.diff)
    }
    if activity.presentation == .fileChange, let path = paths.first {
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

internal func agentToolOutputIsJSON(_ value: Any?) -> Bool {
    guard let value, !(value is String) else { return false }
    if let object = value as? [String: Any], let content = object["content"] { return agentToolOutputIsJSON(content) }
    if let content = value as? [[String: Any]], !content.compactMap({ $0["text"] as? String }).joined(separator: "\n").isEmpty { return false }
    return true
}

internal func agentToolObservedDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}

/// Pinned ClaudeAdapterV2 classification; unknown/MCP tools request command access.
internal func agentClaudeApprovalKind(_ tool: String) -> String {
    let normalized = agentNormalizedClaudeToolName(tool)
    switch normalized {
    case "edit", "multiedit", "notebookedit", "write": return "file-change"
    case "glob", "grep", "ls", "read": return "file-read"
    default: return "command"
    }
}

internal func agentClaudeWritesUpdatesAsThinking(_ model: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: #"claude-[a-z]+-(\d+)(?:-(\d{1,2}))?(?!\d)"#),
          let match = regex.firstMatch(in: model, range: NSRange(model.startIndex..., in: model)),
          let majorRange = Range(match.range(at: 1), in: model), let major = Int(model[majorRange]) else { return false }
    let minor = Range(match.range(at: 2), in: model).flatMap { Int(model[$0]) } ?? 0
    return major > 5 || (major == 5 && minor >= 1)
}
