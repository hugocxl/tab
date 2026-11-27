import Foundation
import TabProtocol

/// A tool step as one short sentence: "Ran git push", "Read Package.swift",
/// "Edited View.swift +12 −3".
public struct ToolStep: Hashable, Sendable {
    /// The verb: past tense once done, "-ing" while running.
    public var verb: String
    /// What the step acted on: a command, a file name, a pattern or a site.
    public var subject: String
    /// Whether the subject is code, shown in a monospaced font.
    public var subjectIsCode: Bool
    /// Lines an edit added and removed.
    public var additions: UInt64?
    public var deletions: UInt64?
    /// The full command, for an expanded command step.
    public var command: String?

    public init(_ item: AgentChatItem) {
        let tool = item.tool
        let running = (tool?.status ?? (item.isComplete ? .completed : .running)) == .running
        let summary = tool?.summary ?? item.text
        additions = tool?.fileChangeDetails?.additions
        deletions = tool?.fileChangeDetails?.deletions
        command = nil
        subjectIsCode = false
        switch tool?.category {
        case .command:
            verb = running ? "Running" : "Ran"
            let full = Self.command(tool) ?? summary
            command = full
            subject = Self.withoutDirectoryChange(full)
            subjectIsCode = true
        case .read:
            verb = running ? "Reading" : "Read"
            subject = Self.fileName(summary)
        case .edit:
            verb = running ? "Editing" : "Edited"
            subject = Self.fileName(tool?.fileChangeDetails?.fileName ?? summary)
        case .search:
            verb = running ? "Searching" : "Searched"
            subject = summary
            subjectIsCode = true
        case .web:
            verb = running ? "Browsing" : "Browsed"
            subject = Self.site(summary)
        case .subagent:
            verb = running ? "Delegating" : "Delegated"
            subject = summary
        default:
            verb = tool?.name ?? "Tool"
            subject = summary == verb ? "" : summary
        }
    }

    /// The shell command from a command tool's JSON input.
    static func command(_ tool: AgentToolActivity?) -> String? {
        guard let input = tool?.input, let data = input.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = (object["command"] ?? object["cmd"]) as? String else { return nil }
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The command's first line, without a leading `cd <folder> &&` or
    /// `NAME=value;`: agents start most commands in the project folder, and
    /// the path crowds out what actually runs.
    static func withoutDirectoryChange(_ command: String) -> String {
        let first = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
        var rest = Substring(first.trimmingCharacters(in: .whitespaces))
        let prefixes = [#"^cd\s+("[^"]*"|'[^']*'|\S+)\s*(&&|;)\s*"#, #"^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'[^']*'|\S*)\s*(&&|;)\s*"#]
        while let match = prefixes.lazy.compactMap({ rest.range(of: $0, options: .regularExpression) }).first,
              match.upperBound < rest.endIndex {
            rest = rest[match.upperBound...]
        }
        return String(rest)
    }

    /// The last path component, or the text as it is when it isn't a path.
    static func fileName(_ path: String) -> String {
        guard path.contains("/") else { return path }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// A URL's host, or the query as it is.
    static func site(_ text: String) -> String {
        guard let url = URL(string: text), let host = url.host() else { return text }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
