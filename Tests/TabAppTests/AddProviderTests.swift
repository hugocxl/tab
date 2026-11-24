import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AddProviderTests: XCTestCase {
    func testAnotherAccountOfAKindGetsAFolderOfItsOwn() throws {
        let empty = AgentProviderSettings()
        let firstClaude = AddProviderSheet.Draft(kind: .claude, settings: empty)
        XCTAssertEqual(firstClaude.id, "claude")
        XCTAssertEqual(firstClaude.home, "", "the first Claude uses its default config folder")
        XCTAssertTrue(firstClaude.installIntegration, "Tab integration is enabled by default for supported kinds")

        let settings = AgentProviderSettings(providers: [.builtIn(.claude), .builtIn(.codex)])
        var first = AddProviderSheet.Draft(kind: .acp, settings: settings)
        XCTAssertEqual(first.id, "acp")
        XCTAssertFalse(first.installIntegration, "custom ACP agents have no built-in Tab integration")
        XCTAssertEqual(first.configError(), "Enter the agent's command.")
        first.executable = "qwen"
        first.arguments = "--acp"
        XCTAssertEqual(first.config.arguments, ["--acp"])

        var claude = AddProviderSheet.Draft(kind: .claude, settings: settings)
        XCTAssertEqual(claude.home, "~/.claude-2", "a second Claude signs in to its own folder")
        claude.setLabel("Work", settings: settings)
        XCTAssertEqual(claude.id, "claude-work")
        XCTAssertEqual(claude.home, "~/.claude-work", "the folder follows the label until edited")
        claude.accentColor = "#8E4BF2"
        claude.useAPIKey = true
        XCTAssertEqual(claude.configError(), "Enter the API key.")
        claude.apiKey = "sk-test"
        let config = claude.config
        XCTAssertEqual(config.name, "Work")
        XCTAssertEqual(config.home, "~/.claude-work")
        XCTAssertEqual(config.environment, [AgentProviderVariable(name: "ANTHROPIC_API_KEY", value: "sk-test")])
        XCTAssertEqual(config.accentColor, "#8E4BF2")
        XCTAssertNoThrow(try config.validate())

        var codex = AddProviderSheet.Draft(kind: .codex, settings: settings)
        codex.setLabel("Personal", settings: settings)
        XCTAssertEqual(codex.shadowHome, "~/.codex-tab/personal", "a second Codex shares the Codex folder but not its sign-in")
        XCTAssertEqual(codex.home, "")
        codex.id = "codex"
        codex.idEdited = true
        XCTAssertEqual(codex.identityError(settings), "Another provider has the ID “codex”.")
    }

    func testASecondAccountMustBeToldApartAndIsWarnedWhenItWouldShareASignIn() {
        let settings = AgentProviderSettings(providers: [.builtIn(.claude)])
        var work = AddProviderSheet.Draft(kind: .claude, settings: settings)
        XCTAssertEqual(work.accentColor, AgentProviderConfig.accentColors.first, "another account starts with a color of its own")
        XCTAssertEqual(work.identityError(settings), "Enter a label, such as Work or Personal, to tell it apart from “Claude Code”.")
        work.setLabel("claude code", settings: settings)
        XCTAssertEqual(work.identityError(settings), "Another Claude Code provider is called “claude code”.")
        work.setLabel("Work", settings: settings)
        XCTAssertNil(work.identityError(settings))
        XCTAssertNil(work.sharedSignIn(settings), "its own folder is its own sign-in")
        let state = AgentProvidersState(settings: settings, health: [
            AgentProviderHealth(provider: "claude", installed: true, auth: .signedIn, email: "me@example.com", checkedAt: Date()),
        ])
        let sameEmail = AgentProviderHealth(provider: "claude", installed: true, version: "2.1.323", auth: .signedIn,
                                            email: "Me@Example.com", checkedAt: Date())
        XCTAssertEqual(AddProviderSheet.warning(work, health: sameEmail, state: state),
                       "Signed in as me@example.com, the same account as “Claude Code”.")

        work.home = "~/.claude"
        XCTAssertEqual(work.sharedSignIn(settings)?.id, "claude")
        XCTAssertEqual(AddProviderSheet.warning(work, health: nil, state: state),
                       "“Claude Code” already signs in from ~/.claude, so both would be one account. Choose another folder to add a different account.")

        // Antigravity keeps one Google sign-in per Mac, so another account starts on an API key.
        let agy = AgentProviderSettings(providers: [.builtIn(.antigravity)])
        var second = AddProviderSheet.Draft(kind: .antigravity, settings: agy)
        XCTAssertTrue(second.useAPIKey)
        second.useAPIKey = false
        XCTAssertEqual(second.sharedSignIn(agy)?.id, "antigravity")

        let gemini = AddProviderSheet.Draft(kind: .gemini, settings: AgentProviderSettings(providers: [.builtIn(.gemini)]))
        XCTAssertEqual(gemini.home, "~/.gemini-2", "another Gemini CLI account gets a home folder of its own")
        XCTAssertNil(gemini.sharedSignIn(AgentProviderSettings(providers: [.builtIn(.gemini)])))
    }

    func testTheFoundCLIFillsTheExecutableUntilOneIsTyped() {
        var draft = AddProviderSheet.Draft(kind: .claude, settings: AgentProviderSettings())
        draft.suggest(executable: "/Users/me/.local/bin/claude")
        XCTAssertEqual(draft.executable, "/Users/me/.local/bin/claude")
        draft.suggest(executable: "/opt/homebrew/bin/claude")
        XCTAssertEqual(draft.executable, "/opt/homebrew/bin/claude", "a better find replaces an untouched suggestion")
        draft.executable = "/usr/local/bin/claude-beta"
        draft.suggest(executable: "/opt/homebrew/bin/claude")
        XCTAssertEqual(draft.executable, "/usr/local/bin/claude-beta", "what the user typed stays")

        var codex = AddProviderSheet.Draft(kind: .codex, settings: AgentProviderSettings())
        codex.suggest(executable: "/Users/me/.nvm/versions/node/v24.1.0/bin/codex")
        XCTAssertEqual(codex.executable, "codex", "a path an upgrade leaves behind is filled in by name")
    }

    func testTheConfigStepSaysWhatItFoundOfTheCLI() {
        let draft = AddProviderSheet.Draft(kind: .claude, settings: AgentProviderSettings())
        XCTAssertEqual(AddProviderSheet.status(draft, health: nil, checking: true).text, "Checking Claude Code…")
        let signedIn = AgentProviderHealth(provider: "claude", installed: true, version: "2.1.323", auth: .signedIn,
                                           account: "Claude Team subscription", email: "me@example.com", checkedAt: Date())
        XCTAssertEqual(AddProviderSheet.status(draft, health: signedIn, checking: false).text,
                       "Claude Code 2.1.323 · Signed in as me@example.com · Claude Team subscription")
        let missing = AgentProviderHealth(provider: "claude", installed: false, checkedAt: Date(), installCommand: "brew install claude")
        let status = AddProviderSheet.status(draft, health: missing, checking: false)
        XCTAssertTrue(status.problem)
        XCTAssertTrue(status.text.hasPrefix("Claude Code isn't installed."))
    }

    func testTheModelMenuSaysWhyAProviderCantRun() {
        let codex = AgentProviderConfig.builtIn(.codex)
        let signedOut = AgentProviderHealth(provider: "codex", installed: true, version: "0.171.0", auth: .signedOut,
                                            message: "Run `codex login` in a terminal to sign in.", checkedAt: Date(),
                                            signInCommand: "codex login")
        let reason = AgentProviderUnavailability(codex, health: signedOut)
        XCTAssertEqual(reason?.badge, "Signed out")
        XCTAssertEqual(reason?.detail, "Codex: Unavailable. Run `codex login` in a terminal to sign in.")
        XCTAssertEqual(reason?.signInCommand, "codex login")

        let ready = AgentProviderHealth(provider: "codex", installed: true, version: "0.171.0", auth: .signedIn, checkedAt: Date())
        XCTAssertNil(AgentProviderUnavailability(codex, health: ready))
        XCTAssertNil(AgentProviderUnavailability(codex, health: nil), "an unchecked provider isn't blocked")
        let unknown = AgentProviderHealth(provider: "codex", installed: true, auth: .unknown, checkedAt: Date())
        XCTAssertNil(AgentProviderUnavailability(codex, health: unknown), "a sign-in Tab can't read may still work")
    }

    func testEmptyProvidersShowEmptyStateInAgentPaneAndAnyProviderCanBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-providers-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PreviewSettingsHost()
        let store = SettingsStore(dirs: TabDirs(root: root), host: host,
                                  theme: AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true))
        let page = SettingsModel(store: store)
        page.select(.agents)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.agentProviders?.settings.providers, [], "starts empty until providers are added")

        let added = store.addAgentProvider(AgentProviderConfig(id: "claude", kind: .claude, name: "Personal"))
        XCTAssertEqual(added, "claude")
        XCTAssertEqual(store.agentProviders?.settings.providers.map(\.id), ["claude"])
        store.removeAgentProvider("claude")
        XCTAssertEqual(store.agentProviders?.settings.providers, [], "any configured provider can be deleted")

        var openedSettings = false
        let pane = AgentPaneController(session: SessionId(), project: ProjectId(), provider: .claude) { _ in
            AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, accessMode: .fullAccess)
        }
        defer { pane.dispose() }
        pane.loadProviders = { AgentProvidersState(settings: AgentProviderSettings()) }
        pane.loadModelCatalog = { _, _ in [] }
        pane.openAgentSettings = { openedSettings = true }
        pane.refresh()
        for _ in 0..<50 where pane.surface.providerGap == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(pane.surface.providerGap, .noneAdded)
        pane.surface.configureProviders.onPress?()
        XCTAssertTrue(openedSettings)
    }
}
