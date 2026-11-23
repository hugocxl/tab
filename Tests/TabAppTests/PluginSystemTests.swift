import AppKit
import XCTest
import TabCore
import TabProtocol
@testable import TabApp
@testable import TabExplorerPlugin
@testable import TabDiffPlugin

@MainActor
final class PluginSystemTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        let dirs = try ModelFixtures.profile()
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in nil }
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }
        return model
    }

    func testDefaultsHaveNoInstalledPlugins() throws {
        let settings = Settings()
        XCTAssertTrue(settings.plugins.installed.isEmpty)

        let model = try makeModel()
        XCTAssertTrue(model.rightSidebarPanels.isEmpty)
        XCTAssertFalse(model.plugins.isActive(.explorer))
        XCTAssertFalse(model.plugins.isActive(.diff))
        XCTAssertEqual(model.plugins.state(of: .explorer), .notInstalled)
        XCTAssertEqual(model.plugins.state(of: .diff), .notInstalled)
        XCTAssertFalse(model.panes.hasFactory(.diff), "Diff pane factory must not be registered until Diff View plugin is installed")
    }

    func testActivatingAndDeactivatingPluginsUpdatesRightSidebarAndDiffPanes() throws {
        let model = try makeModel()
        XCTAssertTrue(model.rightSidebarPanels.isEmpty)

        // Activate Explorer plugin.
        model.plugins.activate(plugin: ExplorerPlugin())
        XCTAssertEqual(model.rightSidebarPanels.map(\.id), ["files"])
        XCTAssertTrue(model.plugins.isActive(.explorer))
        model.selectRightPanel("files")
        XCTAssertEqual(model.rightPanel, "files")
        XCTAssertNotNil(model.rightPanelContent("files"))

        // Activate Diff View plugin.
        model.plugins.activate(plugin: DiffPlugin())
        XCTAssertEqual(model.rightSidebarPanels.map(\.id), ["files", "sourceControl"])
        XCTAssertTrue(model.panes.hasFactory(.diff))
        model.selectRightPanel("sourceControl")
        XCTAssertEqual(model.rightPanel, "sourceControl")

        // Deactivate Diff View: right sidebar falls back to Explorer, diff pane factory unregistered.
        model.plugins.deactivate(.diff)
        XCTAssertEqual(model.rightSidebarPanels.map(\.id), ["files"])
        XCTAssertEqual(model.rightPanel, "files")
        XCTAssertFalse(model.panes.hasFactory(.diff))

        // Deactivate Explorer: right sidebar closes cleanly.
        model.plugins.deactivate(.explorer)
        XCTAssertTrue(model.rightSidebarPanels.isEmpty)
        XCTAssertNil(model.rightPanel)
    }

    func testPluginSettingsPersistenceRoundTripAndBackwardCompatibility() throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }

        // Older settings.json without a "plugins" key decodes with zero installed plugins.
        let legacy = Data(#"{"appearance":{"darkTheme":"Tab"}}"#.utf8)
        let decodedLegacy = try Settings.decode(legacy)
        XCTAssertTrue(decodedLegacy.plugins.installed.isEmpty)

        // Saving plugins persists cleanly and deduplicates.
        var settings = Settings()
        settings.plugins.markInstalled(.explorer)
        settings.plugins.markInstalled(.explorer)
        settings.plugins.markInstalled(.diff)
        try settings.savePlugins(to: dirs.settings)

        let reloaded = try Settings.load(dirs.settings)
        XCTAssertEqual(reloaded.plugins.installed, [.explorer, .diff])

        settings.plugins.markUninstalled(.explorer)
        try settings.savePlugins(to: dirs.settings)
        let afterUninstall = try Settings.load(dirs.settings)
        XCTAssertEqual(afterUninstall.plugins.installed, [.diff])
    }

    func testSidePanelEncodingSupportsArbitraryFuturePluginPanelIds() throws {
        let panels: [SidePanel] = [.none, .files, .sourceControl, .panel("docker"), .panel("custom-panel")]
        for panel in panels {
            let encoded = try JSONEncoder().encode(panel)
            let decoded = try JSONDecoder().decode(SidePanel.self, from: encoded)
            XCTAssertEqual(decoded, panel)
        }
    }

    func testSettingsCatalogIncludesPluginsCategory() {
        XCTAssertTrue(SettingsCategory.allCases.contains(.plugins))
        XCTAssertEqual(SettingsCategory.plugins.title, "Plugins")
        XCTAssertFalse(SettingsCatalog.search("plugins").isEmpty)
    }

    func testSettingsStoreInstallAndUninstallUsesHost() async {
        let dirs = try! ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }
        let host = PreviewSettingsHost()
        let store = SettingsStore(dirs: dirs, host: host, theme: AppTheme(systemIsDark: true))

        XCTAssertEqual(store.pluginState(.explorer), .notInstalled)
        store.installPlugin(.explorer)
        await settle { store.pluginState(.explorer) == .installed }
        XCTAssertEqual(store.pluginState(.explorer), .installed)

        store.uninstallPlugin(.explorer)
        XCTAssertEqual(store.pluginState(.explorer), .notInstalled)
    }

    func testInstallAndUninstallDeletesPluginBundleFromDisk() async throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }

        // Build a minimal fake source directory to test PluginInstaller's copy/delete lifecycle
        // (real MH_BUNDLE loading is verified separately when built bundles are present).
        let sourceDir = dirs.root.appendingPathComponent("source-plugins", isDirectory: true)
        let fakeBundle = sourceDir.appendingPathComponent("explorer.bundle", isDirectory: true)
        let macOSDir = fakeBundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let exec = macOSDir.appendingPathComponent("TabExplorerPlugin")
        try Data("#!/bin/sh\n".utf8).write(to: exec)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
        let plist: [String: Any] = [
            "CFBundleExecutable": "TabExplorerPlugin",
            "CFBundleIdentifier": "com.hugocorta.tab.plugin.explorer",
            "NSPrincipalClass": "TabExplorerPluginFactory",
            "TabPluginId": "explorer",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: fakeBundle.appendingPathComponent("Contents/Info.plist"))

        let installer = PluginInstaller(dirs: dirs, isDebugBuild: true, localSearchDirectories: [sourceDir])
        XCTAssertFalse(installer.isBundlePresent(.explorer))

        let installedURL = try await installer.install(PluginCatalog.explorer)
        XCTAssertEqual(installedURL.standardizedFileURL, dirs.pluginBundle(.explorer).standardizedFileURL)
        XCTAssertTrue(installer.isBundlePresent(.explorer))

        try installer.remove(.explorer)
        XCTAssertFalse(installer.isBundlePresent(.explorer))
    }
}
