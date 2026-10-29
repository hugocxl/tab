import Darwin
import Foundation
import TabProtocol

/// Saved agent conversations found in the harnesses' own JSONL transcripts
/// on this Mac. Discovery only reads files: it never writes, installs hooks
/// or launches a harness.
public enum AgentSessionProviders {
    /// Every provider, in the order the filter menu lists them.
    public static let all: [AgentProvider] = [
        .claude, .codex, .copilot, .droid, .pi, .ohMyPi, .xal, .openCode, .cursor, .grok, .kiro, .antigravity,
    ]

    /// Whether the provider's transcripts can be read. The others keep their
    /// history in databases or unverified formats and show "Not supported".
    public static func isSupported(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .claude, .codex, .copilot, .droid, .pi, .ohMyPi, .xal: return true
        default: return false
        }
    }

    public static var supported: [AgentProvider] { all.filter(isSupported) }
}

/// One saved conversation.
public struct AgentSession: Hashable, Sendable {
    public var provider: AgentProvider
    public var id: String
    public var title: String
    /// The project folder the harness ran in, with symlinks resolved.
    public var directory: String
    /// The transcript.
    public var path: String
    public var modified: Date

    public init(provider: AgentProvider, id: String, title: String, directory: String, path: String, modified: Date) {
        self.provider = provider
        self.id = id
        self.title = title
        self.directory = directory
        self.path = path
        self.modified = modified
    }

    /// Whether every word of `query` is in the title, id or provider name,
    /// ignoring case.
    public func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            let word = word.lowercased()
            return title.lowercased().contains(word) || id.lowercased().contains(word)
                || provider.displayName.lowercased().contains(word)
        }
    }

    /// The harness command that resumes the session. Only the validated id
    /// goes in, never transcript text or paths.
    public var resumeCommand: String? {
        guard Self.isValidId(id) else { return nil }
        let command: String
        switch provider {
        case .claude: command = "claude --resume"
        case .codex: command = "codex resume"
        case .copilot: command = "copilot --resume"
        case .droid: command = "droid --resume"
        case .pi: command = "pi --session"
        case .ohMyPi: command = "omp --resume"
        case .xal: command = "xal resume"
        default: return nil
        }
        return "\(command) \(id)"
    }

    /// ASCII letters, digits, `-`, `_` and `.`, starting with a letter or
    /// digit, at most 200 bytes.
    static func isValidId(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard let first = bytes.first, bytes.count <= 200, isAlphanumeric(first) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".") }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// Where each provider keeps its transcripts, and how deep below that folder
/// they are.
public struct AgentSessionRoots: Hashable, Sendable {
    public struct Source: Hashable, Sendable {
        public var provider: AgentProvider
        public var root: String
        /// Folder levels to descend before transcripts.
        public var depth: Int
    }

    public var sources: [Source]

    public init(home: String) {
        func source(_ provider: AgentProvider, _ relative: String, _ depth: Int) -> Source {
            Source(provider: provider, root: (home as NSString).appendingPathComponent(relative), depth: depth)
        }
        sources = [
            source(.claude, ".claude/projects", 1),
            source(.codex, ".codex/sessions", 3),
            source(.copilot, ".copilot/session-state", 1),
            source(.droid, ".factory/sessions", 1),
            source(.pi, ".pi/agent/sessions", 1),
            source(.ohMyPi, ".omp/agent/sessions", 1),
            source(.xal, ".xal/sessions", 1),
        ]
    }

    /// The roots under the home folder, honoring absolute `CLAUDE_CONFIG_DIR`
    /// and `CODEX_HOME`; `nil` without a home folder.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentSessionRoots? {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        guard !home.isEmpty else { return nil }
        var roots = AgentSessionRoots(home: home)
        for index in roots.sources.indices {
            let override: String?
            switch roots.sources[index].provider {
            case .claude: override = environment["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).appendingPathComponent("projects") }
            case .codex: override = environment["CODEX_HOME"].map { ($0 as NSString).appendingPathComponent("sessions") }
            default: override = nil
            }
            if let override, override.hasPrefix("/") { roots.sources[index].root = override }
        }
        return roots
    }
}

/// What a scan found for the requested project folders.
public struct AgentSessionListing: Equatable, Sendable {
    /// Newest first, one per provider and id.
    public var sessions: [AgentSession] = []
    /// Providers whose folders or files could not be read.
    public var warnings: [(provider: AgentProvider, message: String)] = []
    /// A provider had more entries than a scan looks at.
    public var limited = false
    /// Some files were left for the next scan to keep this one bounded.
    public var pending = false

    public init() {}

    public static func == (lhs: AgentSessionListing, rhs: AgentSessionListing) -> Bool {
        lhs.sessions == rhs.sessions && lhs.limited == rhs.limited && lhs.pending == rhs.pending
            && lhs.warnings.map(\.provider) == rhs.warnings.map(\.provider)
            && lhs.warnings.map(\.message) == rhs.warnings.map(\.message)
    }
}

/// Session metadata by transcript, reused while a file's modification time
/// and length are unchanged. Not thread-safe: scan it on one queue at a time.
public struct AgentSessionCatalog: Sendable {
    static let maxEntries = 20_000
    /// Bytes read per provider per scan; files beyond it wait for the next.
    static let providerReadBytes: UInt64 = 8 * 1024 * 1024

    private struct Cached: Sendable {
        var provider: AgentProvider
        var modified: Date
        var length: UInt64
        var session: AgentSession?
    }

    private var files: [String: Cached] = [:]

    public init() {}

    /// The sessions of one project folder.
    public mutating func scan(_ roots: AgentSessionRoots, project: String) -> AgentSessionListing {
        scan(roots, projects: [project])
    }

    /// Scans the transcripts once for several folders, such as a project and
    /// its worktrees.
    public mutating func scan(_ roots: AgentSessionRoots, projects: [String]) -> AgentSessionListing {
        let projects = Set(projects.map(AgentSessionParser.normalized))
        var listing = AgentSessionListing()
        var seen = Set<String>()
        for source in roots.sources {
            let provider = source.provider
            var readBudget = Self.providerReadBytes
            var paths: [String] = []
            var budget = Self.maxEntries
            do {
                try Self.discover(source.root, depth: source.depth, budget: &budget, paths: &paths)
            } catch {
                listing.warnings.append((provider, error.localizedDescription))
            }
            if budget == 0 { listing.limited = true }
            for path in paths {
                var info = stat()
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                let length = UInt64(max(info.st_size, 0))
                seen.insert(path)
                let cached = files[path].map { $0.provider == provider && $0.modified == modified && $0.length == length } ?? false
                if !cached && readBudget < AgentSessionParser.readLimit(length) {
                    listing.pending = true
                } else if !cached {
                    do {
                        let session = try AgentSessionParser.read(path: path, provider: provider, modified: modified, budget: &readBudget)
                        files[path] = Cached(provider: provider, modified: modified, length: length, session: session)
                    } catch {
                        files[path] = nil
                        if !listing.warnings.contains(where: { $0.provider == provider }) {
                            listing.warnings.append((provider, error.localizedDescription))
                        }
                    }
                }
                if let entry = files[path], entry.provider == provider, let session = entry.session,
                   projects.contains(session.directory)
                {
                    listing.sessions.append(session)
                }
            }
        }
        files = files.filter { seen.contains($0.key) }
        listing.sessions.sort { a, b in
            a.modified != b.modified ? a.modified > b.modified : a.path < b.path
        }
        var identities = Set<String>()
        listing.sessions = listing.sessions.filter { identities.insert("\($0.provider.rawValue)\u{0}\($0.id)").inserted }
        return listing
    }

    private static func discover(_ path: String, depth: Int, budget: inout Int, paths: inout [String]) throws {
        guard let directory = opendir(path) else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(directory) }
        var directories: [String] = []
        while budget > 0, let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            budget -= 1
            let child = (path as NSString).appendingPathComponent(name)
            var type = Int32(entry.pointee.d_type)
            if type == DT_UNKNOWN {
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                type = (info.st_mode & S_IFMT) == S_IFDIR ? DT_DIR : ((info.st_mode & S_IFMT) == S_IFREG ? DT_REG : DT_UNKNOWN)
            }
            if type == DT_DIR && depth > 0 {
                directories.append(child)
            } else if type == DT_REG && (name as NSString).pathExtension == "jsonl" {
                paths.append(child)
            }
        }
        directories.sort()
        for child in directories {
            guard budget > 0 else { break }
            try discover(child, depth: depth - 1, budget: &budget, paths: &paths)
        }
    }
}

/// Reads a transcript's identity, folder and title from its first megabyte
/// and its last 64 KiB.
enum AgentSessionParser {
    static let prefixBytes: UInt64 = 1024 * 1024
    static let tailBytes: UInt64 = 64 * 1024

    static func readLimit(_ length: UInt64) -> UInt64 {
        min(length, prefixBytes + tailBytes)
    }

    /// `path` with symlinks resolved, or as given when it does not exist.
    static func normalized(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The session in `path`, or `nil` for a transcript without an id, an
    /// absolute folder, or one that belongs to a subagent. Reading stops
    /// once `budget` bytes are spent.
    static func read(path: String, provider: AgentProvider, modified: Date, budget: inout UInt64) throws -> AgentSession? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let length = UInt64(max(info.st_size, 0))
        var metadata = Metadata()

        let prefix = try handle.read(upToCount: Int(min(prefixBytes, budget))) ?? Data()
        var consumed: UInt64 = 0
        forEachLine(prefix) { line, complete in
            consumed += UInt64(line.count)
            budget = budget > UInt64(line.count) ? budget - UInt64(line.count) : 0
            if complete, let value = JSON.parse(line) { metadata.visit(provider, value, tail: false) }
        }
        if length > consumed {
            let start = max(consumed, length > tailBytes ? length - tailBytes : 0)
            try handle.seek(toOffset: start)
            let tail = try handle.read(upToCount: Int(min(tailBytes, budget))) ?? Data()
            var skipFirst = start > consumed
            forEachLine(tail) { line, complete in
                budget = budget > UInt64(line.count) ? budget - UInt64(line.count) : 0
                if skipFirst {
                    skipFirst = false
                    return
                }
                if complete, let value = JSON.parse(line) { metadata.visit(provider, value, tail: true) }
            }
        }
        guard let id = metadata.id, AgentSession.isValidId(id) else { return nil }
        guard let directory = metadata.directory, directory.hasPrefix("/") else { return nil }
        guard !metadata.child else { return nil }
        return AgentSession(
            provider: provider,
            id: id,
            title: metadata.title ?? metadata.prompt ?? id,
            directory: normalized(directory),
            path: path,
            modified: modified
        )
    }

    /// Calls `body` with each line including its `\n`, and whether it had one.
    private static func forEachLine(_ data: Data, _ body: (Data, Bool) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            if let newline = data[start...].firstIndex(of: 0x0A) {
                body(data[start...newline], true)
                start = data.index(after: newline)
            } else {
                body(data[start...], false)
                return
            }
        }
    }

    private struct Metadata {
        var id: String?
        var directory: String?
        var title: String?
        var prompt: String?
        var child = false

        mutating func identity(_ value: JSON, id idKey: String, cwd: String) {
            if id == nil { id = value[idKey].string }
            if directory == nil { directory = value[cwd].string }
        }

        /// Slash commands and harness notes are stored as tagged markup; the
        /// first prompt a person actually typed makes the title.
        mutating func prompt(_ value: JSON) {
            guard prompt == nil else { return }
            prompt = text(value).flatMap { $0.hasPrefix("<") ? nil : $0 }
        }

        mutating func visit(_ provider: AgentProvider, _ value: JSON, tail: Bool) {
            let kind = value["type"].string ?? ""
            switch provider {
            case .claude:
                if !tail && (kind == "user" || kind == "assistant") {
                    identity(value, id: "sessionId", cwd: "cwd")
                    if value["isSidechain"].isTrue { child = true }
                }
                if kind == "custom-title" {
                    title = text(value["customTitle"])
                } else if kind == "summary" && title == nil {
                    title = text(value["summary"])
                } else if !tail && kind == "user" && !value["isMeta"].isTrue {
                    prompt(value["message"]["content"])
                }
            case .codex:
                let payload = value["payload"]
                if !tail && kind == "session_meta" {
                    identity(payload, id: "id", cwd: "cwd")
                    if payload["source"].has("subagent") { child = true }
                } else if !tail && kind == "event_msg" && payload["type"].string == "user_message" {
                    prompt(payload["message"])
                }
            case .pi, .ohMyPi, .droid:
                if !tail && (kind == "session" || kind == "session_start") {
                    identity(value, id: "id", cwd: "cwd")
                    if title == nil { title = text(value["title"]) }
                } else if kind == "session_info" || kind == "title" || kind == "title_change" {
                    title = text(value["title"]) ?? text(value["name"])
                } else if !tail && kind == "message" && value["message"]["role"].string == "user" {
                    prompt(value["message"]["content"])
                }
            case .copilot:
                let data = value["data"]
                if !tail && kind == "session.start" {
                    id = data["sessionId"].string
                    directory = data["context"]["cwd"].string
                } else if kind == "session.title_changed" {
                    title = text(data["title"])
                } else if !tail && kind == "user.message" && !value.has("agentId") {
                    prompt(data["content"])
                }
            case .xal:
                if !tail && kind == "meta" {
                    identity(value["meta"], id: "id", cwd: "cwd")
                } else if kind == "event" && value["event"]["type"].string == "session_title_changed" {
                    title = text(value["event"]["title"])
                } else if !tail {
                    for key in ["item", "event"] where value[key]["type"].string == "user_message" {
                        prompt(value[key]["text"])
                    }
                }
            default:
                break
            }
        }
    }

    /// A title from a string (its first 240 characters, controls as spaces,
    /// trimmed) or the first text part of a content array.
    static func text(_ value: JSON) -> String? {
        if let string = value.string {
            var scalars = String.UnicodeScalarView()
            for scalar in string.unicodeScalars.prefix(240) {
                scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
            }
            let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let parts = value.array else { return nil }
        for part in parts {
            let type = part["type"].string
            guard type == "text" || type == "input_text" else { continue }
            if let text = text(part["text"]) { return text }
        }
        return nil
    }
}

/// A parsed JSON value that, like serde's `Value`, answers `nil` for any
/// missing key or index instead of failing.
struct JSON {
    let raw: Any?

    static func parse(_ data: Data) -> JSON? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(raw: value)
    }

    subscript(key: String) -> JSON { JSON(raw: (raw as? [String: Any])?[key]) }

    func has(_ key: String) -> Bool { (raw as? [String: Any])?[key] != nil }

    var string: String? { raw as? String }

    var array: [JSON]? { (raw as? [Any]).map { $0.map { JSON(raw: $0) } } }

    /// A JSON `true`, not a number that bridges to one.
    var isTrue: Bool {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}
