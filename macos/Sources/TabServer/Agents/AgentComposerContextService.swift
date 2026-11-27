import Darwin
import Foundation
import TabProtocol

/// Discovers only known provider skill roots on the server, including remote servers.
actor AgentComposerContextService {
    private let home: URL
    private let environment: [String: String]
    var discoverProvider: (@Sendable (AgentChatProvider, String) async -> AgentCommandDiscovery.Result)?
    private var pending: [AgentComposerContextRequest: Task<AgentCommandDiscovery.Result, Never>] = [:]
    private var cached: [AgentComposerContextRequest: (Date, AgentComposerContextReply)] = [:]
    private let projectDirectory: @Sendable (ProjectId) throws -> URL
    private static let maxEntries = 2048
    private static let maxDepth = 8

    init(home: URL, environment: [String: String] = AgentProcess.environment(),
         discoverProvider: (@Sendable (AgentChatProvider, String) async -> AgentCommandDiscovery.Result)? = nil, projectDirectory: @escaping @Sendable (ProjectId) throws -> URL) {
        self.home = home
        self.environment = environment
        self.discoverProvider = discoverProvider
        self.projectDirectory = projectDirectory
    }

    func catalog(_ request: AgentComposerContextRequest) async throws -> AgentComposerContextReply {
        var key = request
        key.forceRefresh = nil
        if request.forceRefresh != true, let cached = cached[key], Date().timeIntervalSince(cached.0) < 30 { return cached.1 }
        var reply = try handle(request)
        if let discoverProvider {
            let directory = try projectDirectory(request.project).path
            let task = pending[key] ?? Task { await discoverProvider(request.provider, directory) }
            pending[key] = task
            let native = await task.value
            pending[key] = nil
            reply.commands = native.available ? native.commands : nil
            reply.truncated = reply.truncated || native.truncated
            reply.skills.removeAll { native.disabledSkills.contains($0.name) }
            if !native.available { reply.discoveryNotice = "Provider discovery is unavailable. Showing local skills and built-in commands; retry /skills to refresh." }
            var names = Set(reply.skills.map { $0.name.lowercased() })
            for item in native.skills where !names.contains(item.name.lowercased()) {
                let reported = URL(fileURLWithPath: item.path)
                guard item.path.hasPrefix("/"), let parent = canonicalAnchor(reported.deletingLastPathComponent()) else {
                    reply.truncated = true; continue
                }
                let file = parent.appendingPathComponent(reported.lastPathComponent)
                guard let instructions = readRegularFile(file, anchor: parent),
                      !["false", "no", "off", "0"].contains(frontmatter(instructions)["user-invocable"]?.lowercased() ?? "") else {
                    reply.truncated = true; continue
                }
                let skill = AgentComposerSkill(id: item.path, name: item.name, description: String(item.description.prefix(512)),
                    path: ServerPath(item.path), instructions: instructions)
                var candidate = reply; candidate.skills.append(skill)
                guard (try? candidate.validate()) != nil else { reply.truncated = true; continue }
                reply = candidate; names.insert(item.name.lowercased())
            }
        }
        cached[key] = (Date(), reply)
        return reply
    }

    func setDiscovery(_ discovery: @escaping @Sendable (AgentChatProvider, String) async -> AgentCommandDiscovery.Result) {
        discoverProvider = discovery
    }

    func handle(_ request: AgentComposerContextRequest) throws -> AgentComposerContextReply {
        let project = try projectDirectory(request.project)
        var ancestors = [project]
        var parent = project.deletingLastPathComponent()
        while parent.path != "/", ancestors.count < 32 {
            ancestors.append(parent)
            parent.deleteLastPathComponent()
        }
        var roots: [(URL, String, Bool)] = []
        switch request.provider {
        case .claude:
            roots = ancestors.flatMap { [($0, ".claude/skills", false), ($0, ".claude/commands", true)] }
            if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
                roots += [(URL(fileURLWithPath: configured), "skills", false), (URL(fileURLWithPath: configured), "commands", true)]
            } else { roots += [(home, ".claude/skills", false), (home, ".claude/commands", true)] }
        case .codex:
            roots = ancestors.map { ($0, ".agents/skills", false) } + [(home, ".agents/skills", false)]
            if let configured = environment["CODEX_HOME"], !configured.isEmpty {
                roots.append((URL(fileURLWithPath: configured), "skills", false))
            } else { roots.append((home, ".codex/skills", false)) }
        case .antigravity:
            // Project skills, then the user's own, as `agy` reads them.
            roots = ancestors.flatMap { [($0, ".gemini/skills", false), ($0, ".agents/skills", false), ($0, ".agent/skills", false)] }
            roots += [(home, ".gemini/config/skills", false), (home, ".gemini/antigravity-cli/skills", false)]
        case .gemini:
            roots = ancestors.flatMap { [($0, ".gemini/skills", false), ($0, ".agents/skills", false)] }
            let root = environment["GEMINI_CLI_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home
            roots += [(root, ".gemini/skills", false), (home, ".agents/skills", false)]
        case .openCode:
            roots = ancestors.flatMap { [($0, ".opencode/skills", false), ($0, ".agents/skills", false)] }
            if let configured = environment["OPENCODE_CONFIG_DIR"], !configured.isEmpty {
                roots.append((URL(fileURLWithPath: configured), "skills", false))
            } else { roots.append((home, ".config/opencode/skills", false)) }
            roots.append((home, ".agents/skills", false))
        case .grok, .kiro, .acp:
            roots = ancestors.map { ($0, ".agents/skills", false) } + [(home, ".agents/skills", false)]
        }
        var reply = AgentComposerContextReply(skills: [])
        var names = Set<String>()
        var bytes = 0
        var visited = 0
        for (anchor, relative, commands) in roots {
            guard let root = safeRoot(anchor: anchor, relative: relative),
                  let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
                    options: [], errorHandler: { _, _ in false }) else { continue }
            var candidates: [URL] = []
            while let file = enumerator.nextObject() as? URL {
                visited += 1
                guard visited <= Self.maxEntries else { reply.truncated = true; break }
                guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey,
                                                                     .isDirectoryKey]),
                      values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                let depth = file.pathComponents.count - root.pathComponents.count
                if values.isDirectory == true {
                    if depth >= Self.maxDepth { enumerator.skipDescendants(); reply.truncated = true }
                    continue
                }
                guard values.isRegularFile == true,
                      commands ? file.pathExtension == "md" : file.lastPathComponent == "SKILL.md" else { continue }
                candidates.append(file)
            }
            // Stable precedence within a root; project roots always precede global roots.
            for file in candidates.sorted(by: { $0.path < $1.path }) {
                guard let text = readRegularFile(file, anchor: anchor) else { reply.truncated = true; continue }
                let metadata = frontmatter(text)
                if ["false", "no", "off", "0"].contains(metadata["user-invocable"]?.lowercased() ?? "") {
                    continue
                }
                let fallback = commands ? file.deletingPathExtension().lastPathComponent
                    : file.deletingLastPathComponent().lastPathComponent
                let name = metadata["name"] ?? fallback
                let skill = AgentComposerSkill(id: file.path, name: name,
                    description: String((metadata["description"] ?? "").prefix(512)),
                    path: ServerPath(file.path), instructions: text)
                // Invalid names cannot be represented by the visible /skill:name token.
                guard (try? AgentComposerContextReply(skills: [skill]).validate()) != nil else { continue }
                let key = name.lowercased()
                guard !names.contains(key) else { continue }
                let size = skill.id.utf8.count + skill.name.utf8.count + skill.description.utf8.count
                    + skill.path.byteCount + skill.instructions.utf8.count
                guard reply.skills.count < AgentComposerContextReply.maxSkills,
                      bytes + size <= AgentComposerContextReply.maxCatalogBytes else {
                    reply.truncated = true
                    continue
                }
                names.insert(key)
                bytes += size
                reply.skills.append(skill)
            }
            if visited > Self.maxEntries { break }
        }
        try reply.validate()
        return reply
    }

    /// Reject symlinks in configuration roots, not just the final SKILL.md file.
    private func safeRoot(anchor: URL, relative: String) -> URL? {
        guard var url = canonicalAnchor(anchor) else { return nil }
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component))
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  values.isSymbolicLink != true, values.isDirectory == true else { return nil }
        }
        return url
    }

    /// Foundation can shorten /private/var to /var when resolving URLs, while
    /// its directory enumerator returns /private/var paths. Use the filesystem's
    /// canonical spelling consistently for both containment and depth checks.
    private func canonicalAnchor(_ url: URL) -> URL? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    /// No pipes/simulators, no final symlinks, and never allocate an unbounded file.
    private func readRegularFile(_ url: URL, anchor: URL) -> String? {
        guard let base = canonicalAnchor(anchor) else { return nil }
        let components = Array(url.pathComponents.dropFirst(base.pathComponents.count))
        guard url.pathComponents.starts(with: base.pathComponents), !components.isEmpty else { return nil }
        var directory = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(directory)
            directory = next
        }
        let fd = openat(directory, components[components.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        let limit = AgentComposerContextReply.maxInstructionBytes
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= limit else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let remaining = min(buffer.count, limit + 1 - data.count)
            let count = Darwin.read(fd, &buffer, remaining)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deliberately a small frontmatter subset: scalars and folded/literal descriptions.
    private func frontmatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var result: [String: String] = [:]
        var multiline: String?
        for line in lines[1..<end] {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let key = multiline {
                    result[key, default: ""] += (result[key, default: ""].isEmpty ? "" : " ")
                        + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            multiline = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard ["name", "description", "user-invocable"].contains(key) else { continue }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                multiline = key
                result[key] = ""
                continue
            }
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { result[key] = value }
        }
        return result
    }
}
