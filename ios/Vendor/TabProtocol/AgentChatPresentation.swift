import Foundation

/// Provider-observed tool activity. Input survives output updates and transcript persistence.
public struct AgentToolActivity: Codable, Hashable, Sendable {
    public enum Category: String, Codable, Hashable, Sendable {
        case command, read, search, edit, web, subagent, other
    }
    public enum Status: String, Codable, Hashable, Sendable {
        case running, completed, failed, denied, interrupted
    }
    /// Expanded inspector identity is independent of the compact row's semantic category.
    public enum Presentation: String, Codable, Hashable, Sendable {
        case command, dynamicTool, fileChange, fileSearch, webSearch, subagent
    }
    public struct FileChange: Codable, Hashable, Sendable {
        public var path: String
        public var diff: String?
        public var kind: String?
        public init(path: String, diff: String? = nil, kind: String? = nil) {
            self.path = path; self.diff = diff; self.kind = kind
        }
    }
    public struct FileSearchDetails: Codable, Hashable, Sendable {
        public struct Result: Codable, Hashable, Sendable {
            public var fileName: String
            public var line: UInt64?
            public var column: UInt64?
            public var preview: String?
            public init(fileName: String, line: UInt64? = nil, column: UInt64? = nil, preview: String? = nil) {
                self.fileName = fileName; self.line = line; self.column = column; self.preview = preview
            }
        }
        public var pattern: String?
        public var results: [Result]?
        public init(pattern: String? = nil, results: [Result]? = nil) {
            self.pattern = pattern; self.results = results
        }
    }
    public struct WebResult: Codable, Hashable, Sendable {
        public var title: String?
        public var url: String?
        public var snippet: String?
        public init(title: String? = nil, url: String? = nil, snippet: String? = nil) {
            self.title = title; self.url = url; self.snippet = snippet
        }
    }
    public struct FileChangeDetails: Codable, Hashable, Sendable {
        public struct Operation: Codable, Hashable, Sendable {
            public var operation: String
            public var path: String
            public var oldPath: String?
            public var fileType: String?
            public var mimeType: String?
            public init(operation: String, path: String, oldPath: String? = nil, fileType: String? = nil, mimeType: String? = nil) {
                self.operation = operation; self.path = path; self.oldPath = oldPath; self.fileType = fileType; self.mimeType = mimeType
            }
        }
        public var fileName: String
        public var diff: String?
        public var additions: UInt64?
        public var deletions: UInt64?
        public var operations: [Operation]?
        public init(fileName: String, diff: String? = nil, additions: UInt64? = nil, deletions: UInt64? = nil, operations: [Operation]? = nil) {
            self.fileName = fileName; self.diff = diff; self.additions = additions; self.deletions = deletions; self.operations = operations
        }
    }

    public var name: String?
    public var category: Category?
    public var presentation: Presentation?
    /// The last line of a diff the server cut to fit the transcript.
    public static let diffTruncationMarker = "[Diff truncated]"
    public var presentsCommand: Bool { presentation == .command || (presentation == nil && (category == .command || name == "commandExecution")) }
    public var input: String?
    public var output: String?
    /// Distinguishes a structured provider result from text that happens to contain JSON.
    public var outputIsJSON: Bool?
    public var status: Status?
    public var filePaths: [String]?
    public var fileChanges: [FileChange]?
    public var urls: [String]?
    public var searchPatterns: [String]?
    public var webResults: [WebResult]?
    public var fileSearchDetails: FileSearchDetails?
    public var fileChangeDetails: FileChangeDetails?
    public var startedAt: Date?
    public var completedAt: Date?
    public var exitCode: Int?
    /// The size of the whole output when the transcript keeps only part of it; the server
    /// holds the rest, read with `AgentConversationRequest.toolOutput`.
    public var fullOutputBytes: Int?

    public init(name: String? = nil, category: Category? = nil, input: String? = nil,
                output: String? = nil, status: Status? = nil, filePaths: [String]? = nil,
                fileChanges: [FileChange]? = nil, urls: [String]? = nil,
                startedAt: Date? = nil, completedAt: Date? = nil, exitCode: Int? = nil, presentation: Presentation? = nil) {
        self.name = name; self.category = category; self.input = input; self.output = output
        self.status = status; self.filePaths = filePaths; self.fileChanges = fileChanges
        self.urls = urls; self.startedAt = startedAt; self.completedAt = completedAt; self.exitCode = exitCode
        self.presentation = presentation
    }

    public static func category(for name: String) -> Category {
        let name = name.lowercased()
        if ["bash", "shell", "commandexecution", "exec_command", "terminal"].contains(name) { return .command }
        if ["read", "read_file", "readfile"].contains(name) { return .read }
        if ["glob", "grep", "search", "list_files"].contains(name) { return .search }
        if ["edit", "write", "multiedit", "notebookedit", "apply_patch", "filechange"].contains(name) { return .edit }
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
