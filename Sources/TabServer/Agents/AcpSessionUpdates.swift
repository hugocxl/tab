import Foundation
import TabProtocol

// Agent Client Protocol `session/update` notifications as transcript items. Shapes are from
// the protocol's schema as Gemini CLI 0.70.0 and OpenCode 2.3.2 send them, and from the
// provider source's packages/provider-acp runtimeModel.ts, which reads the same variants.
internal final class AcpSessionUpdates {
    private let onEvent: @Sendable (AgentRuntimeEvent) -> Void
    private var items: [String: AgentChatItem] = [:]
    /// The order items began in, so a turn's end completes them in order.
    private var order: [String] = []
    /// The message or thought chunks without an ID of their own join, until something else starts.
    private var openMessage: String?
    private var openThought: String?
    private var counter = 0
    /// Every item ID this turn begins with, unique per runtime.
    private(set) var turnID = "acp-turn-0"
    private var turnNumber = 0
    /// The model the agent says it runs, from its options.
    var currentModel: String?

    init(onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.onEvent = onEvent }

    func beginTurn() {
        turnNumber += 1
        turnID = "acp-turn-\(UUID().uuidString.prefix(8).lowercased())-\(turnNumber)"
        items.removeAll()
        order.removeAll()
        openMessage = nil
        openThought = nil
    }

    /// One `session/update`'s `update` object. Returns the `sessionUpdate` it was.
    @discardableResult
    func receive(_ update: [String: Any]) -> String? {
        guard let kind = update["sessionUpdate"] as? String else { return nil }
        switch kind {
        case "agent_message_chunk":
            guard let text = Self.text(update["content"]), !text.isEmpty else { return kind }
            openThought = nil
            let id = chunkID(update, open: &openMessage, prefix: "msg")
            if items[id] == nil {
                remember(AgentChatItem(id: id, kind: .assistant, text: "", isComplete: false,
                                       workContext: .init(providerTurnID: turnID)))
            }
            items[id]?.text += text
            onEvent(.textDelta(id: id, text: text))
        case "agent_thought_chunk":
            guard let text = Self.text(update["content"]), !text.isEmpty else { return kind }
            openMessage = nil
            let id = chunkID(update, open: &openThought, prefix: "thought")
            var item = items[id] ?? AgentChatItem(id: id, kind: .tool, text: "Thinking", detail: "", isComplete: false,
                workContext: .init(providerTurnID: turnID, itemType: "reasoning", sourceStatus: "running"))
            item.detail = (item.detail ?? "") + text
            remember(item)
        case "tool_call", "tool_call_update":
            openMessage = nil
            openThought = nil
            toolCall(update)
        case "plan":
            guard let item = plan(update["entries"] as? [[String: Any]] ?? []) else { return kind }
            remember(item)
        case "available_commands_update":
            let rows = update["availableCommands"] as? [[String: Any]] ?? []
            onEvent(.commandDescriptors(Self.commands(rows)))
        case "usage_update":
            guard let used = agentTokenCount(update["used"]) else { return kind }
            onEvent(.contextUsage(AgentContextUsage(usedTokens: used, contextWindow: agentContextWindow(update["size"]))))
        case "notice":
            let title = (update["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let description = (update["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let text = [title, description].compactMap({ $0 }).joined(separator: ": ").nonEmpty else { return kind }
            onEvent(.item(AgentChatItem(kind: .notice, text: String(text.prefix(4000)))))
        case "compaction_update":
            let id = "acp-compaction:" + ((update["compactionId"] as? String) ?? turnID)
            let status = update["status"] as? String
            let done = status == "completed" || status == "failed"
            let text = status == "failed" ? "Context compaction failed" : done ? "Context compacted" : "Compacting context"
            let item = AgentChatItem(id: id, kind: .tool, text: text, isComplete: done,
                createdAt: items[id]?.createdAt ?? Date(), updatedAt: Date(),
                workContext: .init(providerTurnID: turnID, itemType: "compaction", sourceStatus: done ? (status ?? "completed") : "running"))
            remember(item)
        default:
            // user_message_chunk is the agent's echo of a prompt the transcript already holds;
            // mode and option changes are the runtime's; titles and the rest aren't shown.
            break
        }
        return kind
    }

    /// Completes every open item as the turn ended: done, or stopped when `interrupted`.
    func endTurn(interrupted: Bool, failed: Bool = false) {
        for id in order {
            guard var item = items[id], !item.isComplete else { continue }
            item.isComplete = true
            item.updatedAt = Date()
            let status = failed ? "failed" : interrupted ? "interrupted" : "completed"
            switch item.workContext?.itemType {
            case "reasoning":
                item.workContext?.sourceStatus = status == "completed" ? "completed" : "interrupted"
            case "todo_list":
                item.workContext?.sourceStatus = status
            default:
                if var tool = item.tool {
                    if tool.status == .running { tool.status = failed ? .failed : interrupted ? .interrupted : .completed }
                    tool.completedAt = tool.completedAt ?? Date()
                    item.tool = tool
                    item.workContext?.sourceStatus = status
                }
            }
            items[id] = item
            onEvent(.item(item))
        }
        items.removeAll()
        order.removeAll()
        openMessage = nil
        openThought = nil
    }

    // MARK: Pieces

    private func remember(_ item: AgentChatItem) {
        if items[item.id] == nil { order.append(item.id) }
        items[item.id] = item
        onEvent(.item(item))
    }

    /// A chunk's item: its message ID when it has one, else the one still open, else a new one.
    private func chunkID(_ update: [String: Any], open: inout String?, prefix: String) -> String {
        if let message = update["messageId"] as? String, !message.isEmpty {
            let id = "acp-\(prefix):\(turnID):\(message)"
            open = id
            return id
        }
        if let open { return open }
        counter += 1
        let id = "acp-\(prefix):\(turnID):\(counter)"
        open = id
        return id
    }

    private func toolCall(_ update: [String: Any]) {
        guard let callID = update["toolCallId"] as? String, !callID.isEmpty else { return }
        let id = "acp-tool:" + callID
        let previous = items[id]
        let kind = (update["kind"] as? String) ?? previous?.tool?.name.flatMap { Self.kinds[$0] }
        let title = (update["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previous?.text ?? kind ?? "Tool"
        var activity = previous?.tool ?? AgentToolActivity(name: kind ?? "other", status: .running, startedAt: Date())
        if let kind {
            activity.name = kind
            activity.category = Self.category(kind, title: title)
            activity.presentation = Self.presentation(kind)
        } else if activity.category == nil {
            activity.category = AgentToolActivity.category(for: title)
        }
        if let raw = update["rawInput"] as? [String: Any], !raw.isEmpty {
            activity.input = activity.presentation == .command ? (raw["command"] as? String ?? agentRuntimeJSON(raw)) : agentRuntimeJSON(raw)
            if activity.presentation == .command, raw["command"] == nil, let command = raw["cmd"] as? String { activity.input = command }
            if let url = raw["url"] as? String { activity.urls = [url] }
            if let query = (raw["query"] as? String) ?? (raw["pattern"] as? String) { activity.searchPatterns = [query] }
        }
        let paths = (update["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        if !paths.isEmpty { activity.filePaths = Array(paths.prefix(64)) }
        if let content = update["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                guard block["type"] as? String == "content" else { return nil }
                return Self.text(block["content"])
            }
            if !texts.isEmpty { activity.output = CodexAgentRuntime.bounded(texts.joined(separator: "\n")) }
            let diffs = content.compactMap { block -> AgentToolActivity.FileChange? in
                guard block["type"] as? String == "diff", let path = block["path"] as? String else { return nil }
                let old = block["oldText"] as? String
                let new = block["newText"] as? String ?? ""
                return .init(path: path, diff: Self.diff(old: old, new: new), kind: old == nil ? "add" : "update")
            }
            if !diffs.isEmpty {
                activity.fileChanges = Array(diffs.prefix(64))
                activity.filePaths = diffs.map(\.path)
                activity.presentation = .fileChange
                activity.category = .edit
                activity.fileChangeDetails = .init(fileName: diffs[0].path, diff: diffs[0].diff,
                    operations: diffs.map { .init(operation: $0.kind ?? "update", path: $0.path) })
            }
        }
        if let raw = update["rawOutput"] as? [String: Any] {
            let metadata = raw["metadata"] as? [String: Any]
            if let exit = (raw["exitCode"] ?? raw["exit_code"] ?? metadata?["exit"]) as? Int { activity.exitCode = exit }
            if activity.output == nil, let output = (raw["output"] ?? raw["stdout"]) as? String, !output.isEmpty {
                activity.output = CodexAgentRuntime.bounded(output)
            }
        }
        let status = (update["status"] as? String) ?? (previous == nil ? "pending" : nil)
        switch status {
        case "completed":
            activity.status = (activity.exitCode ?? 0) == 0 ? .completed : .failed
            activity.completedAt = Date()
        case "failed":
            activity.status = .failed
            activity.completedAt = Date()
        case "pending", "in_progress":
            activity.status = .running
        default:
            break
        }
        let done = activity.status == .completed || activity.status == .failed
        var item = AgentChatItem(id: id, kind: .tool, text: title, isComplete: done, tool: activity,
                                 createdAt: previous?.createdAt ?? Date(), updatedAt: Date(),
                                 workContext: .init(providerTurnID: turnID,
                                                    sourceStatus: done ? (activity.status == .failed ? "failed" : "completed") : "running"))
        item.detail = activity.presentation == .fileChange ? nil : activity.output
        remember(item)
    }

    private func plan(_ entries: [[String: Any]]) -> AgentChatItem? {
        guard !entries.isEmpty else { return nil }
        let steps = entries.prefix(64).enumerated().map { index, entry -> [String: String] in
            let text = (entry["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = entry["status"] as? String
            return ["id": "step-\(index + 1)", "text": text.isEmpty ? "Step \(index + 1)" : String(text.prefix(2000)),
                    "status": status == "in_progress" ? "running" : status == "completed" ? "completed" : "pending"]
        }
        let done = steps.allSatisfy { $0["status"] == "completed" }
        return AgentChatItem(id: "turn-plan:" + turnID, kind: .tool, text: "Updated plan",
                             detail: agentRuntimeJSON(["steps": steps]), isComplete: done,
                             workContext: .init(providerTurnID: turnID, itemType: "todo_list",
                                                sourceStatus: done ? "completed" : "running", planStatus: "active"))
    }

    // MARK: Shapes

    /// The text of a content block, `{type: "text", text}`; other blocks have none.
    static func text(_ content: Any?) -> String? {
        if let blocks = content as? [[String: Any]] { return blocks.compactMap(text).joined().nonEmpty }
        guard let block = content as? [String: Any] else { return nil }
        switch block["type"] as? String {
        case "text": return block["text"] as? String
        case "resource_link": return (block["uri"] as? String).map { "[\(block["name"] as? String ?? $0)](\($0))" }
        default: return nil
        }
    }

    static func commands(_ rows: [[String: Any]]) -> [AgentCommandDescriptor] {
        var seen = Set<String>()
        return rows.prefix(256).compactMap { row in
            guard let name = row["name"] as? String, AgentSlashCommand.validName(name), seen.insert(name).inserted else { return nil }
            let hint = (row["input"] as? [String: Any])?["hint"] as? String
            return AgentCommandDescriptor(name: name, description: String((row["description"] as? String ?? "").prefix(512)),
                                          argumentHint: hint.map { String($0.prefix(128)) }, isSkill: false)
        }
    }

    /// ACP tool kinds by their own name, for updates that leave the kind out.
    private static let kinds: [String: String] = Dictionary(uniqueKeysWithValues:
        ["read", "edit", "delete", "move", "search", "execute", "think", "fetch", "switch_mode", "other"].map { ($0, $0) })

    static func category(_ kind: String, title: String) -> AgentToolActivity.Category {
        switch kind {
        case "read": .read
        case "edit", "delete", "move": .edit
        case "search": .search
        case "execute": .command
        case "fetch": .web
        default: AgentToolActivity.category(for: title)
        }
    }

    static func presentation(_ kind: String) -> AgentToolActivity.Presentation? {
        switch kind {
        case "execute": .command
        case "edit", "delete", "move": .fileChange
        default: .dynamicTool
        }
    }

    /// A whole-file diff of `old` to `new`, as the transcript's diff view reads it.
    static func diff(old: String?, new: String) -> String {
        let removed = (old ?? "").isEmpty ? [] : (old ?? "").components(separatedBy: "\n").map { "-" + $0 }
        let added = new.isEmpty ? [] : new.components(separatedBy: "\n").map { "+" + $0 }
        let lines = removed + added
        let limited = lines.count > 4000 ? Array(lines.prefix(4000)) + [AgentToolActivity.diffTruncationMarker] : lines
        return limited.joined(separator: "\n")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
