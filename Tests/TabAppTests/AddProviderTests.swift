import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AddProviderTests: XCTestCase {
    func testAnotherAccountOfAKindGetsAFolderOfItsOwn() throws {
        let settings = AgentProviderSettings()
        var first = AddProviderSheet.Draft(kind: .acp, settings: settings)
        XCTAssertEqual(first.id, "acp")
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
}
