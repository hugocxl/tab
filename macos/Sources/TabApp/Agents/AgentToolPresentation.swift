import AppKit
import TabProtocol

@MainActor
enum AgentToolPresentation {
    /// What the tool did, as a header shows it: `Run`, `Read`, `Search web`, `Load tools`,
    /// or a provider's tool name in plain words.
    static func displayName(_ activity: AgentToolActivity) -> String {
        // An MCP tool, `mcp__server__tool`, keeps its server's name unless the tool already says it.
        if let raw = activity.name, raw.hasPrefix("mcp__") {
            let parts = raw.components(separatedBy: "__")
            if parts.count >= 3, !parts[1].isEmpty {
                let tool = words(parts[2...].joined(separator: "_"))
                let server = mcpServerName(parts[1])
                return tool.lowercased().hasPrefix(server.lowercased()) ? tool : tool + " (" + server + ")"
            }
        }
        let name = activity.name.map { $0.components(separatedBy: "__").last ?? $0 } ?? ""
        let key = normalized(name)
        switch activity.category ?? .other {
        case .command: return "Run"
        case .read: return "Read"
        case .edit: return editTitle(activity, name: name)
        case .search:
            switch key {
            case "glob": return "Find files"
            case "listfiles", "ls": return "List files"
            default: return "Search"
            }
        case .web:
            let fetches = ["webfetch", "fetch", "openpage"].contains(key)
                || (activity.searchPatterns ?? []).isEmpty && !(activity.urls ?? []).isEmpty
            return fetches ? "Fetch" : "Search web"
        case .subagent: return "Agent"
        case .other:
            guard !name.isEmpty else { return "Tool" }
            return knownTitles[key] ?? words(name)
        }
    }

    /// Plain titles for provider tools whose names are jargon.
    private static let knownTitles: [String: String] = [
        "toolsearch": "Load tools",
        "todowrite": "Update todos",
        "updateplan": "Update plan",
        "skill": "Use skill",
        "askuserquestion": "Ask",
        "enterplanmode": "Plan",
        "exitplanmode": "Present plan",
        "bashoutput": "Read output",
        "taskoutput": "Read output",
        "writestdin": "Write input",
        "killshell": "Stop shell",
        "killbash": "Stop shell",
        "taskstop": "Stop task",
        "sendmessage": "Message agent",
        "listagents": "List agents",
        "croncreate": "Schedule task",
        "crondelete": "Cancel schedule",
        "cronlist": "List schedules",
        "viewimage": "View image",
        "listmcpresourcestool": "List resources",
        "readmcpresourcetool": "Read resource",
        "lsp": "Code intelligence",
    ]

    /// A tool name in lowercase without separators: `ToolSearch` and `tool_search` match.
    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }

    /// `ScheduleWakeup`, `create_issue` or `notion-search` as sentence-cased words.
    static func words(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            // A capital starts a word unless it continues an acronym such as `LSP` or `URL`.
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character.isUppercase, !current.isEmpty,
               previous?.isLowercase == true || previous?.isNumber == true || next?.isLowercase == true {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return name }
        let rest = words.dropFirst().map { $0.count > 1 && $0.allSatisfy(\.isUppercase) ? $0 : $0.lowercased() }
        let lead = first.count > 1 && first.allSatisfy(\.isUppercase) ? first : first.prefix(1).uppercased() + first.dropFirst()
        return ([lead] + rest).joined(separator: " ")
    }

    /// An MCP server's name for people: `claude_ai_Google_Calendar` is `Google Calendar`.
    private static func mcpServerName(_ server: String) -> String {
        let bare = server.hasPrefix("claude_ai_") ? String(server.dropFirst("claude_ai_".count)) : server
        let parts = bare.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// An edit's title by what it did: `Create` a new file, `Write` one over, `Delete`, else `Edit`.
    private static func editTitle(_ activity: AgentToolActivity, name: String) -> String {
        let kinds = Set((activity.fileChanges ?? []).compactMap { $0.kind?.lowercased() }
                        + (activity.fileChangeDetails?.operations ?? []).map { $0.operation.lowercased() })
        if !kinds.isEmpty, kinds.isSubset(of: ["add", "create", "created", "new"]) { return "Create" }
        if !kinds.isEmpty, kinds.isSubset(of: ["delete", "deleted", "remove"]) { return "Delete" }
        if name.lowercased() == "write" || kinds == ["write"] { return "Write" }
        return "Edit"
    }

    /// Lines an edit added and removed, from the provider's counts or its diffs.
    static func changeCounts(_ activity: AgentToolActivity) -> (additions: UInt64, deletions: UInt64)? {
        guard activity.presentation == .fileChange || activity.category == .edit else { return nil }
        if let details = activity.fileChangeDetails, details.additions != nil || details.deletions != nil {
            return (details.additions ?? 0, details.deletions ?? 0)
        }
        let diffs = (activity.fileChanges ?? []).compactMap(\.diff) + [activity.fileChangeDetails?.diff].compactMap { $0 }
        guard !diffs.isEmpty else { return nil }
        var additions: UInt64 = 0, deletions: UInt64 = 0
        for diff in diffs {
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("+"), !line.hasPrefix("+++") { additions += 1 }
                else if line.hasPrefix("-"), !line.hasPrefix("---") { deletions += 1 }
            }
        }
        return (additions, deletions)
    }

    /// What the tool operated on, for the header's code chip: a command, a path relative
    /// to `root`, a pattern or a query. Nil when it would only repeat the tool's name.
    static func operation(_ activity: AgentToolActivity, root: String?) -> String? {
        var summary = activity.summary.trimmingCharacters(in: .whitespaces)
        let key = normalized(activity.name.map { $0.components(separatedBy: "__").last ?? $0 } ?? "")
        let input = activity.input.flatMap(AgentToolJSON.parse)
        if key == "toolsearch", summary.hasPrefix("select:") {
            // `select:Read,WebSearch` loads those tools by name.
            summary = summary.dropFirst("select:".count).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        } else if key == "skill", let skill = input?["skill"]?.string, !skill.isEmpty {
            summary = skill
        } else if activity.category == .web, summary.hasPrefix("https://") || summary.hasPrefix("http://") {
            summary = String(summary.drop { $0 != "/" }.dropFirst(2))
        }
        if let root, !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if summary.hasPrefix(prefix) { summary.removeFirst(prefix.count) }
        }
        guard !summary.isEmpty, summary != activity.name, summary != displayName(activity), summary != "Tool" else { return nil }
        return summary
    }

    static func argumentsNeedScroll(_ input: String?) -> Bool {
        guard let input else { return false }
        let value = AgentToolJSON.parse(input) ?? .string(input)
        if case .object = value { return value["truncated"]?.encoded() == "true" && value["summary"]?.string != nil }
        return true
    }

    static func completedOutput(_ activity: AgentToolActivity, theme: AppTheme) -> NSAttributedString {
        let result = output(activity.output, isJSON: activity.outputIsJSON == true, theme: theme)
        guard result.length == 0, activity.status != .running else { return result }
        let empty = AgentCommandPresentation.text(AgentCommandPresentation.emptyOutput(activity.status), color: theme.fgMuted)
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
