import Foundation

/// Provider-observed tool activity. Input survives output updates and transcript persistence.
public struct AgentToolActivity: Codable, Hashable, Sendable {
    public enum Category: String, Codable, Hashable, Sendable {
        case command, read, search, edit, web, subagent, other
    }
    public enum Status: String, Codable, Hashable, Sendable {
        case running, completed, failed, denied, interrupted
    }
    public struct FileChange: Codable, Hashable, Sendable {
        public var path: String
        public var diff: String?
        public var kind: String?
        public init(path: String, diff: String? = nil, kind: String? = nil) {
            self.path = path; self.diff = diff; self.kind = kind
        }
    }

    public var name: String?
    public var category: Category?
    public var input: String?
    public var output: String?
    public var status: Status?
    public var filePaths: [String]?
    public var fileChanges: [FileChange]?
    public var urls: [String]?
    public var startedAt: Date?
    public var completedAt: Date?
    public var exitCode: Int?

    public init(name: String? = nil, category: Category? = nil, input: String? = nil,
                output: String? = nil, status: Status? = nil, filePaths: [String]? = nil,
                fileChanges: [FileChange]? = nil, urls: [String]? = nil,
                startedAt: Date? = nil, completedAt: Date? = nil, exitCode: Int? = nil) {
        self.name = name; self.category = category; self.input = input; self.output = output
        self.status = status; self.filePaths = filePaths; self.fileChanges = fileChanges
        self.urls = urls; self.startedAt = startedAt; self.completedAt = completedAt; self.exitCode = exitCode
    }

    public static func category(for name: String) -> Category {
        let name = name.lowercased()
        if ["bash", "shell", "commandexecution", "exec_command", "terminal"].contains(name) { return .command }
        if ["read", "read_file", "readfile"].contains(name) { return .read }
        if ["glob", "grep", "search", "list_files"].contains(name) { return .search }
        if ["edit", "write", "multiedit", "apply_patch", "filechange"].contains(name) { return .edit }
        if ["websearch", "webfetch", "web_search", "web_fetch"].contains(name) { return .web }
        if ["task", "agent", "collabagenttoolcall", "spawn_agent"].contains(name) { return .subagent }
        return .other
    }

    /// Compact, readable input; the original JSON is retained in `input` for expansion.
    public var summary: String {
        let values = input.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let keys: [String]
        switch category {
        case .command: keys = ["command", "cmd"]
        case .read, .edit: keys = ["file_path", "path", "filePath"]
        case .search: keys = ["pattern", "query", "path"]
        case .web: keys = ["query", "url"]
        case .subagent: keys = ["description", "prompt", "message"]
        default: keys = ["description", "command", "query", "path"]
        }
        let value = keys.compactMap { values?[$0] as? String }.first
            ?? filePaths?.first ?? (values == nil ? input : nil) ?? name ?? "Tool"
        return String(value.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(240))
    }
}
