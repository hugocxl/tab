import Foundation
import TabCore
import TabProtocol

/// `agent-providers.json`: the coding agents this server runs, what the last check of
/// each one's CLI found, and the installs and updates it ran. A file this build can't
/// read leaves the defaults in memory and the file untouched until the user saves.
final class AgentProviderStore: @unchecked Sendable {
    let url: URL
    private let baseEnvironment: @Sendable () -> [String: String]
    private let now: @Sendable () -> Date
    private let latestVersions: AgentProviderLatestVersions
    private let lock = NSLock()
    private var current: AgentProviderSettings
    private var health: [String: AgentProviderHealth] = [:]
    private var maintenance: [String: AgentProviderMaintenance] = [:]
    private var running: Task<Void, Never>?
    /// The last install or update started, which the next one waits for, so two never
    /// change the same package store at once.
    private var maintenanceChain: Task<Void, Never>?
    /// Runs after the providers change, so cached model lists are dropped.
    var onChange: (@Sendable () -> Void)?

    /// How long an install or update may run.
    static let maintenanceTimeout: TimeInterval = 30 * 60

    init(url: URL, environment: @escaping @Sendable () -> [String: String] = { AgentProcess.environment() },
         now: @escaping @Sendable () -> Date = { Date() },
         latestVersions: AgentProviderLatestVersions = AgentProviderLatestVersions()) {
        self.url = url
        baseEnvironment = environment
        self.now = now
        self.latestVersions = latestVersions
        current = AgentProviderSettings()
        DispatchQueue.global(qos: .utility).async { AgentProviderLaunch.sweepScratch() }
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
            AgentProvidersState(settings: current, health: current.providers.compactMap { health[$0.id] },
                                maintenance: current.providers.compactMap { maintenance[$0.id] })
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
            maintenance = maintenance.filter { id, run in run.isRunning || settings.provider(id) != nil }
            return settings.providers.contains { next in
                changed[next.id].map { !Self.runsTheSameCLI($0, next) } ?? true
            }
        }
        if cliChanged { onChange?() }
        return state()
    }

    /// The state, starting a check in the background when a provider was never checked
    /// or its last check is older than the interval, so every reader sees fresh states.
    func refreshingState() -> AgentProvidersState {
        let state = state()
        let interval = TimeInterval(state.settings.healthCheckInterval)
        let stale = state.settings.providers.contains { provider in
            guard provider.enabled else { return false }
            guard let checked = state.health(provider.id)?.checkedAt else { return true }
            return interval > 0 && now().timeIntervalSince(checked) > interval
        }
        if stale, lock.withLock({ running == nil }) { Task { _ = await check() } }
        return state
    }

    /// Checks every enabled provider's CLI, joining a check already running.
    func check() async -> AgentProvidersState {
        let task: Task<Void, Never> = lock.withLock {
            if let running { return running }
            let providers = current.providers.filter(\.enabled)
            let task = Task.detached { [weak self] in
                await withTaskGroup(of: AgentProviderHealth?.self) { group in
                    for provider in providers {
                        group.addTask { await self?.checked(provider) }
                    }
                    for await result in group { if let result { self?.record(result) } }
                }
                self?.lock.withLock { self?.running = nil }
            }
            running = task
            return task
        }
        await task.value
        return state()
    }

    /// Checks `provider` as `check` would, saved or not, changing nothing: the Add Provider
    /// dialog's view of what it is filling in.
    func probe(_ provider: AgentProviderConfig) async -> AgentProviderHealth {
        await checked(provider, prepare: false)
    }

    /// `provider`'s CLI, sign-in and version against its latest release.
    private func checked(_ provider: AgentProviderConfig, freshLatest: Bool = false, prepare: Bool = true) async -> AgentProviderHealth {
        let environment = baseEnvironment()
        let at = now()
        var health = (try? await runBlocking { Self.check(provider, environment: environment, now: at, prepare: prepare) })
            ?? AgentProviderHealth(provider: provider.id, installed: false, checkedAt: at)
        await advise(&health, provider: provider, environment: environment, freshLatest: freshLatest)
        return health
    }

    private func record(_ result: AgentProviderHealth) {
        lock.withLock {
            guard current.provider(result.provider) != nil else { return }
            health[result.provider] = result
        }
    }

    private static func runsTheSameCLI(_ a: AgentProviderConfig, _ b: AgentProviderConfig) -> Bool {
        a.executable == b.executable && a.home == b.home && a.shadowHome == b.shadowHome && a.environment == b.environment
            && a.arguments == b.arguments
    }

    // MARK: Versions and updates

    /// Adds how the CLI compares with its latest release and the oldest Tab supports.
    private func advise(_ health: inout AgentProviderHealth, provider: AgentProviderConfig,
                        environment base: [String: String], freshLatest: Bool) async {
        let spec = provider.kind.spec
        let environment = AgentProviderLaunch.environment(provider, base: base)
        guard health.installed, let path = health.executablePath else {
            if let install = AgentProviderInstallation.install(spec, environment: environment) {
                health.installCommand = install.line
                health.canInstall = true
            } else {
                health.installCommand = spec.installCommand
            }
            health.status = health.derivedStatus
            return
        }
        let installation = AgentProviderInstallation.detect(URL(fileURLWithPath: path), spec: spec, environment: environment)
        let latest: String?
        if let source = installation.latestSource(spec) {
            latest = await latestVersions.latest(source, fresh: freshLatest)
        } else {
            latest = nil
        }
        let update = installation.update
        health.versionAdvisory = Self.advisory(version: health.version, latest: latest, minimum: spec.minimumVersion,
            installedBy: installation.label,
            updateCommand: update.map { AgentProviderInstallation.commandLine($0.executable, $0.arguments) } ?? spec.installCommand,
            canUpdate: update != nil, checkedAt: now())
        if health.versionAdvisory?.status == .unsupported, let minimum = spec.minimumVersion {
            let fix = update == nil ? "Update it" : "Update it from Settings › Agents"
            health.message = [health.message, "\(provider.title) \(health.version ?? "") is older than \(minimum), the oldest version Tab works with. \(fix)."]
                .compactMap { $0 }.joined(separator: " ")
        }
        health.status = health.derivedStatus
    }

    static func advisory(version: String?, latest: String?, minimum: String?, installedBy: String?, updateCommand: String?,
                         canUpdate: Bool, checkedAt: Date) -> AgentProviderVersionAdvisory {
        let status: AgentProviderVersionAdvisory.Status
        if let version, let minimum, AgentProviderVersion.isOlder(version, than: minimum) {
            status = .unsupported
        } else if let version, let latest {
            status = AgentProviderVersion.isOlder(version, than: latest) ? .behindLatest : .current
        } else {
            status = .unknown
        }
        return AgentProviderVersionAdvisory(status: status, latestVersion: latest, minimumVersion: minimum,
                                            installedBy: installedBy, updateCommand: updateCommand,
                                            canUpdate: canUpdate, checkedAt: checkedAt)
    }

    /// Starts installing or updating `id`'s CLI after any install or update already started.
    func maintain(_ id: String, action: AgentProviderMaintenance.Action) throws -> AgentProvidersState {
        guard let provider = settings.provider(id) else { throw ServiceError(.badRequest, "No provider \(id)") }
        let spec = provider.kind.spec
        let environment = AgentProviderLaunch.environment(provider, base: baseEnvironment())
        let command: AgentProviderMaintenanceStep
        switch action {
        case .install:
            guard let install = AgentProviderInstallation.install(spec, environment: environment) else {
                throw ServiceError(.badRequest, "Tab can't install \(provider.title) here."
                    + (spec.installCommand.map { " Run `\($0)` in a terminal." } ?? ""))
            }
            command = install
        case .update:
            guard let executable = try? AgentProviderLaunch.executable(provider, environment: environment) else {
                throw ServiceError(.badRequest, "\(provider.title) isn't installed.")
            }
            guard let update = AgentProviderInstallation.detect(executable, spec: spec, environment: environment).update else {
                throw ServiceError(.badRequest, "Tab can't tell how \(provider.title) was installed, so it can't update it."
                    + (spec.installCommand.map { " Reinstall it with `\($0)`." } ?? ""))
            }
            command = .command(update.executable, update.arguments)
        }
        let previous = lock.withLock { health[id] }
        let started = now()
        let line = command.line
        let task: Task<Void, Never>? = try lock.withLock {
            if maintenance[id]?.isRunning == true {
                throw ServiceError(.badRequest, "\(provider.title) is already being \(maintenance[id]?.action == .install ? "installed" : "updated").")
            }
            let waiting = maintenanceChain != nil
            maintenance[id] = AgentProviderMaintenance(provider: id, action: action, command: line, status: .running,
                startedAt: started, message: waiting ? "Waiting for another install or update to finish" : "Running \(line)")
            let before = maintenanceChain
            let task = Task.detached { [weak self] in
                await before?.value
                await self?.run(provider, action: action, command: command, line: line, previous: previous,
                                environment: environment)
            }
            maintenanceChain = task
            return task
        }
        _ = task
        return state()
    }

    private func run(_ provider: AgentProviderConfig, action: AgentProviderMaintenance.Action,
                     command: AgentProviderMaintenanceStep, line: String,
                     previous: AgentProviderHealth?, environment: [String: String]) async {
        update(provider.id) { $0.message = "Running \(line)" }
        let timeout = Self.maintenanceTimeout
        let result: Result<ProcessOutput, Error>
        do {
            switch command {
            case let .command(executable, arguments):
                result = .success(try await runBlocking {
                    try ProcessRunner.run(executable, arguments, directory: NSHomeDirectory(),
                                          environment: environment, timeout: timeout)
                })
            case .release(let spec):
                let log = try await AgentProviderRelease.install(spec)
                result = .success(ProcessOutput(stdout: Data(log.utf8), stderr: Data(), status: 0, truncated: false))
            }
        } catch {
            result = .failure(error)
        }
        update(provider.id) { $0.message = "Checking the installed version" }
        let checked = await checked(provider, freshLatest: true)
        record(checked)
        onChange?()
        update(provider.id) { run in
            run.finishedAt = now()
            switch result {
            case .failure(let error):
                run.status = .failed
                run.message = "\(line) failed: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
            case .success(let output) where !output.succeeded:
                run.status = .failed
                run.message = "\(line) exited with status \(output.status)."
                run.output = Self.tail(output.stdoutText + output.stderrText)
            case .success(let output):
                run.output = Self.tail(output.stdoutText + output.stderrText)
                (run.status, run.message) = Self.outcome(action, provider: provider.title, before: previous, after: checked)
            }
        }
    }

    /// Whether an install or update that exited cleanly did what it should.
    static func outcome(_ action: AgentProviderMaintenance.Action, provider: String, before: AgentProviderHealth?,
                        after: AgentProviderHealth) -> (AgentProviderMaintenance.Status, String) {
        guard after.installed else {
            return (.failed, "\(provider) still isn't found. Check that the folder it was installed to is on PATH.")
        }
        let version = after.version.map { " \($0)" } ?? ""
        if action == .install { return (.succeeded, "Installed \(provider)\(version).") }
        if let old = before?.version, let new = after.version, old != new {
            return (.succeeded, "Updated \(provider) from \(old) to \(new).")
        }
        if after.versionAdvisory?.status == .current { return (.succeeded, "\(provider)\(version) is up to date.") }
        return (.unchanged, "\(provider) is still\(version.isEmpty ? " the same version" : version). The update may need to be run in a terminal.")
    }

    private func update(_ id: String, _ change: (inout AgentProviderMaintenance) -> Void) {
        lock.withLock {
            guard var run = maintenance[id] else { return }
            change(&run)
            maintenance[id] = run
        }
    }

    /// The end of a command's output that fits the reply.
    static func tail(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count > AgentProviderMaintenance.maxOutputBytes else { return trimmed }
        var bytes = trimmed.utf8.suffix(AgentProviderMaintenance.maxOutputBytes - 4)
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes = bytes.dropFirst() }
        return "…\n" + String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Checking a CLI

    /// Runs `provider`'s CLI for its version and sign-in. Blocks for up to about 20 seconds.
    /// Without `prepare`, a Codex account folder isn't linked, and a config folder that
    /// doesn't exist yet counts as signed out rather than being made by the CLI.
    static func check(_ provider: AgentProviderConfig, environment base: [String: String], now: Date,
                      prepare: Bool = true) -> AgentProviderHealth {
        let environment = AgentProviderLaunch.environment(provider, base: base)
        let executable: URL
        do {
            executable = try AgentProviderLaunch.executable(provider, environment: environment)
        } catch {
            return AgentProviderHealth(provider: provider.id, installed: false, message: error.localizedDescription, checkedAt: now)
        }
        let versionRun = try? ProcessRunner.run(executable.path, ["--version"], environment: environment, timeout: 10)
        let version = versionRun.flatMap { $0.succeeded ? AgentProviderVersion.find(in: $0.stdoutText + "\n" + $0.stderrText) : nil }
        // A custom ACP agent may not take `--version`; finding it is enough.
        guard versionRun?.succeeded == true || provider.kind == .acp else {
            return AgentProviderHealth(provider: provider.id, installed: false,
                message: "\(executable.path) did not run. Check that it is \(provider.kind.name) and that macOS allows it to open.",
                checkedAt: now, executablePath: executable.path)
        }
        var health = AgentProviderHealth(provider: provider.id, installed: true, version: version, checkedAt: now,
                                         executablePath: executable.path,
                                         signInCommand: AgentProviderLaunch.signInCommand(provider, executable: provider.executable.map { _ in executable.path }))
        if !prepare, let home = AgentProviderLaunch.effectiveHome(provider),
           !FileManager.default.fileExists(atPath: home), provider.environment.allSatisfy({ !provider.kind.spec.apiKeyVariables.contains($0.name) }) {
            health.auth = .signedOut
            health.message = "\(home) doesn't exist yet, so nothing is signed in there."
            health.status = health.derivedStatus
            return health
        }
        do {
            if prepare { try AgentProviderLaunch.prepareShadowHome(provider) }
        } catch {
            health.message = error.localizedDescription
            health.status = .error
            return health
        }
        func run(_ arguments: [String]) -> ProcessOutput? {
            try? ProcessRunner.run(executable.path, arguments, environment: environment, timeout: 10)
        }
        switch provider.kind {
        case .claude:
            (health.auth, health.account, health.email) = claudeAuth(run(["auth", "status", "--json"])?.stdout ?? Data())
        case .codex:
            let status = run(["login", "status"])
            (health.auth, health.account) = codexAuth(status.map { $0.stdoutText + "\n" + $0.stderrText } ?? "",
                                                      succeeded: status?.succeeded == true)
        case .antigravity:
            if environment["GEMINI_API_KEY"]?.isEmpty == false {
                (health.auth, health.account) = (.signedIn, "Gemini API key")
            } else {
                let status = run(["models"])
                (health.auth, health.account) = antigravityAuth(status.map { $0.stdoutText + "\n" + $0.stderrText } ?? "",
                                                                succeeded: status?.succeeded == true)
            }
        case .gemini:
            (health.auth, health.account, health.email) = geminiAuth(environment: environment)
        case .openCode:
            let status = run(["auth", "list"])
            (health.auth, health.account) = openCodeAuth(status?.stdoutText ?? "", succeeded: status?.succeeded == true)
        case .grok:
            if environment["XAI_API_KEY"]?.isEmpty == false {
                (health.auth, health.account) = (.signedIn, "xAI API key")
            } else {
                let status = run(["models"])
                health.auth = grokAuth(status.map { $0.stdoutText + "\n" + $0.stderrText } ?? "")
            }
        case .kiro:
            if environment["KIRO_API_KEY"]?.isEmpty == false {
                (health.auth, health.account) = (.signedIn, "Kiro API key")
            } else {
                let status = run(["whoami", "--format", "json"])
                (health.auth, health.account, health.email) = kiroAuth(status?.stdout ?? Data(), succeeded: status?.succeeded == true)
            }
        case .acp:
            break
        }
        if health.auth == .signedOut { health.message = signInMessage(provider) }
        health.status = health.derivedStatus
        return health
    }

    /// The first version number in `text`, such as `2.1.311` in "2.1.311 (Claude Code)".
    static func version(in text: String) -> String? { AgentProviderVersion.find(in: text) }

    /// What to run to sign in, with the provider's config folder when it has its own.
    static func signInMessage(_ provider: AgentProviderConfig) -> String {
        let spec = provider.kind.spec
        let home = AgentProviderLaunch.effectiveHome(provider)
        var with = ""
        if let variable = provider.homeVariable, let home { with = " with \(variable)=\(home)" }
        let keys = spec.apiKeyVariables.isEmpty ? "" : ", or add \(spec.apiKeyVariables[0]) under Variables"
        switch provider.kind {
        case .antigravity:
            return "Run `agy` in a terminal and sign in with Google\(keys)."
        case .gemini:
            return "Run `gemini` in a terminal\(with) and sign in with your Gemini Code Assist account\(keys). Personal Google accounts use Antigravity CLI."
        default:
            guard let command = spec.signInCommand else { return "Sign in to \(provider.title)\(keys)." }
            return "Run `\(command)` in a terminal\(with) to sign in\(keys)."
        }
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

    /// Gemini CLI signs in with an API key in its environment, Vertex AI, or a Google
    /// account whose credentials it keeps in `~/.gemini`, below `GEMINI_CLI_HOME` when set.
    /// The method chosen last is `security.auth.selectedType` in its settings.
    static func geminiAuth(environment: [String: String]) -> (AgentProviderHealth.Auth, String?, String?) {
        let root = URL(fileURLWithPath: environment["GEMINI_CLI_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory())
            .appendingPathComponent(".gemini", isDirectory: true)
        let settings = (try? Data(contentsOf: root.appendingPathComponent("settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let selected = ((settings?["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
            ?? settings?["selectedAuthType"] as? String
        let hasKey = ["GEMINI_API_KEY", "GOOGLE_API_KEY"].contains { environment[$0]?.isEmpty == false }
        let vertex = environment["GOOGLE_GENAI_USE_VERTEXAI"]?.lowercased() == "true"
        switch selected {
        case "vertex-ai":
            return (vertex || hasKey || environment["GOOGLE_CLOUD_PROJECT"] != nil ? .signedIn : .signedOut, "Vertex AI", nil)
        case "gemini-api-key":
            return (hasKey ? .signedIn : .signedOut, "Gemini API key", nil)
        case "gateway":
            return (.unknown, "AI API gateway", nil)
        default:
            break
        }
        if vertex { return (.signedIn, "Vertex AI", nil) }
        if hasKey { return (.signedIn, "Gemini API key", nil) }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("oauth_creds.json").path) else {
            return (.signedOut, nil, nil)
        }
        let accounts = (try? Data(contentsOf: root.appendingPathComponent("google_accounts.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let email = (accounts?["active"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
        return (.signedIn, "Google account", email)
    }

    /// Reads `agy models`, which lists the account's models, or says to sign in first.
    static func antigravityAuth(_ text: String, succeeded: Bool) -> (AgentProviderHealth.Auth, String?) {
        let lower = text.lowercased()
        if lower.contains("sign in") || lower.contains("not signed") || lower.contains("not logged") { return (.signedOut, nil) }
        return succeeded ? (.signedIn, "Google account") : (.unknown, nil)
    }

    /// Reads `opencode auth list`: one line per model provider with saved or environment
    /// credentials. OpenCode also has free models, so none signed in is not signed out.
    static func openCodeAuth(_ text: String, succeeded: Bool) -> (AgentProviderHealth.Auth, String?) {
        guard succeeded else { return (.unknown, nil) }
        let names = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard let state = columns.last?.lowercased(), ["stored", "env", "oauth", "api"].contains(state),
                  let name = columns.first else { return nil }
            return String(name)
        }
        guard !names.isEmpty else { return (.unknown, "Free models only") }
        return (.signedIn, Array(names.prefix(4)).joined(separator: ", "))
    }

    /// Reads `grok models`, which exits 0 either way and says whether it is logged in.
    static func grokAuth(_ text: String) -> AgentProviderHealth.Auth {
        let lower = text.lowercased()
        if lower.contains("not authenticated") || lower.contains("not logged in") { return .signedOut }
        if lower.contains("you are logged in") { return .signedIn }
        return .unknown
    }

    /// Reads `kiro-cli whoami --format json`, which fails with a null account when signed out.
    static func kiroAuth(_ data: Data, succeeded: Bool) -> (AgentProviderHealth.Auth, String?, String?) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let account = json?["account"]
        guard succeeded, let account, !(account is NSNull) else {
            return (json == nil && !succeeded ? .unknown : .signedOut, nil, nil)
        }
        let details = account as? [String: Any]
        let email = (details?["email"] as? String) ?? (json?["email"] as? String) ?? (account as? String)
        let method = (details?["type"] as? String) ?? (json?["authMethod"] as? String)
        return (.signedIn, method, email.map { String($0.prefix(256)) })
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

    /// The folder the kind's home variable names: a Codex account's shadow home, else the
    /// provider's home; nil leaves the CLI's own default.
    static func effectiveHome(_ provider: AgentProviderConfig) -> String? {
        guard provider.homeVariable != nil else { return nil }
        if provider.supportsShadowHome, let shadow = provider.shadowHome.map(expand), !shadow.isEmpty { return shadow }
        return provider.home.map(expand).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The home a shadow home shares everything but its sign-in with.
    static func sharedHome(_ provider: AgentProviderConfig) -> String {
        let home = provider.home.map(expand) ?? ""
        return home.isEmpty ? expand(provider.kind.spec.defaultHome ?? "~") : home
    }

    /// Links a Codex account's shadow home to its shared home before the CLI runs in it.
    static func prepareShadowHome(_ provider: AgentProviderConfig) throws {
        guard provider.supportsShadowHome, let shadow = provider.shadowHome.map(expand), !shadow.isEmpty else { return }
        do {
            try CodexShadowHome.prepare(shared: URL(fileURLWithPath: sharedHome(provider), isDirectory: true),
                                        shadow: URL(fileURLWithPath: shadow, isDirectory: true))
        } catch {
            throw AgentRuntimeError("\(provider.title) can't start: \(error)")
        }
    }

    /// Arguments Tab adds before the provider's own: a shadow home's bundled plugins.
    static func homeArguments(_ provider: AgentProviderConfig) -> [String] {
        guard provider.supportsShadowHome, let shadow = provider.shadowHome.map(expand), !shadow.isEmpty else { return [] }
        return CodexShadowHome.arguments(shadow: URL(fileURLWithPath: shadow, isDirectory: true))
    }

    /// The command line that signs `provider` in, in its own home folder.
    static func signInCommand(_ provider: AgentProviderConfig, executable: String?) -> String? {
        let spec = provider.kind.spec
        guard var words = spec.signInCommand.map({ $0.split(separator: " ").map(String.init) }), !words.isEmpty else { return nil }
        if let executable { words[0] = executable }
        var line = Executable.commandLine(words)
        if let variable = provider.homeVariable, let home = effectiveHome(provider) {
            line = "\(variable)=\(Executable.commandLine([home])) " + line
        }
        return line
    }

    /// `base` with the provider's home folder, auto-compact window and variables set.
    static func environment(_ provider: AgentProviderConfig, base: [String: String]) -> [String: String] {
        var environment = base
        if let variable = provider.homeVariable, let home = effectiveHome(provider) {
            environment[variable] = home
        }
        if provider.kind == .claude, let tokens = provider.autoCompactTokens {
            environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(tokens)
        }
        // An update a CLI starts by itself would replace it under a running conversation;
        // Tab updates it from Settings instead.
        if provider.kind == .grok { environment["GROK_DISABLE_AUTOUPDATER"] = "1" }
        if provider.kind == .antigravity {
            environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "1"
            environment["PYTHONUNBUFFERED"] = "1"
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
        guard !name.isEmpty else {
            throw AgentRuntimeError("\(provider.title) has no command to run. Set its executable in Settings › Agents.")
        }
        guard name.contains("/") else { return try AgentProcess.resolve(name, environment: environment) }
        guard FileManager.default.isExecutableFile(atPath: name) else {
            throw AgentRuntimeError("\(provider.title) can't start: \(name) is not an executable file. Fix its path in Settings › Agents.")
        }
        return URL(fileURLWithPath: name)
    }

    /// Antigravity unpacks its runtime into `TMPDIR` each time it starts, about a gigabyte,
    /// so each of its processes gets a folder of its own that Tab removes once it exits,
    /// even when it was stopped before it could clean up. Nil for other kinds.
    static func scratchDirectory(_ provider: AgentProviderConfig) -> URL? {
        guard provider.kind == .antigravity else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchPrefix + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return url
    }

    static let scratchPrefix = "tab-agy-"

    /// Removes a scratch folder off the caller's queue.
    static func removeScratch(_ url: URL?, after delay: TimeInterval = 0) {
        guard let url else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes scratch folders a server that ended without cleaning up left behind. A day's
    /// grace leaves those of other servers running now, such as another worktree's.
    static func sweepScratch(in directory: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 86_400,
                             now: Date = Date()) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(scratchPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: entry) }
        }
    }

    /// The arguments that start a conversation: the kind's own, then the provider's.
    static func sessionArguments(_ provider: AgentProviderConfig) -> [String] {
        provider.kind.spec.sessionArguments + provider.arguments
    }
}
