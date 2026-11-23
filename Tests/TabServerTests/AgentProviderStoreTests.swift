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
        XCTAssertEqual(damaged.settings.providers.map(\.id), ["claude", "codex"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json", "a file this build can't read is left for the user")
        XCTAssertThrowsError(try damaged.write(AgentProviderSettings(providers: [AgentProviderConfig(id: "has space", kind: .claude)])))
    }

    func testChecksReadVersionAndSignInAndForgetThemWhenTheCLIChanges() async throws {
        let directory = try root()
        let claude = try fakeCLI(in: directory, version: "2.1.400",
                                 auth: #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","email":"me@example.com"}"#)
        let store = AgentProviderStore(url: directory.appendingPathComponent("agent-providers.json"),
                                       environment: { ["PATH": "/usr/bin:/bin"] })
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
}
