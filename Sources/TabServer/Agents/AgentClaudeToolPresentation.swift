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

internal func agentClaudeToolPresentation(_ name: String) -> AgentToolActivity.Presentation {
    switch agentNormalizedClaudeToolName(name) {
    case "bash": return .command
    case "edit", "multiedit", "notebookedit", "write": return .fileChange
    case "webfetch", "websearch": return .webSearch
    default: return .dynamicTool
    }
}
