import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentProviderStoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tab-providers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A stand-in CLI that answers `--version` and the sign-in commands like `claude` and `codex` do.
    private func fakeCLI(in directory: URL, version: String, auth: String, loggedIn: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent("fake-cli")
        try """
        #!/bin/sh
        case "$1" in
          --version) echo "\(version) (Fake)" ;;
          auth) printf '%s\\n' '\(auth)' ;;
          login) echo "\(loggedIn ? "Logged in using ChatGPT" : "Not logged in")" >&2; exit \(loggedIn ? 0 : 1) ;;
        esac
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testSavedProvidersSurviveARestartAndAnUnreadableFileIsKept() throws {
        let url = try root().appendingPathComponent("agent-providers.json")
        let store = AgentProviderStore(url: url)
        var settings = store.settings
        settings.providers.append(AgentProviderConfig(id: "claude-2", kind: .claude, name: "Work", home: "~/.claude-work",
                                                      environment: [AgentProviderVariable(name: "ANTHROPIC_BASE_URL", value: "https://example.com")]))
        _ = try store.write(settings)
        XCTAssertEqual(AgentProviderStore(url: url).settings, settings)

        try Data("{ not json".utf8).write(to: url)
        let damaged = AgentProviderStore(url: url)
        XCTAssertEqual(damaged.settings.providers.map(\.id), AgentChatProvider.builtIn.map(\.rawValue))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json", "a file this build can't read is left for the user")
        XCTAssertThrowsError(try damaged.write(AgentProviderSettings(providers: [AgentProviderConfig(id: "has space", kind: .claude)])))
    }

    func testChecksReadVersionAndSignInAndForgetThemWhenTheCLIChanges() async throws {
        let directory = try root()
        let claude = try fakeCLI(in: directory, version: "2.1.400",
                                 auth: #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","email":"me@example.com"}"#)
        let store = AgentProviderStore(url: directory.appendingPathComponent("agent-providers.json"),
                                       environment: { ["PATH": "/usr/bin:/bin"] },
                                       latestVersions: AgentProviderLatestVersions(lookup: { _ in "2.1.500" }))
        var settings = store.settings
        settings.providers = settings.providers.map { provider in
            var provider = provider
            provider.executable = claude.path
            return provider
        }
        _ = try store.write(settings)
        let state = await store.check()
        let health = try XCTUnwrap(state.health("claude"))
        XCTAssertTrue(health.installed)
        XCTAssertEqual(health.version, "2.1.400")
        XCTAssertEqual(health.auth, .signedIn)
        XCTAssertEqual(health.account, "Claude Team subscription")
        XCTAssertEqual(health.email, "me@example.com")
        XCTAssertEqual(state.health("codex")?.account, "ChatGPT")
        XCTAssertEqual(health.versionAdvisory?.status, .behindLatest)
        XCTAssertEqual(health.versionAdvisory?.latestVersion, "2.1.500")
        XCTAssertEqual(health.status, .warning, "an update is out")
        XCTAssertEqual(health.versionAdvisory?.canUpdate, true, "Claude Code updates itself")
        XCTAssertEqual(health.versionAdvisory?.updateCommand, "fake-cli update")

        settings.providers[0].models.favorites = ["opus"]
        XCTAssertNotNil(try store.write(settings).health("claude"), "model preferences don't change the CLI")
        settings.providers[0].home = "~/.claude-other"
        XCTAssertNil(try store.write(settings).health("claude"), "another config folder may be another account")
        XCTAssertNotNil(store.state().health("codex"))
    }

    func testAMissingCLIOrSignInSaysWhatToDo() throws {
        let directory = try root()
        let missing = AgentProviderStore.check(AgentProviderConfig(id: "claude", kind: .claude, executable: "/nonexistent/claude"),
                                               environment: [:], now: Date())
        XCTAssertFalse(missing.installed)
        XCTAssertTrue(missing.message?.contains("/nonexistent/claude") ?? false, missing.message ?? "")

        let codex = try fakeCLI(in: directory, version: "0.170.0", auth: "", loggedIn: false)
        let signedOut = AgentProviderStore.check(AgentProviderConfig(id: "codex-2", kind: .codex, executable: codex.path,
                                                                     home: "/tmp/codex-work"),
                                                 environment: ["PATH": "/usr/bin:/bin"], now: Date())
        XCTAssertEqual(signedOut.version, "0.170.0")
        XCTAssertEqual(signedOut.auth, .signedOut)
        XCTAssertEqual(signedOut.message, "Run `codex login` in a terminal with CODEX_HOME=/tmp/codex-work to sign in.")
    }

    func testSignInLabels() {
        func claude(_ json: String) -> (AgentProviderHealth.Auth, String?) {
            let (auth, account, _) = AgentProviderStore.claudeAuth(Data(json.utf8))
            return (auth, account)
        }
        XCTAssertTrue(claude(#"{"loggedIn":true,"subscriptionType":"max"}"#) == (.signedIn, "Claude Max subscription"))
        XCTAssertTrue(claude(#"{"loggedIn":true,"apiProvider":"bedrock"}"#) == (.signedIn, "Amazon Bedrock"))
        XCTAssertTrue(claude(#"{"loggedIn":true,"authMethod":"api_key"}"#) == (.signedIn, "Anthropic API key"))
        XCTAssertTrue(claude(#"{"loggedIn":false}"#) == (.signedOut, nil))
        XCTAssertTrue(claude("Unknown command: auth") == (.unknown, nil), "an older CLI without the command isn't signed out")
        XCTAssertTrue(AgentProviderStore.codexAuth("Logged in using an API key - sk-***", succeeded: true) == (.signedIn, "OpenAI API key"))
        XCTAssertEqual(AgentProviderStore.version(in: "codex-cli 0.170.0-alpha.2\n"), "0.170.0-alpha.2")
    }

    func testLaunchEnvironmentAppliesHomeCompactionAndVariables() {
        let provider = AgentProviderConfig(id: "claude-2", kind: .claude, home: "~/.claude-work",
                                           environment: [AgentProviderVariable(name: "ANTHROPIC_BASE_URL", value: "https://example.com"),
                                                         AgentProviderVariable(name: "PATH", value: "/custom/bin")],
                                           autoCompactTokens: 300_000)
        let environment = AgentProviderLaunch.environment(provider, base: ["PATH": "/usr/bin", "HOME": "/Users/me"])
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], NSHomeDirectory() + "/.claude-work")
        XCTAssertEqual(environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "300000")
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://example.com")
        XCTAssertEqual(environment["PATH"], "/custom/bin", "the user's own variables win")
        XCTAssertEqual(environment["HOME"], "/Users/me", "HOME stays, so Keychain sign-ins keep working")
        XCTAssertNil(AgentProviderLaunch.environment(.builtIn(.codex), base: [:])["CODEX_HOME"])
    }

    func testModelMenusUseEachProvidersHomeAndPreferences() async throws {
        let home = try root(), work = try root()
        let row: (String) -> [String: Any] = { ["slug": $0, "display_name": $0, "visibility": "list"] }
        try JSONSerialization.data(withJSONObject: ["models": [row("personal")]])
            .write(to: try { let url = home.appendingPathComponent(".codex"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }().appendingPathComponent("models_cache.json"))
        try JSONSerialization.data(withJSONObject: ["models": [row("alpha"), row("beta"), row("gamma")]])
            .write(to: work.appendingPathComponent("models_cache.json"))
        let settings = AgentProviderSettings(providers: [
            AgentProviderConfig(id: "codex-2", kind: .codex, home: work.path,
                                models: AgentProviderModels(favorites: ["gamma"], hidden: ["alpha"], custom: [AgentCustomModel(id: "next")])),
            AgentProviderConfig(id: "off", kind: .codex, enabled: false),
        ])
        let unused = AgentProcess.Launch(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], environment: [:])
        let service = AgentModelCatalogService(home: home, environment: [:], launch: unused,
                                              providers: { id, kind in settings.provider(id, kind: kind) },
                                              projectDirectory: { _ in home })
        let project = ProjectId()
        let builtIn = try await service.handle(.init(project: project, provider: .codex))
        XCTAssertEqual(builtIn.models.map(\.id), ["personal"])
        let menu = try await service.handle(.init(project: project, provider: .codex, providerID: "codex-2"))
        XCTAssertEqual(menu.models.map(\.id), ["gamma", "beta", "next"])
        let all = try await service.handle(.init(project: project, provider: .codex, providerID: "codex-2", includeHidden: true))
        XCTAssertEqual(all.models.map(\.id), ["gamma", "alpha", "beta", "next"])
        let off = try await service.handle(.init(project: project, provider: .codex, providerID: "off"))
        XCTAssertTrue(off.models.isEmpty)
    }

    // MARK: States, versions and updates

    func testAdvisoriesCompareWithTheLatestAndTheOldestSupported() {
        func status(_ version: String?, latest: String?, minimum: String? = "1.0.0") -> AgentProviderVersionAdvisory.Status {
            AgentProviderStore.advisory(version: version, latest: latest, minimum: minimum, installedBy: nil, updateCommand: nil,
                                        canUpdate: false, checkedAt: Date()).status
        }
        XCTAssertEqual(status("1.2.0", latest: "1.10.0"), .behindLatest, "versions compare as numbers")
        XCTAssertEqual(status("1.10.0", latest: "1.10.0"), .current)
        XCTAssertEqual(status("1.11.0", latest: "1.10.0"), .current, "a build newer than the registry is current")
        XCTAssertEqual(status("0.9.9", latest: "1.10.0"), .unsupported)
        XCTAssertEqual(status("0.9.9", latest: nil), .unsupported, "too old even when the latest can't be looked up")
        XCTAssertEqual(status("1.2.0", latest: nil), .unknown)
        XCTAssertTrue(AgentProviderVersion.isOlder("2.0.0-beta.2", than: "2.0.0"))
        XCTAssertTrue(AgentProviderVersion.isOlder("2.0.0-beta.2", than: "2.0.0-beta.10"))
        XCTAssertFalse(AgentProviderVersion.isOlder("v2.3.2", than: "2.3"))
        XCTAssertEqual(AgentProviderVersion.find(in: "opencode v2.3.2"), "2.3.2")

        let missing = AgentProviderHealth(provider: "gemini", installed: false, checkedAt: Date())
        XCTAssertEqual(missing.status, .error)
        var tooOld = AgentProviderHealth(provider: "gemini", installed: true, auth: .signedIn, checkedAt: Date(),
                                         versionAdvisory: .init(status: .unsupported))
        XCTAssertEqual(tooOld.status, .error)
        tooOld.versionAdvisory = .init(status: .current)
        XCTAssertEqual(tooOld.derivedStatus, .ready)
    }

    func testInstallationsAreReadFromTheExecutablesRealPath() throws {
        let directory = try root()
        let spec = AgentChatProvider.gemini.spec
        func link(_ target: String) throws -> URL {
            let file = directory.appendingPathComponent(target)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            let bin = directory.appendingPathComponent("bin-\(UUID().uuidString)/gemini")
            try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: file)
            return bin
        }
        let npmPrefix = directory.appendingPathComponent("node")
        let npm = npmPrefix.appendingPathComponent("bin/npm")
        try FileManager.default.createDirectory(at: npm.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: npm.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let viaNpm = AgentProviderInstallation.detect(try link("node/lib/node_modules/@google/gemini-cli/bundle/gemini.js"),
                                                      spec: spec, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(viaNpm, .npm(package: "@google/gemini-cli", npm: npm.path), "the npm beside the package's Node owns it")
        XCTAssertEqual(viaNpm.update?.arguments, ["install", "-g", "@google/gemini-cli@latest"])
        XCTAssertEqual(viaNpm.latestSource(spec), .npm("@google/gemini-cli"))

        let manual = AgentProviderInstallation.detect(try link("somewhere/gemini"), spec: spec, environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(manual, .manual, "Gemini CLI doesn't update itself")
        XCTAssertNil(manual.update)
        XCTAssertEqual(manual.latestSource(spec), .npm("@google/gemini-cli"), "its latest release is still known")

        let selfUpdating = AgentProviderInstallation.detect(try link("local/claude"), spec: AgentChatProvider.claude.spec,
                                                            environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(selfUpdating.update?.arguments, ["update"])
        XCTAssertEqual(AgentProviderInstallation.nodePackage("/a/lib/node_modules/opencode-ai/bin/opencode"), "opencode-ai")
        XCTAssertNil(AgentProviderInstallation.nodePackage("/opt/homebrew/Cellar/opencode/2.3.2/bin/opencode"))
        XCTAssertEqual(AgentProviderLatestVersions.homebrewVersion(Data(#"{"formulae":[{"versions":{"stable":"2.3.2"}}]}"#.utf8), cask: false), "2.3.2")
        XCTAssertEqual(AgentProviderLatestVersions.homebrewVersion(Data(#"{"casks":[{"version":"2.1.330,abc"}]}"#.utf8), cask: true), "2.1.330")
    }

    func testLatestVersionsAreCachedAndAMissingOneIsRetriedSoon() async {
        final class Clock: @unchecked Sendable { var now = Date(); var lookups = 0; var answer: String? }
        let clock = Clock()
        let versions = AgentProviderLatestVersions(now: { clock.now }, lookup: { _ in clock.lookups += 1; return clock.answer })
        let lookedUpMissing = await versions.latest(.npm("pkg"))
        XCTAssertNil(lookedUpMissing)
        clock.answer = "1.0.0"
        _ = await versions.latest(.npm("pkg"))
        XCTAssertEqual(clock.lookups, 1, "a missing release is kept for a minute")
        clock.now += 61
        let found = await versions.latest(.npm("pkg"))
        XCTAssertEqual(found, "1.0.0")
        clock.now += 1800
        _ = await versions.latest(.npm("pkg"))
        XCTAssertEqual(clock.lookups, 2, "a found release is kept for an hour")
        _ = await versions.latest(.npm("pkg"), fresh: true)
        XCTAssertEqual(clock.lookups, 3, "after an update the latest is looked up again")
    }

    func testUpdatesRunTheirCommandAndReportWhatChanged() async throws {
        let directory = try root()
        let marker = directory.appendingPathComponent("version")
        try "1.1.0".write(to: marker, atomically: true, encoding: .utf8)
        let cli = directory.appendingPathComponent("grok")
        try """
        #!/bin/sh
        case "$1" in
          --version) echo "grok $(cat '\(marker.path)')" ;;
          models) echo "You are logged in." ;;
          update) echo "Updating…"; echo "1.2.0" > '\(marker.path)' ;;
        esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let store = AgentProviderStore(url: directory.appendingPathComponent("agent-providers.json"),
                                       environment: { ["PATH": "/usr/bin:/bin"] },
                                       latestVersions: AgentProviderLatestVersions(lookup: { _ in "1.2.0" }))
        var settings = store.settings
        settings.providers = settings.providers.filter { $0.kind == .grok }
        settings.providers[0].executable = cli.path
        _ = try store.write(AgentProviderSettings(providers: settings.providers))
        let before = await store.check()
        XCTAssertEqual(before.health("grok")?.auth, .signedIn)
        XCTAssertEqual(before.health("grok")?.versionAdvisory?.status, .behindLatest)

        let started = try store.maintain("grok", action: .update)
        XCTAssertEqual(started.maintenance("grok")?.status, .running)
        XCTAssertEqual(started.maintenance("grok")?.command, "grok update")
        XCTAssertThrowsError(try store.maintain("grok", action: .update), "one update at a time")
        let deadline = Date().addingTimeInterval(10)
        while store.state().maintenance("grok")?.isRunning == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = store.state()
        XCTAssertEqual(after.maintenance("grok")?.status, .succeeded)
        XCTAssertEqual(after.maintenance("grok")?.message, "Updated Grok from 1.1.0 to 1.2.0.")
        XCTAssertEqual(after.maintenance("grok")?.output, "Updating…")
        XCTAssertEqual(after.health("grok")?.version, "1.2.0")
        XCTAssertEqual(after.health("grok")?.versionAdvisory?.status, .current)
        XCTAssertEqual(after.health("grok")?.status, .ready)
    }

    func testAnUpdateThatChangesNothingSaysSo() {
        let before = AgentProviderHealth(provider: "gemini", installed: true, version: "0.70.0", checkedAt: Date(),
                                         versionAdvisory: .init(status: .behindLatest, latestVersion: "0.71.0"))
        XCTAssertEqual(AgentProviderStore.outcome(.update, provider: "Gemini CLI", before: before, after: before).0, .unchanged)
        var current = before
        current.versionAdvisory = .init(status: .current)
        XCTAssertEqual(AgentProviderStore.outcome(.update, provider: "Gemini CLI", before: current, after: current).0, .succeeded)
        let gone = AgentProviderHealth(provider: "gemini", installed: false, checkedAt: Date())
        XCTAssertEqual(AgentProviderStore.outcome(.install, provider: "Gemini CLI", before: nil, after: gone).0, .failed)
    }

    func testNewProvidersReadTheirSignIn() throws {
        let home = try root()
        let gemini = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
        XCTAssertTrue(AgentProviderStore.geminiAuth(environment: ["GEMINI_CLI_HOME": home.path]) == (.signedOut, nil, nil))
        XCTAssertTrue(AgentProviderStore.geminiAuth(environment: ["GEMINI_CLI_HOME": home.path, "GEMINI_API_KEY": "k"])
                      == (.signedIn, "Gemini API key", nil))
        try Data("{}".utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        try Data(#"{"active":"me@example.com"}"#.utf8).write(to: gemini.appendingPathComponent("google_accounts.json"))
        XCTAssertTrue(AgentProviderStore.geminiAuth(environment: ["GEMINI_CLI_HOME": home.path])
                      == (.signedIn, "Google account", "me@example.com"))
        try Data(#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#.utf8).write(to: gemini.appendingPathComponent("settings.json"))
        XCTAssertEqual(AgentProviderStore.geminiAuth(environment: ["GEMINI_CLI_HOME": home.path]).0, .signedOut,
                       "an API key chosen in its settings but missing from its variables isn't signed in")

        XCTAssertTrue(AgentProviderStore.openCodeAuth("OpenAI  OpenAI                      stored\nAnthropic  Anthropic  env\n", succeeded: true)
                      == (.signedIn, "OpenAI, Anthropic"))
        XCTAssertTrue(AgentProviderStore.openCodeAuth("", succeeded: true) == (.unknown, "Free models only"))
        XCTAssertEqual(AgentProviderStore.grokAuth("Error: not authenticated. Run grok login."), .signedOut)
        XCTAssertEqual(AgentProviderStore.grokAuth("You are logged in as me.\n• grok-build (default)"), .signedIn)
        XCTAssertTrue(AgentProviderStore.kiroAuth(Data(#"{"account":null}"#.utf8), succeeded: false) == (.signedOut, nil, nil))
        XCTAssertTrue(AgentProviderStore.kiroAuth(Data(#"{"account":{"email":"me@example.com","type":"Builder ID"}}"#.utf8), succeeded: true)
                      == (.signedIn, "Builder ID", "me@example.com"))
        XCTAssertEqual(AgentProviderStore.signInMessage(AgentProviderConfig(id: "gemini-2", kind: .gemini, home: "/tmp/work")),
                       "Run `gemini` in a terminal with GEMINI_CLI_HOME=/tmp/work and sign in with your Gemini Code Assist account, or add GEMINI_API_KEY under Variables. Personal Google accounts use Antigravity CLI.")
    }

    func testEachKindStartsItsOwnCommand() {
        XCTAssertEqual(AgentProviderLaunch.sessionArguments(.builtIn(.gemini)), ["--acp"])
        XCTAssertEqual(AgentProviderLaunch.sessionArguments(.builtIn(.openCode)), ["acp"])
        XCTAssertEqual(AgentProviderLaunch.sessionArguments(.builtIn(.grok)), ["agent", "stdio"])
        let custom = AgentProviderConfig(id: "acp-2", kind: .acp, executable: "qwen", arguments: ["--experimental-acp"])
        XCTAssertEqual(AgentProviderLaunch.sessionArguments(custom), ["--experimental-acp"])
        XCTAssertFalse(custom.isBuiltIn)
        XCTAssertThrowsError(try AgentProviderLaunch.executable(AgentProviderConfig(id: "acp-3", kind: .acp), environment: [:]),
                             "a custom agent needs its command")
        XCTAssertEqual(AgentProviderLaunch.environment(.builtIn(.grok), base: [:])["GROK_DISABLE_AUTOUPDATER"], "1",
                       "Grok doesn't replace itself under a running conversation")
    }

    // MARK: Antigravity

    func testAntigravitySignInAndAuthMethods() {
        XCTAssertTrue(AgentProviderStore.antigravityAuth("Fetching available models...\nError: Please sign in to view available models. Launch the CLI without arguments to sign in.\n",
                                                         succeeded: false) == (.signedOut, nil))
        XCTAssertTrue(AgentProviderStore.antigravityAuth("Fetching available models...\n  gemini-4-neon\n", succeeded: true) == (.signedIn, "Google account"))
        let methods: [[String: Any]] = [["id": "oauth-personal"], ["id": "oauth-business"], ["id": "gemini-api-key"], ["id": "agent-platform"]]
        XCTAssertEqual(AcpAuthentication.method(methods, provider: .antigravity, hasKey: false), "oauth-personal",
                       "the keychain sign-in agy made in a terminal is reused")
        XCTAssertEqual(AcpAuthentication.method(methods, provider: .antigravity, hasKey: true), "gemini-api-key")
        XCTAssertNil(AcpAuthentication.method(methods, provider: .gemini, hasKey: false), "other agents never start a browser sign-in")
        XCTAssertTrue(AcpAuthentication.asksForBrowser(Data("Open the following link to authenticate the ACP server: https://accounts.google.com/o/oauth2/v2/auth?x=1".utf8)))
        XCTAssertFalse(AcpAuthentication.asksForBrowser(Data("Starting server".utf8)))
        XCTAssertEqual(AgentProviderLaunch.environment(.builtIn(.antigravity), base: [:])["AGY_CLI_DISABLE_AUTO_UPDATE"], "1")
        XCTAssertEqual(AgentProviderLaunch.sessionArguments(.builtIn(.antigravity)), ["acp"])
    }

    func testAntigravityModelFamiliesKeepTheirOwnReasoningLevels() throws {
        // As agy acp 1.5.15 opens a session: model families and the current one's levels as
        // options, and every family's variants as models.
        let response: [String: Any] = [
            "models": ["availableModels": ["gemini-4-neon-high", "gemini-4-neon-xhigh", "gemini-4-neon-low",
                                           "gemini-3.1-pro-high", "gemini-3.1-pro-low"].map { ["modelId": $0, "name": $0] },
                       "currentModelId": "gemini-3.1-pro-low"],
            "configOptions": [
                ["id": "model", "category": "model", "type": "select", "currentValue": "gemini-3.1-pro",
                 "options": [["value": "gemini-4-neon", "name": "Gemini 4 Neon"], ["value": "gemini-3.1-pro", "name": "Gemini 3.1 Pro"]]],
                ["id": "thought_level", "category": "thought_level", "type": "select", "currentValue": "low",
                 "options": [["value": "low", "name": "Low"], ["value": "high", "name": "High"]]],
                ["id": "mode", "category": "mode", "type": "select", "currentValue": "default",
                 "options": [["value": "default", "name": "Default"], ["value": "accept-edits", "name": "Accept edits"], ["value": "plan", "name": "Plan"]]],
            ],
        ]
        let options = AcpSessionOptions(response)
        let models = options.descriptors()
        XCTAssertEqual(models.map(\.id), ["gemini-4-neon", "gemini-3.1-pro"])
        XCTAssertEqual(models[0].reasoningEfforts, [.low, .high, .xhigh])
        XCTAssertEqual(models[1].reasoningEfforts, [.low, .high])
        XCTAssertTrue(models[1].isDefault)
        XCTAssertEqual(options.planMode, "plan")
        XCTAssertNil(options.fullAccessMode, "agy has no mode that skips approvals; Tab approves instead")
    }

    func testReleasesInstallOnlyWhatTheManifestNamesAndNeverReplaceAFile() throws {
        let good = #"{"version":"1.5.15","url":"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.5.15-1/darwin-arm/cli_mac_arm64.tar.gz","sha512":"\#(String(repeating: "a", count: 128))"}"#
        XCTAssertEqual(AgentProviderRelease.parse(Data(good.utf8))?.version, "1.5.15")
        XCTAssertNil(AgentProviderRelease.parse(Data(good.replacingOccurrences(of: "storage.googleapis.com", with: "example.com").utf8)))
        XCTAssertNil(AgentProviderRelease.parse(Data(good.replacingOccurrences(of: "https", with: "http").utf8)))
        XCTAssertNil(AgentProviderRelease.parse(Data(good.replacingOccurrences(of: String(repeating: "a", count: 128), with: "abc").utf8)))
        XCTAssertEqual(AgentProviderRelease.manifestURL(AgentChatProvider.antigravity.spec.releaseManifest ?? "")?.lastPathComponent, "darwin_arm64.json")

        let directory = try root()
        let file = directory.appendingPathComponent("data")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try AgentProviderRelease.sha512(of: file),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        let binary = directory.appendingPathComponent("antigravity")
        try Data().write(to: binary)
        let link = directory.appendingPathComponent("bin/agy")
        try AgentProviderRelease.link(binary, at: link)
        try AgentProviderRelease.link(binary, at: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), binary.path)
        let other = directory.appendingPathComponent("bin/other")
        try Data().write(to: other)
        XCTAssertThrowsError(try AgentProviderRelease.link(binary, at: other), "someone else's file stays")
    }

    func testScratchFoldersOfEndedServersAreSwept() throws {
        let directory = try root()
        let old = directory.appendingPathComponent(AgentProviderLaunch.scratchPrefix + "old")
        let fresh = directory.appendingPathComponent(AgentProviderLaunch.scratchPrefix + "fresh")
        let unrelated = directory.appendingPathComponent("unrelated")
        for url in [old, fresh, unrelated] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: unrelated.path)
        AgentProviderLaunch.sweepScratch(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "another server's may be in use")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertNil(AgentProviderLaunch.scratchDirectory(.builtIn(.openCode)))
    }
}
