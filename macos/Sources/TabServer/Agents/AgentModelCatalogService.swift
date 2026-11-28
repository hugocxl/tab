import Darwin
import Foundation
import TabCore
import TabProtocol

/// Discovery never starts a thread or conversation, and reads only the active model cache.
actor AgentModelCatalogService {
    private let home: URL
    private let environment: [String: String]
    private let projectDirectory: @Sendable (ProjectId) throws -> URL
    private let launch: AgentProcess.Launch?
    private let timeout: TimeInterval
    private let cacheDirectory: URL?
    private let now: @Sendable () -> Date
    private let providers: @Sendable (String?, AgentChatProvider) -> AgentProviderConfig
    private struct Key: Hashable, Sendable {
        var project: ProjectId
        /// The provider's ID; a built-in provider's is its kind's name.
        var provider: String
        var filename: String { "\(project.description)-\(provider).json" }
    }
    private struct Refresh: Sendable {
        var id = UUID()
        var task: Task<AgentModelCatalogReply, Never>
    }
    private var cached: [Key: (Date, AgentModelCatalogReply)] = [:]
    private var pending: [Key: Refresh] = [:]

    init(home: URL, environment: [String: String] = AgentProcess.environment(),
         launch: AgentProcess.Launch? = nil, timeout: TimeInterval = AgentModelCatalogService.defaultTimeout,
         cacheDirectory: URL? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         providers: @escaping @Sendable (String?, AgentChatProvider) -> AgentProviderConfig = { _, kind in .builtIn(kind) },
         projectDirectory: @escaping @Sendable (ProjectId) throws -> URL) {
        self.home = home
        self.environment = environment
        self.launch = launch
        self.timeout = timeout
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.providers = providers
        self.projectDirectory = projectDirectory
    }

    /// How long a discovery holds before the next request starts the CLI again: a found
    /// catalog changes rarely, so every pane's menu reuses it for ten minutes; an empty one
    /// is retried sooner.
    static func freshness(_ reply: AgentModelCatalogReply) -> TimeInterval { reply.models.isEmpty ? 30 : 600 }

    /// Forgets every discovered catalog, as after the providers' settings change.
    func invalidate() {
        cached = [:]
    }

    /// The provider's models, arranged as the user chose in Settings: custom
    /// ones added, favorites first, hidden ones left out unless asked for.
    func handle(_ request: AgentModelCatalogRequest) async throws -> AgentModelCatalogReply {
        let config = providers(request.providerID, request.provider)
        guard config.enabled else { return AgentModelCatalogReply(models: [], source: "disabled") }
        var reply = try await discover(request, config: config)
        reply.models = Array((request.includeHidden ? config.models.arrange(reply.models) : config.models.visible(reply.models))
            .prefix(AgentModelCatalogReply.maxModels))
        return reply
    }

    private func discover(_ request: AgentModelCatalogRequest, config: AgentProviderConfig) async throws -> AgentModelCatalogReply {
        let directory = try projectDirectory(request.project)
        let provider = request.provider
        let key = Key(project: request.project, provider: config.id)
        let environment = AgentProviderLaunch.environment(config, base: self.environment)
        if !request.forceRefresh, let cached = cached[key], now().timeIntervalSince(cached.0) < Self.freshness(cached.1) { return cached.1 }
        if let pending = pending[key] {
            if !request.forceRefresh, let cached = cached[key], !cached.1.models.isEmpty { return cached.1 }
            return await completeRefresh(pending, key: key)
        }
        // Even an older CLI cache is more useful than blocking the menu on a stuck executable.
        let memory = cached[key]?.1
        let disk = memory.flatMap { $0.models.isEmpty ? nil : $0 }
            ?? (provider == .codex ? Self.readCache(home: home, environment: environment) : nil)
            ?? readPersisted(key: key)
        if let disk, !disk.models.isEmpty {
            if memory?.models.isEmpty != false { cached[key] = (now(), disk) }
            // A saved catalog may be another project's, so only fresher sources are written back.
            if disk.source != "saved" { persist(disk, key: key) }
            let modified = try? Self.cacheURL(home: home, environment: environment)
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if !request.forceRefresh, memory == nil, provider == .codex, disk.source == "cache", let modified,
               Date().timeIntervalSince(modified) < 300 { return disk }
        }
        var launchEnvironment = environment
        if provider == .claude { launchEnvironment.removeValue(forKey: "CLAUDECODE") }
        launchEnvironment.removeValue(forKey: "TAB_SESSION_ID")
        let override = launch
        let timeout = timeout
        let task = Task.detached { [launchEnvironment] () -> AgentModelCatalogReply in
            do {
                let arguments: [String]
                switch provider.spec.wire {
                case .codexAppServer:
                    try AgentProviderLaunch.prepareShadowHome(config)
                    arguments = ["app-server"] + AgentProviderLaunch.homeArguments(config)
                case .acp: arguments = AgentProviderLaunch.sessionArguments(config)
                case .claudeStream:
                    arguments = ["--print", "--verbose", "--input-format", "stream-json",
                        "--output-format", "stream-json", "--no-session-persistence", "--safe-mode",
                        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""]
                }
                var environment = launchEnvironment
                let scratch = AgentProviderLaunch.scratchDirectory(config)
                if let scratch { environment["TMPDIR"] = scratch.path }
                defer { AgentProviderLaunch.removeScratch(scratch, after: 5) }
                let launch = try override ?? AgentProcess.Launch(
                    executable: AgentProviderLaunch.executable(config, environment: environment),
                    arguments: arguments, environment: environment)
                if provider.spec.wire == .acp {
                    // Node CLIs such as Gemini load their settings before they answer.
                    return await AcpModelDiscovery.discover(launch: launch, directory: directory.path,
                                                            timeout: max(timeout, Self.acpTimeout), provider: provider,
                                                            hasKey: provider.spec.apiKeyVariables.contains { environment[$0]?.isEmpty == false })
                }
                return await AgentModelCatalogDiscovery.discover(provider: provider, launch: launch,
                    directory: directory.path, timeout: timeout)
            } catch { return .init(models: []) }
        }
        let refresh = Refresh(task: task)
        pending[key] = refresh
        if !request.forceRefresh, let disk, !disk.models.isEmpty {
            Task { _ = await completeRefresh(refresh, key: key) }
            return disk
        }
        return await completeRefresh(refresh, key: key)
    }

    private func completeRefresh(_ refresh: Refresh, key: Key) async -> AgentModelCatalogReply {
        let result = await refresh.task.value
        guard pending[key]?.id == refresh.id else { return cached[key]?.1 ?? result }
        pending[key] = nil
        let chosen = result.models.isEmpty ? cached[key]?.1 ?? result : result
        cached[key] = (now(), chosen)
        if !result.models.isEmpty { persist(result, key: key) }
        return chosen
    }

    private func persist(_ reply: AgentModelCatalogReply, key: Key) {
        guard !reply.models.isEmpty, let cacheDirectory,
              let data = try? WireJSON.encode(reply), data.count <= Self.maxCacheBytes else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheDirectory.appendingPathComponent(key.filename), options: .atomic)
    }

    /// The project's saved catalog or, for a project that has none yet (a new worktree), the
    /// provider's most recent one from another project: the live refresh that follows
    /// replaces it, so the menu never waits on a first discovery with nothing to show.
    private func readPersisted(key: Key) -> AgentModelCatalogReply? {
        guard let cacheDirectory else { return nil }
        if let reply = Self.readSaved(cacheDirectory.appendingPathComponent(key.filename)) { return reply }
        let suffix = "-\(key.provider).json"
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let others = files.filter {
            let name = $0.lastPathComponent
            return name.hasSuffix(suffix) && UUID(uuidString: String(name.dropLast(suffix.count))) != nil
        }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in others.prefix(8) { if let reply = Self.readSaved(file) { return reply } }
        return nil
    }

    private static func readSaved(_ url: URL) -> AgentModelCatalogReply? {
        guard let data = readBoundedFile(url),
              var reply = try? WireJSON.decode(AgentModelCatalogReply.self, from: data),
              (try? reply.validate()) != nil, !reply.models.isEmpty else { return nil }
        reply.source = "saved"
        return reply
    }

    static let maxCacheBytes = 4 * 1024 * 1024
    /// How long Claude Code or Codex may take to answer. They usually do in under a second,
    /// but not when many start at once, as when the app opens with several agent panes.
    static let defaultTimeout: TimeInterval = 15
    /// How long an ACP agent may take to start and open the session its models come from.
    static let acpTimeout: TimeInterval = 25

    private static func cacheURL(home: URL, environment: [String: String]) -> URL {
        let root = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return root.appendingPathComponent("models_cache.json")
    }

    static func readCache(home: URL, environment: [String: String]) -> AgentModelCatalogReply? {
        let url = cacheURL(home: home, environment: environment)
        guard let data = readBoundedFile(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        let sorted = models.enumerated().filter { $0.element["visibility"] as? String == "list" }
            .sorted {
                let a = $0.element["priority"] as? Int ?? Int.max
                let b = $1.element["priority"] as? Int ?? Int.max
                return a == b ? $0.offset < $1.offset : a < b
            }.map(\.element)
        return .init(models: descriptors(sorted, cache: true), source: "cache")
    }

    private static func readBoundedFile(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maxCacheBytes else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maxCacheBytes {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maxCacheBytes + 1 - data.count))
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data.count <= maxCacheBytes ? data : nil
    }

    static func descriptors(_ rows: [[String: Any]], cache: Bool) -> [AgentModelDescriptor] {
        var seen = Set<String>()
        var result: [AgentModelDescriptor] = []
        for row in rows {
            if !cache, row["hidden"] as? Bool == true { continue }
            guard let id = (cache ? row["slug"] : row["model"] ?? row["id"]) as? String else { continue }
            let levels = row[cache ? "supported_reasoning_levels" : "supportedReasoningEfforts"] as? [[String: Any]] ?? []
            var efforts: [AgentReasoningEffort] = []
            for level in levels {
                if let raw = (level["effort"] ?? level["reasoningEffort"]) as? String {
                    let effort = AgentReasoningEffort(rawValue: raw)
                    if (try? effort.validate()) != nil, !efforts.contains(effort) { efforts.append(effort) }
                }
            }
            let defaultRaw = row[cache ? "default_reasoning_level" : "defaultReasoningEffort"] as? String
            let model = AgentModelDescriptor(id: id,
                title: row[cache ? "display_name" : "displayName"] as? String ?? id,
                reasoningEfforts: efforts, defaultReasoningEffort: defaultRaw.map(AgentReasoningEffort.init(rawValue:)),
                isDefault: row[cache ? "is_default" : "isDefault"] as? Bool ?? false)
            guard (try? AgentModelCatalogReply(models: [model]).validate()) != nil,
                  seen.insert(id).inserted else { continue }
            result.append(model)
            if result.count == AgentModelCatalogReply.maxModels { break }
        }
        return result
    }

    /// Claude Code initialize response (2.1.308): models[].value is the selectable
    /// alias; supportedEffortLevels are capabilities, not a bundled model table.
    static func claudeDescriptors(_ rows: [[String: Any]]) -> [AgentModelDescriptor] {
        var result: [AgentModelDescriptor] = []
        var seen = Set<String>()
        let defaultModel = rows.first { $0["value"] as? String == "default" }?["resolvedModel"] as? String
        for row in rows {
            guard let id = row["value"] as? String, id != "default" else { continue }
            let rawEfforts = row["supportedEffortLevels"] as? [String] ?? []
            var efforts: [AgentReasoningEffort] = []
            if row["supportsEffort"] as? Bool != false {
                for raw in rawEfforts {
                    let effort = AgentReasoningEffort(rawValue: raw)
                    if (try? effort.validate()) != nil, !efforts.contains(effort) { efforts.append(effort) }
                }
            }
            let model = AgentModelDescriptor(id: id,
                title: claudeTitle(row["displayName"] as? String ?? id, resolvedModel: row["resolvedModel"] as? String),
                reasoningEfforts: efforts,
                defaultReasoningEffort: (row["defaultEffort"] as? String).map(AgentReasoningEffort.init(rawValue:)),
                resolvedModel: row["resolvedModel"] as? String,
                isDefault: row["isDefault"] as? Bool == true
                    || (defaultModel != nil && row["resolvedModel"] as? String == defaultModel))
            guard (try? AgentModelCatalogReply(models: [model]).validate()) != nil,
                  seen.insert(id).inserted else { continue }
            result.append(model)
            if result.count == AgentModelCatalogReply.maxModels { break }
        }
        return result
    }

    /// Claude Code names aliases by family only ("Opus"); add the version from the
    /// resolved ID ("claude-opus-5-5" → "Opus 5.5") so the menu says which model it is.
    static func claudeTitle(_ title: String, resolvedModel: String?) -> String {
        guard let resolvedModel else { return title }
        let parts = resolvedModel.split(separator: "-")
        guard parts.count >= 4, parts[0] == "claude", parts[1].lowercased() == title.lowercased(),
              parts[2].allSatisfy(\.isNumber), parts[3].allSatisfy(\.isNumber),
              parts[3].count <= 2 else { return title }
        return "\(title) \(parts[2]).\(parts[3])"
    }
}

/// One bounded, short-lived provider handshake. All mutable state lives on its queue.
private final class AgentModelCatalogDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tab.agent-model-catalog")
    private var process: AgentProcess?
    private var continuation: CheckedContinuation<AgentModelCatalogReply, Never>?
    private var requestID = 1
    private var rows: [[String: Any]] = []
    private var cursors = Set<String>()
    private var bytes = 0
    private var provider: AgentChatProvider = .codex

    static func discover(provider: AgentChatProvider, launch: AgentProcess.Launch, directory: String,
                         timeout: TimeInterval) async -> AgentModelCatalogReply {
        let discovery = AgentModelCatalogDiscovery()
        discovery.provider = provider
        return await withCheckedContinuation { continuation in
            discovery.queue.async {
                discovery.continuation = continuation
                discovery.queue.asyncAfter(deadline: .now() + timeout) { discovery.finish(success: false) }
                do {
                    discovery.process = try AgentProcess(launch: launch, directory: directory, onLine: { data in
                        discovery.queue.async { discovery.receive(data) }
                    }, onExit: { _, _ in
                        discovery.queue.async { discovery.finish(success: false) }
                    })
                    if provider == .codex {
                        try discovery.process?.write(["id": 1, "method": "initialize", "params": [
                            "clientInfo": ["name": "tab", "version": Release.version]]])
                    } else {
                        try discovery.process?.write(["type": "control_request", "request_id": "1",
                            "request": ["subtype": "initialize", "hooks": [:]]])
                    }
                } catch { discovery.finish(success: false) }
            }
        }
    }

    private func receive(_ data: Data) {
        guard continuation != nil else { return }
        bytes += data.count
        guard bytes <= AgentModelCatalogService.maxCacheBytes else { finish(success: false); return }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if provider == .claude {
            guard message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any],
                  response["request_id"] as? String == "1" else { return }
            guard response["subtype"] as? String == "success",
                  let body = response["response"] as? [String: Any],
                  let models = body["models"] as? [[String: Any]] else { finish(success: false); return }
            rows = models
            finish(success: true)
            return
        }
        guard
              let id = message["id"] as? Int, id == requestID else { return }
        guard let result = message["result"] as? [String: Any] else { finish(success: false); return }
        do {
            if id == 1 {
                try process?.write(["method": "initialized"])
                try list(cursor: nil)
            } else {
                guard let page = result["data"] as? [[String: Any]] else { finish(success: false); return }
                rows += page
                guard rows.count <= 4096 else { finish(success: false); return }
                if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                    guard cursors.count < 32, cursors.insert(cursor).inserted else { finish(success: false); return }
                    try list(cursor: cursor)
                } else { finish(success: true) }
            }
        } catch { finish(success: false) }
    }

    private func list(cursor: String?) throws {
        requestID += 1
        var params: [String: Any] = ["includeHidden": false, "limit": 100]
        if let cursor { params["cursor"] = cursor }
        try process?.write(["id": requestID, "method": "model/list", "params": params])
    }

    private func finish(success: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        process?.stop()
        process = nil
        let models = provider == .claude ? AgentModelCatalogService.claudeDescriptors(rows)
            : AgentModelCatalogService.descriptors(rows, cache: false)
        continuation.resume(returning: .init(models: success ? models : [],
                                             source: success ? "live" : nil))
    }
}

/// An ACP agent lists its models only for a session: this opens one in the project with no
/// MCP servers and nothing sent, reads its model and reasoning options, and deletes it
/// again where the agent can, so it never shows among the agent's own conversations.
private final class AcpModelDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tab.acp-model-catalog")
    private var process: AgentProcess?
    private var continuation: CheckedContinuation<AgentModelCatalogReply, Never>?
    private var capabilities: [String: Any] = [:]
    private var directory = ""
    private var bytes = 0
    private var models: [AgentModelDescriptor] = []
    private var provider: AgentChatProvider = .acp
    private var hasKey = false
    private var authenticated = false
    private var methods: [[String: Any]] = []

    static func discover(launch: AgentProcess.Launch, directory: String, timeout: TimeInterval,
                         provider: AgentChatProvider, hasKey: Bool) async -> AgentModelCatalogReply {
        let discovery = AcpModelDiscovery()
        discovery.directory = directory
        discovery.provider = provider
        discovery.hasKey = hasKey
        return await withCheckedContinuation { continuation in
            discovery.queue.async {
                discovery.continuation = continuation
                discovery.queue.asyncAfter(deadline: .now() + timeout) { discovery.finish() }
                do {
                    discovery.process = try AgentProcess(launch: launch, directory: directory, onLine: { data in
                        discovery.queue.async { discovery.receive(data) }
                    }, onExit: { _, _ in
                        discovery.queue.async { discovery.finish() }
                    })
                    try discovery.write(1, "initialize", ["protocolVersion": 1,
                        "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                        "clientInfo": ["name": "tab", "title": "Tab", "version": Release.version]])
                } catch { discovery.finish() }
            }
        }
    }

    private func write(_ id: Int, _ method: String, _ params: [String: Any]) throws {
        try process?.write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func receive(_ data: Data) {
        guard continuation != nil else { return }
        bytes += data.count
        guard bytes <= AgentModelCatalogService.maxCacheBytes else { finish(); return }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A browser sign-in can't happen here; the agent is signed out.
            if AcpAuthentication.asksForBrowser(data) { finish() }
            return
        }
        if message["method"] != nil {
            // Refuse anything the agent asks; this session never runs a prompt.
            if let id = message["id"] {
                try? process?.write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported while listing models."]])
            }
            return
        }
        let error = message["error"] as? [String: Any]
        if message["id"] as? Int == 2, let error, !authenticated, (error["code"] as? NSNumber)?.intValue == -32000,
           let method = AcpAuthentication.method(methods, provider: provider, hasKey: hasKey) {
            // Signed in as the runtime would be, then asked again.
            authenticated = true
            try? write(3, "authenticate", ["methodId": method])
            return
        }
        guard let id = message["id"] as? Int, let result = message["result"] as? [String: Any] else {
            if message["id"] != nil { finish() }
            return
        }
        do {
            switch id {
            case 1:
                capabilities = result["agentCapabilities"] as? [String: Any] ?? [:]
                methods = result["authMethods"] as? [[String: Any]] ?? []
                try write(2, "session/new", ["cwd": directory, "mcpServers": [Any]()])
            case 3:
                try write(2, "session/new", ["cwd": directory, "mcpServers": [Any]()])
            case 2:
                models = AcpSessionOptions(result).descriptors()
                let session = (capabilities["sessionCapabilities"] as? [String: Any]) ?? [:]
                if let sessionID = result["sessionId"] as? String, session["delete"] != nil || session["close"] != nil {
                    try write(4, session["delete"] != nil ? "session/delete" : "session/close", ["sessionId": sessionID])
                } else {
                    finish()
                }
            default:
                finish()
            }
        } catch { finish() }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        process?.stop()
        process = nil
        let listed = Array(models.prefix(AgentModelCatalogReply.maxModels))
        continuation.resume(returning: .init(models: listed, source: listed.isEmpty ? nil : "live"))
    }
}
