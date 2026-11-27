import Foundation
import XCTest
@testable import TabProtocol

final class AgentProviderSettingsTests: XCTestCase {
    func testFilesFromOtherBuildsLoadOnlyConfiguredProvidersAndDropDuplicates() throws {
        let json = """
        {"providers": [
            {"id": "claude-2", "kind": "claude", "name": "Work", "futureKey": 1},
            {"id": "future", "kind": "future-agent", "enabled": true},
            {"id": "claude-2", "kind": "claude", "name": "Duplicate"},
            {"id": "codex", "kind": "codex", "enabled": false}
        ], "futureSetting": true}
        """
        let settings = try JSONDecoder().decode(AgentProviderSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.providers.map(\.id), ["claude-2", "codex"])
        XCTAssertEqual(settings.provider("claude-2")?.name, "Work")
        XCTAssertEqual(settings.provider("codex")?.enabled, false)
        XCTAssertEqual(settings.healthCheckInterval, AgentProviderSettings.defaultHealthCheckInterval)
        try settings.validate()
        XCTAssertEqual(try JSONDecoder().decode(AgentProviderSettings.self, from: Data("{}".utf8)).providers, [],
                       "an unconfigured file starts empty until providers are added")
        XCTAssertTrue(AgentProviderSettings().providers.isEmpty)
    }

    func testProvidersOlderBuildsAddedByThemselvesAreDroppedAndChangedOnesKept() throws {
        // Older builds listed every built-in kind, added or not, and wrote no revision.
        let builtIns = AgentChatProvider.builtIn.map { kind -> String in
            switch kind {
            case .claude: #"{"id": "claude", "kind": "claude", "arguments": ["--chrome"]}"#
            case .gemini: #"{"id": "gemini", "kind": "gemini", "enabled": false}"#
            default: #"{"id": "\#(kind.rawValue)", "kind": "\#(kind.rawValue)", "enabled": true}"#
            }
        }
        let legacy = #"{"providers": [\#((builtIns + [#"{"id": "claude-personal", "kind": "claude", "name": "Personal"}"#]).joined(separator: ","))]}"#
        let migrated = try JSONDecoder().decode(AgentProviderSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(migrated.providers.map(\.id), ["claude", "claude-personal"],
                       "only the providers the user changed or added survive")

        // Saved again, the list is the user's own and nothing is dropped any more.
        let saved = try JSONEncoder().encode(migrated)
        XCTAssertEqual(try JSONDecoder().decode(AgentProviderSettings.self, from: saved), migrated)
        let explicit = AgentProviderSettings(providers: AgentChatProvider.builtIn.map { .builtIn($0) })
        XCTAssertEqual(try JSONDecoder().decode(AgentProviderSettings.self, from: JSONEncoder().encode(explicit)).providers.count,
                       AgentChatProvider.builtIn.count, "providers added by hand with nothing changed stay")

        // A list without every built-in kind was the user's own already.
        let partial = #"{"providers": [{"id": "claude", "kind": "claude"}, {"id": "codex", "kind": "codex"}]}"#
        XCTAssertEqual(try JSONDecoder().decode(AgentProviderSettings.self, from: Data(partial.utf8)).providers.map(\.id),
                       ["claude", "codex"])
    }

    func testAccountsThatSignInFromTheSamePlaceAreOneAccount() {
        let claude = AgentProviderConfig(id: "claude", kind: .claude)
        XCTAssertEqual(claude.signInFolder, "~/.claude")
        XCTAssertTrue(claude.sharesSignIn(with: AgentProviderConfig(id: "claude-2", kind: .claude, home: NSHomeDirectory() + "/.claude/")),
                      "the default folder written out is the same folder")
        XCTAssertFalse(claude.sharesSignIn(with: AgentProviderConfig(id: "claude-work", kind: .claude, home: "~/.claude-work")))
        let key = [AgentProviderVariable(name: "ANTHROPIC_API_KEY", value: "sk-1")]
        XCTAssertFalse(claude.sharesSignIn(with: AgentProviderConfig(id: "claude-key", kind: .claude, environment: key)),
                       "an API key is an account of its own")
        XCTAssertTrue(AgentProviderConfig(id: "a", kind: .claude, environment: key)
            .sharesSignIn(with: AgentProviderConfig(id: "b", kind: .claude, home: "~/.other", environment: key)))

        let codex = AgentProviderConfig(id: "codex", kind: .codex)
        XCTAssertFalse(codex.sharesSignIn(with: AgentProviderConfig(id: "codex-work", kind: .codex, shadowHome: "~/.codex-tab/work")),
                       "a Codex account folder keeps its own sign-in while sharing the Codex folder")

        let antigravity = AgentProviderConfig(id: "antigravity", kind: .antigravity)
        XCTAssertNil(antigravity.signInFolder)
        XCTAssertTrue(antigravity.sharesSignIn(with: AgentProviderConfig(id: "antigravity-2", kind: .antigravity)),
                      "a kind with one sign-in per Mac is one account without an API key")
        XCTAssertFalse(AgentProviderConfig(id: "acp", kind: .acp, executable: "qwen")
            .sharesSignIn(with: AgentProviderConfig(id: "acp-2", kind: .acp, executable: "goose")))
        XCTAssertFalse(claude.sharesSignIn(with: codex))
    }

    func testAnOlderServersStateOffersOnlyTheKindsItRuns() throws {
        let checked = Date().timeIntervalSinceReferenceDate
        let old = """
        {"settings": {"providers": [{"id": "claude", "kind": "claude"}, {"id": "codex", "kind": "codex"}]},
         "health": [{"provider": "claude", "installed": true, "auth": "signedOut", "checkedAt": \(checked)}]}
        """
        let state = try WireJSON.decode(AgentProvidersState.self, from: Data(old.utf8))
        XCTAssertEqual(state.kinds, AgentChatProvider.original)
        XCTAssertEqual(state.settings.providers.map(\.kind), [.claude, .codex])
        XCTAssertEqual(state.health("claude")?.status, .error, "a status an older server didn't send comes from what it did")
        XCTAssertTrue(state.maintenance.isEmpty)

        let newer = """
        {"settings": {"providers": [{"id": "claude", "kind": "claude"}, {"id": "gemini", "kind": "gemini"}]},
         "kinds": ["claude", "gemini", "future-agent"],
         "health": [{"provider": "gemini", "installed": true, "auth": "signedIn", "status": "future-status", "checkedAt": \(checked),
                     "versionAdvisory": {"status": "future", "latestVersion": "1.0.0"}}],
         "maintenance": [{"provider": "gemini", "action": "update", "command": "npm i", "status": "future", "startedAt": \(checked)}]}
        """
        let decoded = try WireJSON.decode(AgentProvidersState.self, from: Data(newer.utf8))
        XCTAssertEqual(decoded.kinds, [.claude, .gemini], "a kind this build doesn't know is left out")
        XCTAssertEqual(decoded.settings.providers.map(\.id), ["claude", "gemini"])
        XCTAssertEqual(decoded.health("gemini")?.status, .warning)
        XCTAssertEqual(decoded.health("gemini")?.versionAdvisory?.status, .unknown)
        XCTAssertEqual(decoded.maintenance("gemini")?.status, .failed, "an unknown outcome never reads as running")

        let state2 = AgentProvidersState(settings: AgentProviderSettings(), maintenance: [
            AgentProviderMaintenance(provider: "gemini", action: .install, command: "brew install gemini-cli", status: .running, startedAt: Date()),
        ])
        XCTAssertEqual(try WireJSON.decode(AgentProvidersState.self, from: WireJSON.encode(state2)), state2)
    }

    func testAConversationResolvesConfiguredProviderAndFallsBackWhenRemoved() {
        let settings = AgentProviderSettings(providers: [AgentProviderConfig(id: "work", kind: .codex)])
        XCTAssertEqual(settings.provider("work", kind: .codex).id, "work")
        XCTAssertEqual(settings.provider("work", kind: .claude).id, "claude", "a provider of another kind never runs it")
        XCTAssertEqual(settings.provider("removed", kind: .codex).id, "codex")
        XCTAssertEqual(settings.provider(nil, kind: .codex).id, "work", "nil ID uses the first configured provider of that kind")
        XCTAssertEqual(settings.newID(.codex), "codex-2")
    }

    func testModelsArrangeFavoritesThenTheUsersOrderAndHideOnlyFromTheMenu() {
        let reported = ["a", "b", "c", "d"].map { AgentModelDescriptor(id: $0, title: $0.uppercased(), reasoningEfforts: []) }
        let models = AgentProviderModels(favorites: ["c"], hidden: ["b", "custom"], order: ["d", "b"],
                                         custom: [AgentCustomModel(id: "custom"), AgentCustomModel(id: "a")])
        XCTAssertEqual(models.arrange(reported).map(\.id), ["c", "d", "b", "a", "custom"])
        XCTAssertEqual(models.visible(reported).map(\.id), ["c", "d", "a"])
        XCTAssertEqual(models.arrange(reported).first { $0.id == "a" }?.title, "A", "a custom ID the CLI reports keeps its details")
    }

    func testAccountsGetIDsFromTheirLabelsAndKeepTheirColorAndFolder() throws {
        var settings = AgentProviderSettings(providers: [.builtIn(.claude)])
        XCTAssertEqual(settings.newID(.claude, label: "Claude Code"), "claude-2", "the kind's own name adds a numbered one")
        XCTAssertEqual(settings.newID(.claude, label: "  Work · Équipe! "), "claude-work-equipe")
        XCTAssertEqual(settings.newID(.acp, label: ""), "acp", "the first custom agent takes the kind's name")
        settings.providers.append(AgentProviderConfig(id: "claude-work", kind: .claude, name: "Work", shadowHome: nil,
                                                      accentColor: "#1F6FEB"))
        XCTAssertEqual(settings.newID(.claude, label: "work"), "claude-work-2")
        XCTAssertFalse(AgentProviderConfig.isValidID("work account"))
        XCTAssertFalse(AgentProviderConfig.isValidID("équipe"), "IDs stay ASCII")

        var codex = AgentProviderConfig(id: "codex-personal", kind: .codex, shadowHome: "~/.codex-tab/personal", accentColor: "#2fa84a")
        let decoded = try JSONDecoder().decode(AgentProviderConfig.self, from: JSONEncoder().encode(codex))
        XCTAssertEqual(decoded, codex)
        XCTAssertTrue(decoded.accentComponents! == (0x2F, 0xA8, 0x4A))
        try codex.validate()
        codex.accentColor = "blue"
        XCTAssertThrowsError(try codex.validate())
    }

    func testValidationRefusesWhatACLICantTake() {
        func refuses(_ change: (inout AgentProviderConfig) -> Void) {
            var provider = AgentProviderConfig.builtIn(.claude)
            change(&provider)
            XCTAssertThrowsError(try AgentProviderSettings(providers: [provider]).validate())
        }
        refuses { $0.id = "has space" }
        refuses { $0.environment = [AgentProviderVariable(name: "A=B", value: "x")] }
        refuses { $0.home = "bad\0path" }
        refuses { $0.autoCompactTokens = 50_000 }
        var duplicate = AgentProviderSettings(providers: [.builtIn(.claude)])
        duplicate.providers.append(.builtIn(.claude))
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testPromptsAndSnapshotsFromOlderBuildsKeepTheirProvider() throws {
        let prompt = try JSONDecoder().decode(AgentPrompt.self, from: Data("""
            {"id": "\(UUID().uuidString)", "text": "hi", "provider": "codex", "planMode": false, "attachments": []}
            """.utf8))
        XCTAssertNil(prompt.providerID)
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WireJSON.encode(snapshot)) as? [String: Any])
        object["providerID"] = nil
        let decoded = try WireJSON.decode(AgentChatSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.providerID)
    }
}
