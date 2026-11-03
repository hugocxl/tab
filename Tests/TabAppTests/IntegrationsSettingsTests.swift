import AppKit
import TabClient
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class IntegrationsSettingsTests: XCTestCase {
    private var root: URL!
    private var dirs: TabDirs!
    private var host: PreviewSettingsHost!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-integrations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dirs = TabDirs(root: root)
        host = PreviewSettingsHost()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func toggle(_ page: SettingsModel) throws -> ToggleSpec {
        let row = try XCTUnwrap(page.lastBuild?.rows.first { $0.id == "agent-integration" })
        guard case .toggle(let spec)? = row.control else { throw XCTSkip("not a toggle") }
        return spec
    }

    func testTheSwitchInstallsIntoEveryAgentFoundAndRemovesAgain() async throws {
        let store = SettingsStore(dirs: dirs, host: host, theme: AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true))
        let page = SettingsModel(store: store)
        page.select(.integrations)
        try await Task.sleep(nanoseconds: 50_000_000)
        page.reload()
        XCTAssertFalse(try toggle(page).isOn)

        try toggle(page).change(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        page.reload()

        XCTAssertTrue(try toggle(page).isOn)
        XCTAssertEqual(host.integrations.first { $0.agent == .claude }?.hook, .installed)
        XCTAssertEqual(host.integrations.first { $0.agent == .pi }?.skill, .missing, "Pi isn't on this Mac")

        try toggle(page).change(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        page.reload()

        XCTAssertFalse(try toggle(page).isOn)
        XCTAssertFalse(AgentIntegrations.isEnabled(host.integrations))
    }

    func testMigratingOpensAnAgentWithAPromptForThatTerminal() throws {
        let store = SettingsStore(dirs: dirs, host: host, theme: AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true))
        let page = SettingsModel(store: store)
        page.select(.integrations)
        let row = try XCTUnwrap(page.lastBuild?.rows.first { $0.id == "terminal-migration" })
        let buttons = try XCTUnwrap(row.control).leaves.compactMap { control -> ButtonSpec? in
            if case .button(let spec) = control { return spec }
            return nil
        }
        XCTAssertEqual(buttons.map(\.title), host.migrations.map(\.name))

        buttons[0].action()

        let prompt = try XCTUnwrap(host.agentPrompts.first)
        XCTAssertTrue(prompt.contains("Migrate my \(host.migrations[0].name) setup"))
        XCTAssertTrue(prompt.contains(dirs.settings.path))
        XCTAssertTrue(prompt.contains(dirs.terminalSettings.path))
    }

    func testThePromptNamesOnlyActionsTheKeymapAccepts() throws {
        let source = try XCTUnwrap(TerminalMigration.sources.first)
        let prompt = TerminalMigration.prompt(for: source, home: root, dirs: dirs)
        let ids = prompt.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- `"), let end = line.dropFirst(3).firstIndex(of: "`") else { return nil }
            return String(line.dropFirst(3)[..<end])
        }
        XCTAssertFalse(ids.isEmpty)
        for id in ids where !id.hasPrefix("/") {
            XCTAssertNoThrow(try Keymap().withBinding(id, nil), "\(id) isn't a keymap action")
        }
    }
}
