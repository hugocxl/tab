import AppKit
import TabClient
import TabCore
import TabProtocol
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
        let row = try XCTUnwrap(page.lastBuild?.rows.first { $0.id == "agent-provider-integration" })
        guard case .toggle(let spec)? = row.control else { throw XCTSkip("not a toggle") }
        return spec
    }

    func testPerProviderIntegrationInstallsAndRemovesOnProviderPage() async throws {
        let claude = AgentProviderConfig(id: "claude-work", kind: .claude, name: "Work", home: "~/.claude-work")
        host.providers = AgentProvidersState(settings: AgentProviderSettings(providers: [claude]))
        let store = SettingsStore(dirs: dirs, configFile: dirs.root.appendingPathComponent("user-settings.json"), host: host, theme: AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true))
        let page = SettingsModel(store: store)
        page.select(.agents)
        try await Task.sleep(nanoseconds: 50_000_000)
        page.reload()
        XCTAssertNil(page.lastBuild?.rows.first { $0.id == "agent-integration" }, "global terminal integration is removed")

        page.openProvider(claude.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        page.reload()
        XCTAssertFalse(try toggle(page).isOn)

        try toggle(page).change(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        page.reload()

        XCTAssertTrue(try toggle(page).isOn)
        XCTAssertEqual(host.providerIntegrations[claude.id]?.hook, .installed)
        XCTAssertEqual(host.providerIntegrations[claude.id]?.skill, .installed)

        try toggle(page).change(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        page.reload()

        XCTAssertFalse(try toggle(page).isOn)
        XCTAssertEqual(host.providerIntegrations[claude.id]?.isIntegrated, false)
    }
}
