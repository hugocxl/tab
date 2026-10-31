import AppKit

extension NSAttributedString.Key {
    static let agentMarkdownAnchor = NSAttributedString.Key("TabAgentMarkdownAnchor")
    static let agentMarkdownHeading = NSAttributedString.Key("TabAgentMarkdownHeading")
}

@MainActor
struct AgentMarkdownHeadingTarget {
    let title: String
    let text: AgentRichTextView
    let range: NSRange
    var explicitID: String? = nil

    static func collect(in text: AgentRichTextView) -> [Self] {
        let content = text.attributedString()
        var targets: [Self] = []
        content.enumerateAttribute(.agentMarkdownHeading, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if let title = value as? String { targets.append(Self(title: title, text: text, range: range)) }
        }
        content.enumerateAttribute(.agentMarkdownAnchor, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if let id = value as? String { targets.append(Self(title: "", text: text, range: range, explicitID: id)) }
        }
        return targets.sorted { $0.range.location < $1.range.location }
    }
}

/// Matches the source renderer's Unicode heading slugs and message-local duplicate suffixes. Fragment navigation
/// never becomes a file open or changes the application's route.
@MainActor
enum AgentMarkdownFragments {
    static func slug(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{M}\p{N}\p{Pc} -]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
    }

    static func normalize(_ id: String) -> String {
        var result = id.removingPercentEncoding ?? id
        while result.hasPrefix("user-content-") { result.removeFirst("user-content-".count) }
        return result
    }

    static func identifiers(for titles: [String]) -> [String?] {
        var taken: Set<String> = []
        var suffixes: [String: Int] = [:]
        return titles.map { title in
            let base = slug(title)
            guard !base.isEmpty else { return nil }
            var suffix = suffixes[base] ?? 0
            var candidate = base
            while taken.contains(candidate) {
                suffix += 1
                candidate = "\(base)-\(suffix)"
            }
            suffixes[base] = suffix
            taken.insert(candidate)
            return candidate
        }
    }

    static func target(_ id: String, in targets: [AgentMarkdownHeadingTarget]) -> AgentMarkdownHeadingTarget? {
        let requested = normalize(id)
        if let explicit = targets.first(where: { $0.explicitID.map(normalize) == requested }) { return explicit }
        let identifiers = identifiers(for: targets.map(\.title))
        guard let index = identifiers.firstIndex(where: { $0.map(normalize) == requested }) else { return nil }
        return targets[index]
    }
}
