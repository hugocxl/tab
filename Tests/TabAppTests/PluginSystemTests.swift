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
            "CFBundleVersion": "120",
            "NSPrincipalClass": "TabExplorerPluginFactory",
            "TabPluginId": "explorer",
<<<<<<< Updated upstream
            "TabPluginVersion": Release.version,
||||||| Stash base
=======
            "TabPluginVersion": "0.129.0",
>>>>>>> Stashed changes
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: fakeBundle.appendingPathComponent("Contents/Info.plist"))

        let installer = PluginInstaller(
            dirs: dirs, version: "0.129.0", buildNumber: "120",
            isDebugBuild: true, localSearchDirectories: [sourceDir]
        )
        XCTAssertFalse(installer.isBundlePresent(.explorer))

        let installedURL = try await installer.install(PluginCatalog.explorer)
        XCTAssertEqual(installedURL.standardizedFileURL, dirs.pluginBundle(.explorer).standardizedFileURL)
        XCTAssertTrue(installer.isBundlePresent(.explorer))

        try installer.remove(.explorer)
        XCTAssertFalse(installer.isBundlePresent(.explorer))
    }

<<<<<<< Updated upstream
    func testInstallerRejectsMismatchedPluginVersion() async throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }

        let sourceDir = dirs.root.appendingPathComponent("source-plugins", isDirectory: true)
        try writeFakeBundle(id: "explorer", executable: "TabExplorerPlugin", principal: "TabExplorerPluginFactory",
                            version: "0.122.0", into: sourceDir)

        let staleInstaller = PluginInstaller(dirs: dirs, version: "0.129.0", isDebugBuild: true, localSearchDirectories: [sourceDir])
        do {
            _ = try await staleInstaller.install(PluginCatalog.explorer)
            XCTFail("Expected version mismatch error")
        } catch let error as PluginError {
            guard case .invalidBundle(let message) = error else {
                return XCTFail("Expected invalidBundle, got \(error)")
            }
            XCTAssertTrue(message.contains("0.122.0"))
            XCTAssertTrue(message.contains("0.129.0"))
        }

        // Installing under the matching version succeeds, and becomes incompatible once Tab updates.
        let matchingInstaller = PluginInstaller(dirs: dirs, version: "0.122.0", isDebugBuild: true, localSearchDirectories: [sourceDir])
        _ = try await matchingInstaller.install(PluginCatalog.explorer)
        XCTAssertTrue(matchingInstaller.isBundleCompatible(.explorer))
        XCTAssertEqual(matchingInstaller.installedBundleVersion(.explorer), "0.122.0")
        XCTAssertFalse(staleInstaller.isBundleCompatible(.explorer))
    }

    func testLoadInstalledRefusesStaleBundleVersion() async throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }

        var settings = Settings()
        settings.plugins.markInstalled(.explorer)
        try settings.savePlugins(to: dirs.settings)

        // Place an outdated 0.122.0 bundle on disk in TAB_DIR/Plugins/.
        try writeFakeBundle(id: "explorer", executable: "TabExplorerPlugin", principal: "TabExplorerPluginFactory",
                            version: "0.122.0", into: dirs.plugins)

        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in nil }
        model.plugins.installer = PluginInstaller(
            dirs: dirs,
            version: "0.129.0",
            isDebugBuild: false,
            localSearchDirectories: [],
            download: { _ in throw PluginError.downloadFailed("offline") }
        )

        model.plugins.loadInstalled()
        XCTAssertFalse(model.plugins.isActive(.explorer))
        await settle {
            if case .failed = model.plugins.state(of: .explorer) { return true }
            return false
        }
        XCTAssertFalse(model.plugins.isActive(.explorer))
    }

    func testChromeButtonDrawsSignatureIconsMonochrome() throws {
        // Icons like .git (vermilion) and .folder (gray) carry signature hues for file trees
        // and brand marks, but ChromeButton must always tint them with the chrome foreground.
        let theme = AppTheme.shared
        let expected = theme.fgMuted.usingColorSpace(.sRGB)!
        for icon in [AppIcon.folder, .file, .git, .gitBranch, .gitGraph, .chartLine] {
            let button = ChromeButton(icon, label: icon.rawValue)
            let image = try XCTUnwrap(button.image)
            let color = try XCTUnwrap(dominantOpaqueColor(of: image))
            XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.05, "\(icon) red mismatch")
            XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.05, "\(icon) green mismatch")
            XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.05, "\(icon) blue mismatch")
        }
    }

    private func writeFakeBundle(
        id: String,
        executable: String,
        principal: String,
        version: String,
        into directory: URL
    ) throws {
        let bundle = directory.appendingPathComponent("\(id).bundle", isDirectory: true)
        let macOSDir = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let exec = macOSDir.appendingPathComponent(executable)
        try Data("#!/bin/sh\n".utf8).write(to: exec)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
        let plist: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": "com.hugocorta.tab.plugin.\(id)",
            "NSPrincipalClass": principal,
            "TabPluginId": id,
            "TabPluginVersion": version,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    private func dominantOpaqueColor(of image: NSImage) -> NSColor? {
        let size = NSSize(width: 34, height: 34)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        var best: NSColor?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.1 else {
                    continue
                }
                if best == nil || pixel.alphaComponent > best!.alphaComponent {
                    best = pixel
                }
            }
        }
        return best
    }
||||||| Stash base
=======
    func testPluginInstallerRejectsVersionAndBuildMismatches() async throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }

        let sourceDir = dirs.root.appendingPathComponent("source-plugins", isDirectory: true)
        let bundle = try makeFakeBundle(
            in: sourceDir,
            id: "diff",
            executable: "TabDiffPlugin",
            principal: "TabDiffPluginFactory",
            version: "0.122.0",
            build: "100"
        )

        // Matching version + build succeeds.
        let matching = PluginInstaller(
            dirs: dirs, version: "0.122.0", buildNumber: "100",
            isDebugBuild: true, localSearchDirectories: [sourceDir]
        )
        XCTAssertTrue(matching.isBundleCompatible(at: bundle))
        try matching.validateBundle(at: bundle, descriptor: PluginCatalog.diff)

        // Newer app version rejects older plugin bundle.
        let newerVersion = PluginInstaller(
            dirs: dirs, version: "0.129.0", buildNumber: "100",
            isDebugBuild: true, localSearchDirectories: [sourceDir]
        )
        XCTAssertFalse(newerVersion.isBundleCompatible(at: bundle))
        XCTAssertThrowsError(try newerVersion.validateBundle(at: bundle, descriptor: PluginCatalog.diff)) { error in
            guard case PluginError.incompatibleVersion = error else {
                return XCTFail("Expected incompatibleVersion, got \(error)")
            }
        }

        // Same version but different build number rejects stale plugin bundle.
        let newerBuild = PluginInstaller(
            dirs: dirs, version: "0.122.0", buildNumber: "101",
            isDebugBuild: true, localSearchDirectories: [sourceDir]
        )
        XCTAssertFalse(newerBuild.isBundleCompatible(at: bundle))
        XCTAssertThrowsError(try newerBuild.validateBundle(at: bundle, descriptor: PluginCatalog.diff)) { error in
            guard case PluginError.incompatibleVersion = error else {
                return XCTFail("Expected incompatibleVersion, got \(error)")
            }
        }
    }

    func testLoadInstalledUpdatesOutdatedBundleInsteadOfLoadingIt() async throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }

        // Place an outdated diff.bundle (0.122.0) directly in TAB_DIR/Plugins/.
        _ = try makeFakeBundle(
            in: dirs.plugins,
            id: "diff",
            executable: "TabDiffPlugin",
            principal: "TabDiffPluginFactory",
            version: "0.122.0",
            build: "100"
        )

        var settings = Settings()
        settings.plugins.markInstalled(.diff)
        try settings.savePlugins(to: dirs.settings)

        let requestedURL = Box<URL?>(nil)
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in nil }
        model.plugins.installer = PluginInstaller(
            dirs: dirs,
            version: "0.129.0",
            buildNumber: "120",
            isDebugBuild: false,
            localSearchDirectories: [],
            download: { url in
                requestedURL.value = url
                throw PluginError.downloadFailed("offline")
            }
        )

        model.plugins.loadInstalled()
        XCTAssertFalse(model.plugins.isActive(.diff))
        await settle {
            if case .failed = model.plugins.state(of: .diff) { return true }
            return false
        }
        XCTAssertEqual(
            requestedURL.value?.lastPathComponent,
            "TabPlugin-diff-0.129.0-arm64.zip",
            "Outdated installed plugin must trigger a download for the current app version"
        )
        guard case .failed(let message) = model.plugins.state(of: .diff) else {
            return XCTFail("Expected failed state after offline update attempt, got \(model.plugins.state(of: .diff))")
        }
        XCTAssertTrue(message.contains("offline"))
    }

    func testHasNewerLocalBundleDetectsFreshDebugRebuild() throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }

        let installed = try makeFakeBundle(
            in: dirs.plugins,
            id: "diff",
            executable: "TabDiffPlugin",
            principal: "TabDiffPluginFactory",
            version: "0.129.0",
            build: "120"
        )
        let sourceDir = dirs.root.appendingPathComponent("local-plugins", isDirectory: true)
        let local = try makeFakeBundle(
            in: sourceDir,
            id: "diff",
            executable: "TabDiffPlugin",
            principal: "TabDiffPluginFactory",
            version: "0.129.0",
            build: "120"
        )

        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_000_100)
        try FileManager.default.setAttributes(
            [.modificationDate: olderDate],
            ofItemAtPath: installed.appendingPathComponent("Contents/MacOS/TabDiffPlugin").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: newerDate],
            ofItemAtPath: local.appendingPathComponent("Contents/MacOS/TabDiffPlugin").path
        )

        let installer = PluginInstaller(
            dirs: dirs, version: "0.129.0", buildNumber: "120",
            isDebugBuild: true, localSearchDirectories: [sourceDir]
        )
        XCTAssertTrue(installer.hasNewerLocalBundle(for: PluginCatalog.diff))
    }

    private func makeFakeBundle(
        in directory: URL,
        id: String,
        executable: String,
        principal: String,
        version: String,
        build: String
    ) throws -> URL {
        let bundle = directory.appendingPathComponent("\(id).bundle", isDirectory: true)
        let macOSDir = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let exec = macOSDir.appendingPathComponent(executable)
        try Data("#!/bin/sh\n".utf8).write(to: exec)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
        let plist: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": "com.hugocorta.tab.plugin.\(id)",
            "CFBundleVersion": build,
            "NSPrincipalClass": principal,
            "TabPluginId": id,
            "TabPluginVersion": version,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
>>>>>>> Stashed changes
}
