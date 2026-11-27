import Foundation

/// Recognizes the pull-request links of an assistant paragraph that get a card:
/// bare URLs, `<autolinks>` and Markdown links whose text is the URL itself.
/// Links with their own label, and links in code spans, stay ordinary links.
@MainActor
enum AgentPullRequestLink {
    /// github.com, plus the host of the project's `origin` remote for GitHub Enterprise.
    static func hosts(origin: String?) -> Set<String> {
        var hosts: Set<String> = ["github.com"]
        if let host = originHost(origin) { hosts.insert(host) }
        return hosts
    }

    /// The host of `https://host/owner/repo`, `ssh://git@host/owner/repo` or `git@host:owner/repo`.
    static func originHost(_ origin: String?) -> String? {
        guard let origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty else { return nil }
        if origin.contains("://") {
            guard let host = URL(string: origin)?.host?.lowercased(), !host.isEmpty else { return nil }
            return host
        }
        guard let colon = origin.firstIndex(of: ":") else { return nil }
        var host = origin[..<colon]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        guard !host.isEmpty, !host.contains("/"), !origin[origin.index(after: colon)...].hasPrefix("/") else { return nil }
        return host.lowercased()
    }

    /// The pull-request URLs that `markdown` (one paragraph or list item) shows bare, in order, once each.
    static func urls(in markdown: String, hosts: Set<String>) -> [URL] {
        guard !hosts.isEmpty, markdown.contains("/pull/") else { return [] }
        let text = labelledLinksRemoved(codeSpansRemoved(markdown))
        guard let pattern = urlPattern else { return [] }
        var seen: Set<String> = []
        var result: [URL] = []
        let source = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            var candidate = source.substring(with: match.range)
            while let last = candidate.last, ".,;:!?'\"*_~".contains(last) { candidate.removeLast() }
            guard let url = URL(string: candidate), let host = url.host?.lowercased(), hosts.contains(host),
                  let target = AgentConversationPullRequestPreview.target(from: url) else { continue }
            let key = "\(target.host)/\(target.repository.lowercased())/\(target.number)"
            guard seen.insert(key).inserted else { continue }
            result.append(url)
        }
        return result
    }

    private static let urlPattern = try? NSRegularExpression(pattern: #"https://[^\s<>()\[\]`]+"#)
    private static let linkPattern = try? NSRegularExpression(pattern: #"!?\[([^\]]*)\]\(\s*<?([^)\s>]*)>?(?:\s+"[^"]*")?\s*\)"#)

    /// Inline code is literal text, never a card.
    private static func codeSpansRemoved(_ text: String) -> String {
        guard text.contains("`") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "`" else { result.append(text[index]); index = text.index(after: index); continue }
            var run = index
            while run < text.endIndex, text[run] == "`" { run = text.index(after: run) }
            let fence = String(text[index..<run])
            guard let close = text.range(of: fence, range: run..<text.endIndex) else {
                result += fence
                index = run
                continue
            }
            result += String(repeating: " ", count: text[index..<close.upperBound].count)
            index = close.upperBound
        }
        return result
    }

    /// Keeps a Markdown link's destination only when its text is that same URL.
    private static func labelledLinksRemoved(_ text: String) -> String {
        guard text.contains("]("), let pattern = linkPattern else { return text }
        let source = NSMutableString(string: text)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let label = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let destination = source.substring(with: match.range(at: 2))
            let isImage = source.substring(with: match.range).hasPrefix("!")
            let replacement = !isImage && (label == destination || label == "<\(destination)>") ? " \(destination) " : " "
            source.replaceCharacters(in: match.range, with: replacement)
        }
        return source as String
    }
}
