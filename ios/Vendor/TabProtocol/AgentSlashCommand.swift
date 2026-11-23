import Foundation

/// A leading slash invocation, shared by the composer and provider adapters.
public struct AgentSlashCommand: Equatable, Sendable {
    public var name: String
    public var arguments: String

    public init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let token = text.dropFirst().prefix { !$0.isWhitespace }
        guard Self.validName(String(token)) else { return nil }
        name = String(token)
        arguments = String(text.dropFirst(token.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0)
        }
    }

    public static let localNames: Set<String> = [
        "clear", "new", "resume", "skills", "status", "plan", "copy", "export", "help", "fork",
        "outline", "previous-prompt", "next-prompt", "model", "effort", "attach", "stop", "clear-draft", "stashes"
    ]

    /// Commands whose terminal UI or settings are not represented by an agent pane.
    public static let unavailableNames: Set<String> = [
        "agents", "auto-mode-setup", "color", "extra-usage", "fast", "focus", "heapdump", "workflow-launch-exec",
        "config", "settings", "reset", "import", "plugin-authoring", "claude-hud:setup", "claude-hud:configure", "update-config",
        "fewer-permission-prompts", "statusline", "terminal-setup", "vim", "theme"
    ]

    public static func unavailable(_ name: String) -> Bool {
        name.hasPrefix("__") || unavailableNames.contains(name)
    }

    /// Ordinary absolute paths must remain usable as prompts.
    public var isPath: Bool {
        ["tmp", "Users", "Applications", "Library", "System", "Volumes", "private", "usr", "opt", "var", "etc", "dev"].contains(name)
    }

    public func validationError(provider: AgentChatProvider, commands: [String], hasAttachments: Bool = false,
                                descriptors: [AgentCommandDescriptor] = []) -> String? {
        if isPath { return nil }
        if Self.unavailable(name) { return "/\(name) is not available in agent panes. Use the provider's terminal interface." }
        if Self.localNames.contains(name) { return "/\(name) is a Tab action. Run it from the conversation composer." }
        if let canonical = descriptors.first(where: { $0.names.contains(name) })?.name, canonical != name {
            if Self.unavailable(canonical) { return "/\(name) is not available in agent panes. Use the provider's terminal interface." }
            if Self.localNames.contains(canonical) { return "Use /\(canonical) in this pane instead of /\(name)." }
        }
        if name.hasPrefix("skill:") { return nil }
        guard commands.contains(name) || (provider == .claude && ["compact", "context", "cost", "usage"].contains(name)) else {
            return "Unknown command /\(name). Use /help to see available commands."
        }
        let attachmentFree: Set<String> = ["compact", "review", "context", "cost", "usage", "mcp", "autocompact",
            "output-style", "advisor", "reload-plugins", "reload-skills", "rename", "usage-credits", "recap", "skill-doctor", "list-agents"]
        if hasAttachments, provider == .codex || attachmentFree.contains(name) { return "/\(name) does not accept attachments. Remove them or send them in a separate message." }
        if provider == .codex {
            if name == "compact", !arguments.isEmpty { return "Codex /compact does not accept instructions. Use /compact without arguments." }
            if name == "review", !arguments.isEmpty,
               !arguments.hasPrefix("branch "), !arguments.hasPrefix("commit ") {
                return "Use /review, /review branch <name>, or /review commit <sha>."
            }
        }
        return nil
    }
}

/// Provider metadata is optional so older servers can continue sending command names.
public struct AgentCommandDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var argumentHint: String?
    public var isSkill: Bool?
    public var aliases: [String]?

    public init(name: String, description: String, argumentHint: String? = nil, isSkill: Bool? = nil, aliases: [String]? = nil) {
        self.name = name; self.description = description; self.argumentHint = argumentHint; self.isSkill = isSkill; self.aliases = aliases
    }

    public var names: [String] { [name] + (aliases ?? []) }

    public var isValid: Bool {
        AgentSlashCommand.validName(name) && description.utf8.count <= 2048 && (argumentHint?.utf8.count ?? 0) <= 512
            && (aliases?.count ?? 0) <= 16 && (aliases ?? []).allSatisfy(AgentSlashCommand.validName)
    }
}
