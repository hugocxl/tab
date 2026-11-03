import XCTest
@testable import TabClient
import TabCore

final class AgentIntegrationTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tab-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Hooks run a `tab` that exists, unless a test names one that doesn't.
    private func integrations(cli: String? = nil) -> AgentIntegrations {
        let installed = home.appendingPathComponent("Tab.app/Contents/MacOS/tab")
        if !FileManager.default.fileExists(atPath: installed.path) {
            try? FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: installed.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        return AgentIntegrations(home: home, environment: [:], cli: cli.map { URL(fileURLWithPath: $0) } ?? installed)
    }

    private func json(_ path: String) throws -> NSDictionary {
        let data = try Data(contentsOf: home.appendingPathComponent(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testInstallKeepsTheUsersSettingsAndHooksAndRemoveRestoresThem() throws {
        let settings: NSDictionary = [
            "model": "opus",
            "hooks": ["SessionStart": [["matcher": "startup", "hooks": [["type": "command", "command": "echo hi"]]]],
                      "Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]
        let file = home.appendingPathComponent(".claude/settings.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: file)

        let installed = try integrations().install()
        try integrations().install()

        XCTAssertEqual(installed.first { $0.agent == .claude }?.hook, .installed)
        XCTAssertEqual(installed.first { $0.agent == .codex }?.skill, .installed)
        XCTAssertEqual(installed.first { $0.agent == .opencode }?.found, false)
        XCTAssertEqual(try HookDocument.read(file).tabCommands, [integrations().hookCommand])
        XCTAssertEqual(try json(".claude/settings.json")["model"] as? String, "opus")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode").path))

        try integrations().remove()

        XCTAssertEqual(try json(".claude/settings.json"), settings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/tab-cli").path))
        XCTAssertFalse(AgentIntegrations.isEnabled(integrations().status()))
    }

    func testAFileThatIsNotAJSONObjectIsNeverReplaced() throws {
        let file = home.appendingPathComponent(".claude/settings.json")
        try Data("{ \"model\": ".utf8).write(to: file)

        XCTAssertThrowsError(try integrations().install())

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ \"model\": ")
    }

    func testRefreshFollowsAMovedTabWithoutAddingHooks() throws {
        try integrations(cli: "/Applications/Old Tab.app/Contents/MacOS/tab").install()
        XCTAssertEqual(integrations().status(.claude).hook, .outdated)
        let skillOnly = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: skillOnly, withIntermediateDirectories: true)

        try integrations().refresh()

        XCTAssertEqual(integrations().status(.claude).hook, .installed)
        XCTAssertEqual(integrations().status(.codex).hook, .installed)
        XCTAssertEqual(integrations().status(.opencode).skill, .missing)
        XCTAssertEqual(try HookDocument.read(home.appendingPathComponent(".claude/settings.json")).tabCommands,
                       [integrations().hookCommand])
    }

    func testRefreshLeavesTheHookOfAnotherInstalledTab() throws {
        let development = home.appendingPathComponent("Tab Dev.app/Contents/MacOS/tab")
        try FileManager.default.createDirectory(at: development.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: development.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        try integrations(cli: development.path).install()

        try integrations().refresh()

        XCTAssertEqual(integrations().status(.claude).hook, .installed)
        XCTAssertEqual(try HookDocument.read(home.appendingPathComponent(".claude/settings.json")).tabCommands,
                       [integrations(cli: development.path).hookCommand])
    }

    func testAHookFileBehindALinkIsEditedWhereItLives() throws {
        let dotfiles = home.appendingPathComponent("dotfiles.json")
        try Data("{\"theme\":\"dark\"}".utf8).write(to: dotfiles)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude/settings.json"),
                                                   withDestinationURL: dotfiles)

        try integrations().install()

        let link = try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".claude/settings.json").path)
        XCTAssertEqual(link, dotfiles.path)
        XCTAssertEqual(try HookDocument.read(dotfiles).tabCommands.count, 1)
    }

    func testContextOnlyInsideATabTerminal() {
        XCTAssertNil(AgentIntegrations.context(environment: [:], cli: nil))
        let context = AgentIntegrations.context(environment: ["TAB_SESSION_ID": "s1"], cli: nil)
        XCTAssertTrue(context?.contains("session s1") ?? false)
    }

    func testOnlyTabsOwnHooksCount() {
        XCTAssertTrue(HookDocument.isTab("'/Applications/Tab Dev.app/Contents/MacOS/tab' agent-context"))
        XCTAssertFalse(HookDocument.isTab("/usr/local/bin/other agent-context"))
        XCTAssertFalse(HookDocument.isTab("tab agent-context --verbose"))
    }

    func testIntegrationsArguments() throws {
        XCTAssertEqual(try CLIParser.parse(["integrations"]).command, .integrations(.status, json: false))
        XCTAssertEqual(try CLIParser.parse(["integrations", "install", "--json"]).command, .integrations(.install, json: true))
        XCTAssertEqual(try CLIParser.parse(["agent-context"]).command, .agentContext)
        XCTAssertThrowsError(try CLIParser.parse(["--host", "box", "integrations"]))
    }
}
