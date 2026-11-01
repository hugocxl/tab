import Foundation
import TabProtocol

/// Only an already retained tool resource may become an MCP app or `html_render`
/// document. Tool/UI services that were not supplied by the provider remain unavailable.
@MainActor
enum AgentConversationMcpAsset {
    nonisolated static let maximumHTMLBytes = 5 * 1024 * 1024 // pinned MCP_APP_MAX_HTML_BYTES
    struct Ownership {
        var itemID: String
        var attachment: AgentChatAttachmentDescriptor
        var toolName: String
        var output: String
        func isRetained(in items: [String: AgentChatItem]) -> Bool {
            guard let item = items[itemID] else { return false }
            return item.kind == .tool && item.tool?.name == toolName && item.tool?.output == output
                && item.attachments?.contains(attachment) == true
        }
    }
    struct Match {
        var ownership: Ownership
        var reference: [String: Any]
        /// `html_render` bytes were prepared when published and are served verbatim.
        var publishedHTML = false
        var maximumBytes: Int { publishedHTML ? 25 * 1024 * 1024 : maximumHTMLBytes }
    }
    static func htmlRenderCandidates(attachmentID: String, items: [AgentChatItem]) -> [Match] {
        items.compactMap { item in
            guard item.kind == .tool, let tool = item.tool, let name = tool.name,
                  tool.presentation == nil || tool.presentation == .dynamicTool, let output = tool.output else { return nil }
            var budget = ReadBudget()
            guard let object = read(output, budget: &budget), !budget.exceeded,
                  let reference = object["htmlRender"] as? [String: Any], let id = boundedName(reference["attachmentId"]),
                  id == attachmentID,
                  let attachment = item.attachments?.first(where: { $0.id == id }),
                  attachment.mimeType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/html",
                  attachment.byteCount <= 25 * 1024 * 1024 else { return nil }
            return Match(ownership: Ownership(itemID: item.id, attachment: attachment, toolName: name, output: output), reference: reference, publishedHTML: true)
        }
    }
    static func match(attachmentID: String, items: [AgentChatItem]) -> Match? {
        for item in items where item.kind == .tool {
            guard let tool = item.tool, let toolName = tool.name, tool.presentation == nil || tool.presentation == .dynamicTool,
                  let output = tool.output else { continue }
            var budget = ReadBudget()
            guard let object = read(output, budget: &budget), !budget.exceeded,
                  let app = (object["tabMcpApp"] ?? object["t3McpApp"]) as? [String: Any],
                  let id = boundedName(app["attachmentId"]),
                  let server = boundedName(app["server"]), let name = boundedName(app["tool"]),
                  toolName == server + "." + name,
                  let uri = app["resourceUri"] as? String, uri.utf16.count <= 4096, uri.hasPrefix("ui://"),
                  id == attachmentID,
                  let attachment = item.attachments?.first(where: { $0.id == id }),
                  attachment.mimeType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/html",
                  attachment.byteCount <= maximumHTMLBytes else { continue }
            return Match(ownership: Ownership(itemID: item.id, attachment: attachment, toolName: toolName, output: output), reference: app)
        }
        return nil
    }
    private static func boundedName(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf16.count <= 256,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    // Pinned compactDynamicToolOutput's envelope limits and first-data order.
    private struct ReadBudget { var bytes = 16_384; var nodes = 128; var exceeded = false }
    private static func read(_ value: Any?, depth: Int = 0, budget: inout ReadBudget) -> [String: Any]? {
        guard depth <= 4, budget.nodes > 0 else { budget.exceeded = true; return nil }
        budget.nodes -= 1
        if let text = value as? String {
            guard text.utf8.count <= budget.bytes else { budget.exceeded = true; return nil }
            budget.bytes -= text.utf8.count
            guard let data = text.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
            return read(decoded, depth: depth + 1, budget: &budget)
        }
        if let values = value as? [Any] {
            guard values.count <= 32 else { budget.exceeded = true; return nil }
            var first: [String: Any]?
            for block in values {
                let text = (block as? [String: Any])?["text"]
                let nested = text as? [String: Any]
                let result = read(nested?["text"] ?? text, depth: depth + 1, budget: &budget)
                if first == nil { first = result }
                if budget.exceeded { break }
            }
            return first
        }
        guard let object = value as? [String: Any] else { return nil }
        let structured = object["structuredContent"]
        let content = (structured is NSNull ? nil : structured) ?? object["content"]
        if let content, !(content is NSNull) { return read(content, depth: depth + 1, budget: &budget) }
        return object
    }
}
