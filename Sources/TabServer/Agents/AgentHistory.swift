import Foundation
import TabProtocol

/// What a saved provider conversation becomes in Tab.
struct AgentHistoryTranscript: Sendable {
    var items: [AgentChatItem] = []
    var resolvedModel: String?
}

/// Reads the conversations Claude Code and Codex save on their own, under
/// `~/.claude/projects` and `~/.codex/sessions`. Neither format is documented,
/// so every field is optional and a line that doesn't parse is skipped.
struct AgentHistory: Sendable {
    /// Claude Code's configuration folder, `~/.claude` unless `CLAUDE_CONFIG_DIR` moves it.
    var claude: URL
    /// Codex's, `~/.codex` unless `CODEX_HOME` moves it.
    var codex: URL

    /// A listing reads up to this much of each file's start, where the folder and first prompt are.
    private static let headBytes = 1 << 20
    /// Usually this much is enough.
    private static let shortHeadBytes = 64 * 1024
    /// And this much of its end, where Claude Code appends titles.
    private static let tailBytes = 256 * 1024
    private static let maxListedFiles = 4000
    private static let maxEnumeratedFiles = 20_000
    private static let maxTranscriptBytes = 512 << 20

    init(claude: URL, codex: URL) {
        self.claude = claude
        self.codex = codex
    }

    init(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        func configured(_ key: String) -> URL? {
            environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        }
        self.init(claude: configured("CLAUDE_CONFIG_DIR") ?? home.appendingPathComponent(".claude", isDirectory: true),
                  codex: configured("CODEX_HOME") ?? home.appendingPathComponent(".codex", isDirectory: true))
    }

    /// Conversations started in `directory` itself, newest first, leaving out
    /// the provider sessions in `excluding`.
    func list(directory: String, excluding: Set<String>) -> AgentHistoryReply {
        var cwds = CwdMatcher(directory)
        var entries = claudeEntries(&cwds, excluding: excluding) + codexEntries(&cwds, excluding: excluding)
        entries.sort { $0.updatedAt > $1.updatedAt }
        let truncated = entries.count > AgentHistoryReply.maxEntries
        return AgentHistoryReply(entries: Array(entries.prefix(AgentHistoryReply.maxEntries)), truncated: truncated)
    }

    /// The transcript of `session`, which must have started in `directory`.
    func transcript(provider: AgentChatProvider, session: String, directory: String) throws -> AgentHistoryTranscript {
        try AgentHistoryEntry.validate(providerSession: session)
        var cwds = CwdMatcher(directory)
        switch provider {
        case .claude:
            guard let file = claudeFiles(cwds).first(where: { $0.deletingPathExtension().lastPathComponent == session }) else {
                throw ServiceError(.badRequest, "Claude Code has no saved conversation \(session) in this folder")
            }
            return try Self.claudeTranscript(Self.lines(of: file))
        case .codex:
            guard let file = codexFiles().first(where: { $0.url.lastPathComponent.hasSuffix("-\(session).jsonl") })?.url,
                  let meta = Self.codexMeta(Self.lines(Self.head(of: file, bytes: Self.headBytes), whole: false)),
                  meta.id == session, cwds.matches(meta.cwd) else {
                throw ServiceError(.badRequest, "Codex has no saved conversation \(session) in this folder")
            }
            return try Self.codexTranscript(Self.lines(of: file))
        }
    }

    // MARK: Claude Code

    /// Claude Code keeps a folder's conversations in `projects/<path>`, with
    /// every character but letters and digits turned into `-`, shortened when long.
    static func claudeFolderName(_ path: String) -> String {
        String(path.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    private func claudeFiles(_ cwds: CwdMatcher) -> [URL] {
        let projects = claude.appendingPathComponent("projects", isDirectory: true)
        let names = Set([cwds.directory, cwds.canonical].map(Self.claudeFolderName))
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        var files: [URL] = []
        for folder in folders where names.contains(where: { name in
            folder == name || (name.count > 200 && folder.hasPrefix(name.prefix(200)))
        }) {
            let url = projects.appendingPathComponent(folder, isDirectory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            files += contents.filter { $0.pathExtension == "jsonl" }
        }
        return files
    }

    private func claudeEntries(_ cwds: inout CwdMatcher, excluding: Set<String>) -> [AgentHistoryEntry] {
        var entries: [AgentHistoryEntry] = []
        for file in claudeFiles(cwds).prefix(Self.maxListedFiles) {
            let id = file.deletingPathExtension().lastPathComponent
            guard !excluding.contains(id), (try? AgentHistoryEntry.validate(providerSession: id)) != nil,
                  let size = Self.size(of: file) else { continue }
            var cwd: String?
            var prompt: String?
            var customTitle: String?
            var aiTitle: String?
            func read(_ record: [String: Any]) {
                switch record["type"] as? String {
                case "custom-title": customTitle = (record["customTitle"] as? String) ?? customTitle
                case "ai-title": aiTitle = (record["aiTitle"] as? String) ?? aiTitle
                case "summary": aiTitle = aiTitle ?? record["summary"] as? String
                case "user", "assistant":
                    cwd = cwd ?? record["cwd"] as? String
                    guard prompt == nil, record["type"] as? String == "user", record["isSidechain"] as? Bool != true,
                          record["isMeta"] as? Bool != true else { return }
                    prompt = Self.claudeUserText((record["message"] as? [String: Any])?["content"])
                default: return
                }
            }
            let start = Self.head(of: file, size: size, until: { cwd != nil && prompt != nil }) { $0.forEach(read) }
            if size > start { Self.lines(tail: Self.tail(of: file, bytes: Self.tailBytes)).forEach(read) }
            guard cwds.matches(cwd), let title = customTitle ?? aiTitle ?? prompt else { continue }
            entries.append(AgentHistoryEntry(provider: .claude, providerSession: id, title: Self.title(title),
                                             updatedAt: Self.modified(file)))
        }
        return entries
    }

    /// What the person typed, without the context Claude Code adds to a prompt.
    static func claudeUserText(_ content: Any?) -> String? {
        if let text = content as? String { return prompt(text) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? prompt($0["text"] as? String ?? "") : nil }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    static func claudeTranscript(_ records: some Sequence<[String: Any]>) -> AgentHistoryTranscript {
        var transcript = AgentHistoryTranscript()
        var ids = Set<String>()
        var tools: [String: Int] = [:]
        var lastMessage: String?
        func append(_ item: AgentChatItem) {
            guard ids.insert(item.id).inserted else { return }
            transcript.items.append(item)
        }
        for (index, record) in records.enumerated() {
            guard let type = record["type"] as? String, type == "user" || type == "assistant",
                  record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
                  let message = record["message"] as? [String: Any] else { continue }
            let id = record["uuid"] as? String ?? "claude-\(index)"
            let date = agentToolObservedDate(record["timestamp"])
            if type == "user" {
                lastMessage = nil
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                    guard let toolID = block["tool_use_id"] as? String, let at = tools[toolID] else { continue }
                    transcript.items[at].tool?.output = agentToolOutput(block["content"])
                    transcript.items[at].tool?.status = block["is_error"] as? Bool == true ? .failed : .completed
                    transcript.items[at].tool?.completedAt = date
                }
                guard let text = claudeUserText(message["content"]) else { continue }
                let interrupted = text.hasPrefix("[Request interrupted by user")
                append(AgentChatItem(id: id, kind: interrupted ? .notice : .user, text: interrupted ? "Agent interrupted." : text,
                                     createdAt: date, updatedAt: date))
                continue
            }
            guard message["model"] as? String != "<synthetic>" else { continue }
            if let model = message["model"] as? String, !model.isEmpty { transcript.resolvedModel = model }
            let messageID = message["id"] as? String ?? id
            for (offset, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    if lastMessage == messageID, let last = transcript.items.indices.last, transcript.items[last].kind == .assistant {
                        transcript.items[last].text += "\n\n" + text
                    } else {
                        append(AgentChatItem(id: "\(id):\(offset)", kind: .assistant, text: text, createdAt: date, updatedAt: date))
                    }
                    lastMessage = messageID
                case "tool_use":
                    guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = agentRuntimeJSON(block["input"])
                    var activity = agentToolActivity(name: name, input: input)
                    activity.status = .completed
                    activity.startedAt = date
                    append(AgentChatItem(id: toolID, kind: .tool, text: name, detail: input, tool: activity,
                                         createdAt: date, updatedAt: date))
                    if transcript.items.last?.id == toolID { tools[toolID] = transcript.items.count - 1 }
                    lastMessage = nil
                default: continue
                }
            }
        }
        return transcript
    }

    // MARK: Codex

    private struct CodexFile {
        var url: URL
        var modified: Date
    }

    /// Codex keeps every conversation in `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`.
    private func codexFiles() -> [CodexFile] {
        let root = codex.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
            return []
        }
        var files: [CodexFile] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL, visited < Self.maxEnumeratedFiles {
            visited += 1
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
            files.append(CodexFile(url: url, modified: Self.modified(url)))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    private struct CodexMeta {
        var id: String
        var cwd: String?
        /// Subagents a conversation started have their own files.
        var subagent: Bool
    }

    private static func codexMeta(_ records: some Sequence<[String: Any]>) -> CodexMeta? {
        guard let meta = records.first(where: { $0["type"] as? String == "session_meta" })?["payload"] as? [String: Any],
              let id = meta["id"] as? String else { return nil }
        let source = meta["source"]
        return CodexMeta(id: id, cwd: meta["cwd"] as? String, subagent: source != nil && !(source is String))
    }

    private func codexEntries(_ cwds: inout CwdMatcher, excluding: Set<String>) -> [AgentHistoryEntry] {
        var names: [String: String] = [:]
        let index = codex.appendingPathComponent("session_index.jsonl")
        if (Self.size(of: index) ?? .max) <= 16 << 20 {
            for record in Self.lines(Self.head(of: index, bytes: 16 << 20), whole: true) {
                if let id = record["id"] as? String, let name = record["thread_name"] as? String, !name.isEmpty { names[id] = name }
            }
        }
        var entries: [AgentHistoryEntry] = []
        for file in codexFiles().prefix(Self.maxListedFiles) {
            var meta: CodexMeta?
            var prompt: String?
            let size = Self.size(of: file.url) ?? .max
            Self.head(of: file.url, size: size, until: {
                meta.map { $0.subagent || !cwds.matches($0.cwd) || names[$0.id] != nil || prompt != nil } ?? false
            }) { records in
                meta = nil
                for record in records {
                    if meta == nil { meta = Self.codexMeta([record]) }
                    guard prompt == nil, record["type"] as? String == "response_item",
                          let payload = record["payload"] as? [String: Any], payload["type"] as? String == "message",
                          payload["role"] as? String == "user" else { continue }
                    prompt = Self.codexText(payload)
                }
            }
            guard let meta, !meta.subagent, cwds.matches(meta.cwd), !excluding.contains(meta.id),
                  (try? AgentHistoryEntry.validate(providerSession: meta.id)) != nil,
                  let title = names[meta.id] ?? prompt else { continue }
            entries.append(AgentHistoryEntry(provider: .codex, providerSession: meta.id, title: Self.title(title),
                                             updatedAt: file.modified))
        }
        return entries
    }

    private static func codexText(_ message: [String: Any]) -> String? {
        let texts = (message["content"] as? [[String: Any]] ?? []).compactMap { block -> String? in
            guard let text = block["text"] as? String else { return nil }
            return message["role"] as? String == "user" ? prompt(text) : text
        }
        let text = texts.joined(separator: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    static func codexTranscript(_ records: some Sequence<[String: Any]>) -> AgentHistoryTranscript {
        var transcript = AgentHistoryTranscript()
        var ids = Set<String>()
        var tools: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            let date = agentToolObservedDate(record["timestamp"])
            guard let payload = record["payload"] as? [String: Any] else { continue }
            if record["type"] as? String == "turn_context", let model = payload["model"] as? String, !model.isEmpty {
                transcript.resolvedModel = model
            }
            guard record["type"] as? String == "response_item" else { continue }
            let id = payload["id"] as? String ?? payload["call_id"] as? String ?? "codex-\(index)"
            func append(_ item: AgentChatItem) {
                guard ids.insert(item.id).inserted else { return }
                transcript.items.append(item)
            }
            switch payload["type"] as? String {
            case "message":
                let role = payload["role"] as? String
                guard role == "user" || role == "assistant", let text = codexText(payload) else { continue }
                append(AgentChatItem(id: id, kind: role == "user" ? .user : .assistant, text: text, createdAt: date, updatedAt: date))
            case "function_call", "custom_tool_call", "local_shell_call", "web_search_call":
                let type = payload["type"] as? String
                let name = payload["name"] as? String ?? (type == "web_search_call" ? "web_search" : "shell")
                let input = payload["arguments"] as? String ?? payload["input"] as? String
                    ?? agentRuntimeJSON(payload["action"])
                let category = AgentToolActivity.category(for: name)
                let activity = AgentToolActivity(name: name, category: category, input: input, status: .completed,
                                                 startedAt: date, presentation: category == .command ? .command : nil)
                append(AgentChatItem(id: id, kind: .tool, text: name, detail: input, tool: activity, createdAt: date, updatedAt: date))
                if let call = payload["call_id"] as? String, transcript.items.last?.id == id {
                    tools[call] = transcript.items.count - 1
                }
            case "function_call_output", "custom_tool_call_output":
                guard let call = payload["call_id"] as? String, let at = tools[call] else { continue }
                transcript.items[at].tool?.output = agentToolOutput(payload["output"])
                transcript.items[at].tool?.completedAt = date
            default: continue
            }
        }
        return transcript
    }

    // MARK: Shared

    /// Text the person wrote; `nil` for context a CLI wrapped in tags of its own,
    /// such as `<environment_context>…</environment_context>`. Claude Code's
    /// slash commands read as typed.
    static func prompt(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let name = tagged("command-name", in: text) {
            let arguments = tagged("command-args", in: text) ?? ""
            return arguments.isEmpty ? name : name + " " + arguments
        }
        if text.hasPrefix("# AGENTS.md instructions") { return nil }
        return isWrapped(text) ? nil : text
    }

    /// Whether `text` opens with a tag like `<name>` and closes with one like `</name>`.
    private static func isWrapped(_ text: String) -> Bool {
        func tagName(_ name: Substring) -> Bool {
            guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
            return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
        }
        guard text.hasPrefix("<"), text.hasSuffix(">"), let close = text.range(of: "</", options: .backwards) else { return false }
        let opening = text.dropFirst().prefix { $0 != ">" && $0 != " " }
        return tagName(opening) && tagName(text[close.upperBound...].dropLast())
    }

    private static func tagged(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        var title = line.trimmingCharacters(in: .whitespaces)
        while title.utf8.count > AgentHistoryReply.maxTitleBytes { title.removeLast() }
        return title
    }

    /// Compares folders as the CLIs recorded them with the project's, following links once per path.
    private struct CwdMatcher {
        let directory: String
        let canonical: String
        private var seen: [String: Bool] = [:]

        init(_ directory: String) {
            self.directory = directory
            canonical = Catalog.canonical(directory)
        }

        mutating func matches(_ cwd: String?) -> Bool {
            guard let cwd else { return false }
            if cwd == directory || cwd == canonical { return true }
            if let known = seen[cwd] { return known }
            let same = Catalog.canonical(cwd) == canonical
            seen[cwd] = same
            return same
        }
    }

    private static func size(of file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
    }

    private static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Reads the start of `file`, `size` bytes long, a little first and more
    /// unless `done`. Returns how much it read.
    @discardableResult
    private static func head(of file: URL, size: Int, until done: () -> Bool, _ read: (JSONLines) -> Void) -> Int {
        var bytes = shortHeadBytes
        while true {
            read(lines(head(of: file, bytes: bytes), whole: size <= bytes))
            if done() || size <= bytes || bytes >= headBytes { return min(size, bytes) }
            bytes = headBytes
        }
    }

    private static func head(of file: URL, bytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: bytes)) ?? Data()
    }

    private static func tail(of file: URL, bytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file), let end = try? handle.seekToEnd() else { return Data() }
        defer { try? handle.close() }
        try? handle.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return (try? handle.readToEnd()) ?? Data()
    }

    private static func lines(of file: URL) throws -> JSONLines {
        guard (size(of: file) ?? 0) <= maxTranscriptBytes else {
            throw ServiceError(.badRequest, "This conversation is too large to open in Tab")
        }
        return lines(try Data(contentsOf: file, options: .alwaysMapped), whole: true)
    }

    /// JSON objects, one per line. Unless `whole`, the last line may be cut off and is dropped.
    static func lines(_ data: Data, whole: Bool) -> JSONLines {
        JSONLines(data: data, whole: whole)
    }

    /// The same for the end of a file, whose first line may be cut off.
    private static func lines(tail data: Data) -> JSONLines {
        guard let newline = data.firstIndex(of: 0x0A) else { return JSONLines(data: Data(), whole: true) }
        return lines(data[data.index(after: newline)...], whole: true)
    }

    /// Parses lines as they are read, so a long transcript is never held twice.
    struct JSONLines: Sequence, IteratorProtocol {
        let data: Data
        let whole: Bool
        private var start: Data.Index

        init(data: Data, whole: Bool) {
            self.data = data
            self.whole = whole
            start = data.startIndex
        }

        mutating func next() -> [String: Any]? {
            while start < data.endIndex {
                let end = data[start...].firstIndex(of: 0x0A)
                guard end != nil || whole else { start = data.endIndex; break }
                let line = data[start..<(end ?? data.endIndex)]
                start = end.map { data.index(after: $0) } ?? data.endIndex
                if let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return record }
            }
            return nil
        }
    }
}
