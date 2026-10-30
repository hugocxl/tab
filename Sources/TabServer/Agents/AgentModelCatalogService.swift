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
    private struct Key: Hashable, Sendable {
        var project: ProjectId
        var provider: AgentChatProvider
        var filename: String { "\(project.description)-\(provider.rawValue).json" }
    }
    private struct Refresh: Sendable {
        var id = UUID()
        var task: Task<AgentModelCatalogReply, Never>
    }
    private var cached: [Key: (Date, AgentModelCatalogReply)] = [:]
    private var pending: [Key: Refresh] = [:]

    init(home: URL, environment: [String: String] = AgentProcess.environment(),
         launch: AgentProcess.Launch? = nil, timeout: TimeInterval = 4, cacheDirectory: URL? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         projectDirectory: @escaping @Sendable (ProjectId) throws -> URL) {
        self.home = home
        self.environment = environment
        self.launch = launch
        self.timeout = timeout
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.projectDirectory = projectDirectory
    }

    func handle(_ request: AgentModelCatalogRequest) async throws -> AgentModelCatalogReply {
        let directory = try projectDirectory(request.project)
        let provider = request.provider
        let key = Key(project: request.project, provider: provider)
        if !request.forceRefresh, let cached = cached[key], now().timeIntervalSince(cached.0) < 30 { return cached.1 }
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
            persist(disk, key: key)
            let modified = try? Self.cacheURL(home: home, environment: environment)
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if !request.forceRefresh, memory == nil, provider == .codex, disk.source == "cache", let modified,
               Date().timeIntervalSince(modified) < 300 { return disk }
        }
        var environment = environment
        if provider == .claude { environment.removeValue(forKey: "CLAUDECODE") }
        let launchEnvironment = environment
        let override = launch
        let timeout = timeout
        let task = Task.detached { () -> AgentModelCatalogReply in
            do {
                let launch = try override ?? AgentProcess.Launch(
                    executable: AgentProcess.resolve(provider == .codex ? "codex" : "claude", environment: launchEnvironment),
                    arguments: provider == .codex ? ["app-server"] : ["--print", "--verbose", "--input-format", "stream-json",
                        "--output-format", "stream-json", "--no-session-persistence", "--safe-mode",
                        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", ""], environment: launchEnvironment)
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

    private func readPersisted(key: Key) -> AgentModelCatalogReply? {
        guard let cacheDirectory,
              let data = Self.readBoundedFile(cacheDirectory.appendingPathComponent(key.filename)),
              var reply = try? WireJSON.decode(AgentModelCatalogReply.self, from: data),
              (try? reply.validate()) != nil, !reply.models.isEmpty else { return nil }
        reply.source = "saved"
        return reply
    }

    static let maxCacheBytes = 4 * 1024 * 1024

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
            let model = AgentModelDescriptor(id: id, title: row["displayName"] as? String ?? id,
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
