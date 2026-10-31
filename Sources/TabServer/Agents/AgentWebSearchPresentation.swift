import Foundation
import TabProtocol

/// Provider web-search patterns preserve duplicates and action order.
internal func agentCodexWebSearchPatterns(_ item: [String: Any]) -> [String] {
    let query = item["query"] as? String
    var values: [String?]
    if let action = item["action"] as? [String: Any] {
        switch action["type"] as? String {
        case "search": values = (action["queries"] as? [String] ?? []).map(Optional.some) + [action["query"] as? String, query]
        case "openPage": values = [action["url"] as? String, query]
        case "findInPage": values = [action["pattern"] as? String, action["url"] as? String, query]
        default: values = [query]
        }
    } else { values = [query] }
    return values.compactMap { value in
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Keep Claude's typed search metadata rather than trying to recover titles from display text.
internal func agentUpdateClaudeWebSearch(_ activity: inout AgentToolActivity, result: Any?) {
    guard activity.presentation == .webSearch else { return }
    let input = activity.input.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let output = result as? [String: Any]
    let isSearch = output?["query"] is String && output?["results"] is [Any] && output?["durationSeconds"] is NSNumber
    let pattern = ["query", "url", "pattern"].compactMap { key -> String? in
        guard let value = (input?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }.first
        ?? (isSearch ? output?["query"] as? String : nil)
    activity.searchPatterns = pattern.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : [$0] } ?? []
    if isSearch {
        activity.webResults = (output?["results"] as? [Any] ?? []).flatMap { result -> [AgentToolActivity.WebResult] in
            guard let record = result as? [String: Any], let content = record["content"] as? [[String: Any]] else { return [] }
            return content.map { .init(title: $0["title"] as? String, url: $0["url"] as? String) }
        }
    }
    if (activity.webResults ?? []).isEmpty, agentNormalizedClaudeToolName(activity.name ?? "") == "webfetch",
       let text = activity.output, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let ns = text as NSString
        activity.webResults = [.init(url: (input?["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                                     snippet: ns.substring(to: min(8000, ns.length)))]
    }
}
