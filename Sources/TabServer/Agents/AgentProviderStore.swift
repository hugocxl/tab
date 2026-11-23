import Foundation
import TabCore
import TabProtocol

/// `agent-providers.json`: the coding agents this server runs, and what the
/// last check of each one's CLI found. A file this build can't read leaves
/// the defaults in memory and the file untouched until the user saves.
final class AgentProviderStore: @unchecked Sendable {
    let url: URL
    private let baseEnvironment: @Sendable () -> [String: String]
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var current: AgentProviderSettings
    private var health: [String: AgentProviderHealth] = [:]
    private var running: Task<Void, Never>?
    /// Runs after the providers change, so cached model lists are dropped.
    var onChange: (@Sendable () -> Void)?

    init(url: URL, environment: @escaping @Sendable () -> [String: String] = { AgentProcess.environment() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        baseEnvironment = environment
        self.now = now
        current = AgentProviderSettings()
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let settings = try JSONDecoder().decode(AgentProviderSettings.self, from: data)
            try settings.validate()
            current = settings
        } catch {
            ServerLog.error("\(url.lastPathComponent) is unreadable; using the default agents: \(error)")
        }
    }

    var settings: AgentProviderSettings { lock.withLock { current } }

    func state() -> AgentProvidersState {
        lock.withLock {
            AgentProvidersState(settings: current, health: current.providers.compactMap { health[$0.id] })
        }
    }

    /// The provider a conversation of `kind` runs, given the ID it chose.
    func provider(_ id: String?, kind: AgentChatProvider) -> AgentProviderConfig {
        settings.provider(id, kind: kind)
    }

    /// Validates, saves, then uses `settings` for conversations that start from now on.
    func write(_ settings: AgentProviderSettings) throws -> AgentProvidersState {
        do {
            try settings.validate()
        } catch {
            throw ServiceError(.badRequest, "The agent providers are invalid")
        }
        let cliChanged = try lock.withLock { () throws -> Bool in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try AtomicFile.write(try encoder.encode(settings), to: url)
            } catch {
                throw ServiceError(.persistenceFailed, "Could not save the agent providers: \(error.localizedDescription)")
            }
            let changed = Dictionary(uniqueKeysWithValues: current.providers.map { ($0.id, $0) })
            current = settings
            // A provider whose CLI or account may differ is checked again.
            health = health.filter { id, _ in
                guard let next = settings.provider(id), let previous = changed[id] else { return false }
                return next.enabled && Self.runsTheSameCLI(previous, next)
            }
            return settings.providers.contains { next in
                changed[next.id].map { !Self.runsTheSameCLI($0, next) } ?? true
            }
        }
        if cliChanged { onChange?() }
        return state()
    }

    /// Checks every enabled provider's CLI, joining a check already running.
    func check() async -> AgentProvidersState {
        let task: Task<Void, Never> = lock.withLock {
            if let running { return running }
            let providers = current.providers.filter(\.enabled)
            let environment = baseEnvironment()
            let now = now
            let task = Task.detached { [weak self] in
                await withTaskGroup(of: AgentProviderHealth.self) { group in
                    for provider in providers {
                        group.addTask {
                            (try? await runBlocking { Self.check(provider, environment: environment, now: now()) })
                                ?? AgentProviderHealth(provider: provider.id, installed: false, checkedAt: now())
                        }
                    }
                    for await result in group { self?.record(result) }
                }
                self?.lock.withLock { self?.running = nil }
            }
            running = task
            return task
        }
        await task.value
        return state()
    }

    private func record(_ result: AgentProviderHealth) {
        lock.withLock {
            guard current.provider(result.provider) != nil else { return }
            health[result.provider] = result
        }
    }

    private static func runsTheSameCLI(_ a: AgentProviderConfig, _ b: AgentProviderConfig) -> Bool {
        a.executable == b.executable && a.home == b.home && a.environment == b.environment
    }

    // MARK: Checking a CLI

    /// Runs `provider`'s CLI for its version and sign-in. Blocks for up to about 20 seconds.
    static func check(_ provider: AgentProviderConfig, environment base: [String: String], now: Date) -> AgentProviderHealth {
        let environment = AgentProviderLaunch.environment(provider, base: base)
        let executable: URL
        do {
            executable = try AgentProviderLaunch.executable(provider, environment: environment)
        } catch {
            return AgentProviderHealth(provider: provider.id, installed: false, message: error.localizedDescription, checkedAt: now)
        }
        guard let output = try? ProcessRunner.run(executable.path, ["--version"], environment: environment, timeout: 10),
              output.succeeded else {
            return AgentProviderHealth(provider: provider.id, installed: false,
                message: "\(executable.path) did not run. Check that it is \(provider.kind.name) and that macOS allows it to open.",
                checkedAt: now)
        }
        var health = AgentProviderHealth(provider: provider.id, installed: true, version: version(in: output.stdoutText),
                                         checkedAt: now)
        switch provider.kind {
        case .claude:
            let status = try? ProcessRunner.run(executable.path, ["auth", "status", "--json"], environment: environment, timeout: 10)
            (health.auth, health.account, health.email) = claudeAuth(status?.stdout ?? Data())
        case .codex:
            let status = try? ProcessRunner.run(executable.path, ["login", "status"], environment: environment, timeout: 10)
            (health.auth, health.account) = codexAuth(status.map { $0.stdoutText + "\n" + $0.stderrText } ?? "",
                                                      succeeded: status?.succeeded == true)
        }
        if health.auth == .signedOut {
            let command = provider.kind == .claude ? "claude auth login" : "codex login"
            let home = provider.home.map(AgentProviderLaunch.expand).flatMap { $0.isEmpty ? nil : $0 }
            health.message = "Run `\(command)` in a terminal" + (home.map { " with \(provider.homeVariable)=\($0)" } ?? "") + " to sign in."
        }
        return health
    }

    /// The first version number in `text`, such as `2.1.311` in "2.1.311 (Claude Code)".
    static func version(in text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Reads `claude auth status --json`.
    static func claudeAuth(_ data: Data) -> (AgentProviderHealth.Auth, String?, String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = json["loggedIn"] as? Bool else { return (.unknown, nil, nil) }
        guard loggedIn else { return (.signedOut, nil, nil) }
        let email = (json["email"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
        switch json["apiProvider"] as? String {
        case "bedrock": return (.signedIn, "Amazon Bedrock", email)
        case "vertex": return (.signedIn, "Google Vertex AI", email)
        case "foundry": return (.signedIn, "Microsoft Foundry", email)
        default: break
        }
        if let plan = json["subscriptionType"] as? String, !plan.isEmpty {
            let names = ["pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise", "free": "Free"]
            let name = names[plan.lowercased()] ?? plan.prefix(1).uppercased() + plan.dropFirst().prefix(31)
            return (.signedIn, "Claude \(name) subscription", email)
        }
        let method = (json["authMethod"] as? String)?.lowercased() ?? ""
        return (.signedIn, method.contains("key") || method.contains("console") ? "Anthropic API key" : nil, email)
    }

    /// Reads `codex login status`, which prints "Logged in using ChatGPT" or "Not logged in".
    static func codexAuth(_ text: String, succeeded: Bool) -> (AgentProviderHealth.Auth, String?) {
        let lower = text.lowercased()
        if lower.contains("not logged in") { return (.signedOut, nil) }
        guard succeeded, lower.contains("logged in") else { return (.unknown, nil) }
        if lower.contains("chatgpt") { return (.signedIn, "ChatGPT") }
        if lower.contains("api key") { return (.signedIn, "OpenAI API key") }
        return (.signedIn, nil)
    }
}

/// How a provider's settings change the CLI Tab starts.
enum AgentProviderLaunch {
    /// `~` and `~/…` as paths in the user's home folder.
    static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        return NSHomeDirectory() + trimmed.dropFirst()
    }

    /// `base` with the provider's home folder, auto-compact window and variables set.
    static func environment(_ provider: AgentProviderConfig, base: [String: String]) -> [String: String] {
        var environment = base
        if let home = provider.home.map(expand), !home.isEmpty { environment[provider.homeVariable] = home }
        if provider.kind == .claude, let tokens = provider.autoCompactTokens {
            environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(tokens)
        }
        for variable in provider.environment where !variable.name.isEmpty {
            environment[variable.name] = variable.value
        }
        return environment
    }

    /// The CLI to run: the provider's path, or its command found on `PATH`.
    static func executable(_ provider: AgentProviderConfig, environment: [String: String]) throws -> URL {
        let chosen = provider.executable.map(expand) ?? ""
        let name = chosen.isEmpty ? provider.defaultExecutable : chosen
        guard name.contains("/") else { return try AgentProcess.resolve(name, environment: environment) }
        guard FileManager.default.isExecutableFile(atPath: name) else {
            throw AgentRuntimeError("\(provider.title) can't start: \(name) is not an executable file. Fix its path in Settings › Agents.")
        }
        return URL(fileURLWithPath: name)
    }
}
