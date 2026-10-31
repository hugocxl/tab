import AppKit
import TabProtocol

@MainActor
enum AgentToolPresentation {
    static func argumentsNeedScroll(_ input: String?) -> Bool {
        guard let input else { return false }
        let value = AgentToolJSON.parse(input) ?? .string(input)
        if case .object = value { return value["truncated"]?.encoded() == "true" && value["summary"]?.string != nil }
        return true
    }

    static func completedOutput(_ activity: AgentToolActivity, theme: AppTheme) -> NSAttributedString {
        let result = output(activity.output, isJSON: activity.outputIsJSON == true, theme: theme)
        guard result.length == 0, activity.status != .running else { return result }
        let empty = AgentCommandPresentation.text("No output.", color: theme.fgMuted)
        empty.addAttribute(.font, value: NSFontManager.shared.convert(AppFont.mono(13), toHaveTrait: .italicFontMask), range: NSRange(location: 0, length: empty.length))
        return empty
    }

    static func arguments(_ input: String?, theme: AppTheme) -> NSAttributedString {
        guard let input else { return AgentCommandPresentation.text("", color: theme.fgMuted) }
        let value = AgentToolJSON.parse(input) ?? .string(input)
        let result = AgentCommandPresentation.text("", color: theme.fg.withAlphaComponent(0.85))
        if case .object(let entries) = value, value["truncated"]?.encoded() != "true" || value["summary"]?.string == nil {
            for (index, entry) in entries.enumerated() {
                if index > 0 { result.append(AgentCommandPresentation.text("\n", color: theme.fgMuted)) }
                result.append(AgentCommandPresentation.text(entry.0 + " ", color: theme.fgMuted))
                let text = entry.1.string.flatMap { $0.isEmpty ? nil : $0 } ?? entry.1.encoded()
                result.append(AgentCommandPresentation.text(text, color: theme.fg.withAlphaComponent(0.85)))
            }
        } else {
            result.append(AgentJSONSyntax.highlight(formatted(value) ?? "", theme: theme))
        }
        return result
    }

    static func formatted(_ value: AgentToolJSON) -> String? {
        if value.encoded() == "null" { return nil }
        if let text = blocks(value, depth: 0) { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prettyJSON(text) }
        let text = value.encoded(pretty: true)
        return text == "{}" || text == "[]" ? nil : text
    }

    static func prettyJSON(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return source }
        if let value = AgentToolJSON.parse(trimmed) { return value.encoded(pretty: true) }
        let lines = trimmed.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let documents = lines.compactMap(AgentToolJSON.parse)
        return documents.count == lines.count ? documents.map { $0.encoded(pretty: true) }.joined(separator: "\n\n") : source
    }

    private static func blocks(_ value: AgentToolJSON, depth: Int) -> String? {
        guard depth <= 4 else { return nil }
        switch value {
        case .string(let text): return text
        case .array(let values):
            let parts = values.compactMap { blocks($0, depth: depth + 1) }
            return parts.count == values.count ? parts.filter { !$0.isEmpty }.joined(separator: "\n") : nil
        case .object(let entries):
            if value["type"]?.string == "text" { return value["text"]?.string }
            if value["type"]?.string == "image" { return "[image]" }
            if value["type"]?.string == "resource_link" { return value["uri"]?.string }
            if value["type"]?.string == "resource" { return value["resource"]?["text"]?.string ?? value["resource"]?["uri"]?.string }
            let keys = entries.map(\.0).filter { $0 != "isError" && $0 != "is_error" }
            if keys == ["content"], let content = value["content"] { return blocks(content, depth: depth + 1) }
            if Set(keys) == ["content", "structuredContent"], let content = value["content"], let text = blocks(content, depth: depth + 1), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            return nil
        default: return nil
        }
    }

    static func output(_ source: String?, isJSON: Bool = false, theme: AppTheme) -> NSAttributedString {
        let text = source.map { isJSON ? (formatted(AgentToolJSON.parse($0) ?? .string($0)) ?? "") : prettyJSON($0) } ?? ""
        return AgentCommandPresentation.text(text, color: theme.fgMuted)
    }
}
