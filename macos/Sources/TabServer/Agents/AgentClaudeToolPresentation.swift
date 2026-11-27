import Foundation
import TabProtocol

/// ClaudeAdapterV2 classifies only its known native tools. Semantic aliases and
/// MCP tool names may share an icon, but must not silently select a typed inspector.
internal func agentNormalizedClaudeToolName(_ name: String) -> String {
    String(String.UnicodeScalarView(name.lowercased().unicodeScalars.filter { scalar in
        let value = scalar.value
        let whitespace = (9...13).contains(value) || (0x2000...0x200A).contains(value)
            || [0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF].contains(value)
        return !whitespace && scalar != "_" && scalar != "-"
    }))
}

/// A Grep or Glob result as file-search rows: `path:line:text` matches, or one path per
/// line. Nil when the output isn't a list of files.
internal func agentClaudeFileSearch(name: String, input: String?, output: String?) -> AgentToolActivity.FileSearchDetails? {
    guard ["grep", "glob"].contains(agentNormalizedClaudeToolName(name)), let output, !output.isEmpty else { return nil }
    let pattern = input.flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["pattern"] as? String
    var results: [AgentToolActivity.FileSearchDetails.Result] = []
    let matchLine = try? NSRegularExpression(pattern: #"^(.+?):(\d+):(.*)$"#)
    for raw in output.split(whereSeparator: \.isNewline).prefix(200) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("Found "), !line.hasPrefix("No files found"), !line.hasPrefix("No matches") else { continue }
        let range = NSRange(line.startIndex..., in: line)
        if let match = matchLine?.firstMatch(in: line, range: range),
           let file = Range(match.range(at: 1), in: line), let number = Range(match.range(at: 2), in: line),
           let text = Range(match.range(at: 3), in: line) {
            results.append(.init(fileName: String(line[file]), line: UInt64(line[number]), preview: String(line[text])))
        } else if !line.contains(" ") || line.hasPrefix("/") {
            results.append(.init(fileName: line))
        } else {
            return nil
        }
    }
    guard !results.isEmpty else { return nil }
    return .init(pattern: pattern, results: results)
}

internal func agentClaudeToolPresentation(_ name: String) -> AgentToolActivity.Presentation {
    switch agentNormalizedClaudeToolName(name) {
    case "bash": return .command
    case "edit", "multiedit", "notebookedit", "write": return .fileChange
    case "webfetch", "websearch": return .webSearch
    default: return .dynamicTool
    }
}
