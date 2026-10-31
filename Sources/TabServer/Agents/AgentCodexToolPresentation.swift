import Foundation

/// Mirrors CodexAdapterV2's dynamic-tool projection before display formatting.
/// Keep content blocks intact so text, images and resource links can coexist.
internal func agentCodexDynamicToolName(_ item: [String: Any]) -> String {
    let tool = item["tool"] as? String ?? "Tool"
    if item["type"] as? String == "mcpToolCall" {
        return (item["server"] as? String).map { $0 + "." + tool } ?? tool
    }
    let namespace = (item["namespace"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return [namespace, tool].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".")
}

internal func agentCodexDynamicToolOutput(_ item: [String: Any]) -> Any? {
    if item["type"] as? String == "dynamicToolCall" {
        if let content = item["contentItems"], !(content is NSNull) { return content }
        return item["success"] as? Bool == false ? ["success": false] : nil
    }
    let result = item["result"] as? [String: Any]
    let structured = result?["structuredContent"]
    let output = structured != nil && !(structured is NSNull) ? structured : result?["content"]
    guard let error = item["error"], !(error is NSNull) else { return output }
    var value: [String: Any] = [:]
    if let message = (error as? [String: Any])?["message"] { value["error"] = message }
    if let output { value["result"] = output }
    return value
}

/// Mirrors the result projection without serializing provider dictionaries again.
/// Image extraction supplies exact subtree replacements, preserving adjacent keys.
internal func agentCodexDynamicToolOutputJSON(_ item: [String: Any], source: AgentProviderJSON?, replacements: [AgentProviderJSON.Replacement] = []) -> String? {
    guard let source else { return nil }
    let root: [AgentProviderJSON.Component] = [.key("params"), .key("item")]
    if item["type"] as? String == "dynamicToolCall" {
        guard let content = item["contentItems"], !(content is NSNull) else { return nil }
        return source.value(at: root + [.key("contentItems")], replacing: replacements)
    }
    let result = item["result"] as? [String: Any]
    let structured = result?["structuredContent"]
    let key = structured != nil && !(structured is NSNull) ? "structuredContent" : "content"
    let output = source.value(at: root + [.key("result"), .key(key)], replacing: replacements)
    guard let error = item["error"], !(error is NSNull) else { return output }
    var fields: [String] = []
    if let message = source.value(at: root + [.key("error"), .key("message")]) { fields.append("\"error\":" + message) }
    if let output { fields.append("\"result\":" + output) }
    return "{" + fields.joined(separator: ",") + "}"
}
