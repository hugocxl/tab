import AppKit

/// The response renderer never opens file URLs itself. Files go through the pane's project-aware
/// callback; only ordinary web/mail links are handed back to AppKit's default link handling.
enum AgentResponseLink: Equatable {
    case external(URL)
    case file(String, Int?)

    /// Inline code often contains member names such as NSColor.labelColor.
    /// Infer only recognizable filenames; explicit Markdown destinations remain unrestricted.
    static func inferredFile(_ text: String) -> Self? {
        guard case .file(let path, let line) = parse(text) else { return nil }
        let ext = (path.lowercased() as NSString).pathExtension
        let fileExtensions: Set<String> = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb",
            "js", "jsx", "ts", "tsx", "json", "jsonc", "yaml", "yml", "toml", "xml",
            "html", "css", "scss", "md", "mdx", "txt", "sh", "zsh", "bash", "sql",
            "java", "kt", "kts", "cs", "fs", "php", "vue", "svelte", "dart", "ex", "exs",
            "lock", "plist", "entitlements", "xcconfig", "xib", "storyboard", "xcassets",
            "svg", "png", "jpg", "jpeg", "webp", "gif", "pdf", "csv", "env", "conf", "ini"
        ]
        guard path.contains("/") || ext.isEmpty || fileExtensions.contains(ext) else { return nil }
        return .file(path, line)
    }

    static func parse(_ destination: String) -> Self? {
        let raw = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("//"), let url = URL(string: "https:" + raw) { return .external(url) }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            if ["http", "https"].contains(scheme), url.host != nil { return .external(url) }
            if scheme == "mailto", raw.count > "mailto:".count { return .external(url) }
            if scheme == "tab-agent-file" {
                guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let path = parts.queryItems?.first(where: { $0.name == "path" })?.value else { return nil }
                let line = parts.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
                return .file(path, line)
            }
            if scheme == "file" {
                guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
                return filePosition(url.path, fragment: url.fragment)
            }
        }
        let pieces = raw.components(separatedBy: "#")
        let candidate = filePosition(pieces[0].removingPercentEncoding ?? pieces[0], fragment: pieces.count == 2 ? pieces[1] : nil)
        guard case .file(let path, _) = candidate, !path.contains("://"),
              !path.contains(":"), plausiblePath(path) else { return nil }
        return candidate
    }

    private static func filePosition(_ source: String, fragment: String?) -> Self {
        var path = source
        var line: Int?
        if let match = source.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            let position = source[match].dropFirst().split(separator: ":").first.flatMap { Int($0) }
            if let position, position > 0 { line = position; path = String(source[..<match.lowerBound]) }
        }
        if line == nil, let fragment, fragment.range(of: #"^L\d+(?:C\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let digits = fragment.dropFirst().prefix { $0.isNumber }
            if let position = Int(digits), position > 0 { line = position }
        }
        return .file(path, line)
    }

    private static func plausiblePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../") { return true }
        if path.contains("/") { return true }
        let lower = path.lowercased()
        if ["makefile", "dockerfile", "readme", "license", "changelog", "gemfile", "brewfile", "justfile", "package.swift"].contains(lower) { return true }
        let ext = (lower as NSString).pathExtension
        guard !ext.isEmpty, ext.rangeOfCharacter(from: .letters) != nil else { return false }
        return !["com", "org", "net", "io", "dev", "app", "ai"].contains(ext)
    }

    var attributeURL: URL? {
        switch self {
        case .external(let url): return url
        case .file(let path, let line):
            var parts = URLComponents()
            parts.scheme = "tab-agent-file"
            parts.host = "open"
            parts.queryItems = [URLQueryItem(name: "path", value: path)]
            if let line { parts.queryItems?.append(URLQueryItem(name: "line", value: String(line))) }
            return parts.url
        }
    }
}
