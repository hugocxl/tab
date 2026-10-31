import Foundation

/// Shared/fileLinks.ts splitFilePathPosition semantics, including column offsets.
/// Renderer target paths are already decoded; decode file URLs exactly once.
struct AgentConversationFileTarget: Equatable {
    var path: String
    var line: Int?
    var column: Int?

    static func parse(_ target: String) -> Self? {
        var path = target, hash = ""
        if target.lowercased().hasPrefix("file:") {
            guard let parts = URLComponents(string: target), parts.scheme?.lowercased() == "file",
                  parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
                  let decoded = parts.percentEncodedPath.removingPercentEncoding else { return nil }
            path = decoded; hash = parts.fragment.map { "#" + $0 } ?? ""
        } else if target.contains("://") { return nil }
        else if let split = target.range(of: "#"), target[split.lowerBound...].range(of: #"^#L[0-9]+(?:C[0-9]+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            path = String(target[..<split.lowerBound]); hash = String(target[split.lowerBound...])
        }
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let source = path as NSString
        let suffix = try? NSRegularExpression(pattern: #":([0-9]+)(?::([0-9]+))?$"#)
        let fragment = try? NSRegularExpression(pattern: #"^#L([0-9]+)(?:C([0-9]+))?$"#, options: .caseInsensitive)
        let match = suffix?.firstMatch(in: path, range: NSRange(location: 0, length: source.length))
        let position = match ?? fragment?.firstMatch(in: hash, range: NSRange(location: 0, length: (hash as NSString).length))
        guard let position else { return Self(path: path) }
        let input = match == nil ? hash as NSString : source
        func positive(_ index: Int) -> Int? {
            let range = position.range(at: index)
            guard range.location != NSNotFound, let value = Int(input.substring(with: range)), value > 0 else { return nil }
            return value
        }
        return Self(path: match.map { source.substring(to: $0.range.location) } ?? path, line: positive(1), column: positive(2))
    }
}
