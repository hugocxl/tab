import XCTest
import TabCore
@testable import TabApp
@testable import TabQuickShotPlugin

@MainActor
final class QuickShotPluginTests: XCTestCase {
    func testConfigPersistsInSettingsAndToleratesUnknownValues() throws {
        let dirs = try ModelFixtures.profile()
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }

        var settings = Settings()
        settings.plugins.markInstalled(.quickshot)
        let config = QuickShotConfig(
            trigger: .shortcut, shortcut: try KeyChord("ctrl-alt-cmd-s"),
            destination: .temporary, clipboard: .image, playsSound: false, showsPreview: false
        )
        try settings.plugins.encodeConfig(config, for: .quickshot)
        try settings.savePlugins(to: dirs.settings)

        let reloaded = try Settings.load(dirs.settings)
        XCTAssertEqual(reloaded.plugins.installed, [.quickshot])
        XCTAssertEqual(QuickShotConfig.current(in: reloaded), config)

        // A newer or hand-edited file: unknown keys, an unknown choice and a bad chord.
        let edited = Data(#"""
        {"plugins":{"installed":["quickshot"],"config":{"quickshot":
          {"trigger":"tripleTap","shortcut":"not a chord","destination":"temporary","future":[1,{"a":null}]}}}}
        """#.utf8)
        let decoded = QuickShotConfig.current(in: try Settings.decode(edited))
        XCTAssertEqual(decoded.trigger, .commandKeys)
        XCTAssertNil(decoded.shortcut)
        XCTAssertEqual(decoded.destination, .temporary)
        XCTAssertEqual(decoded.clipboard, .path)
        XCTAssertTrue(decoded.playsSound)

        // Older files have no config at all.
        XCTAssertEqual(QuickShotConfig.current(in: Settings()), QuickShotConfig())
    }

    func testOtherPluginsConfigSurvivesSavingQuickShotConfig() throws {
        var plugins = PluginSettings()
        plugins.config["other"] = .object(["keep": .array([.int(1), .string("x"), .bool(true), .null])])
        try plugins.encodeConfig(QuickShotConfig(), for: .quickshot)
        let data = try JSONEncoder().encode(plugins)
        let decoded = try JSONDecoder().decode(PluginSettings.self, from: data)
        XCTAssertEqual(decoded.config["other"], plugins.config["other"])
        XCTAssertNotNil(decoded.decodeConfig(QuickShotConfig.self, for: .quickshot))
    }

    func testExpiredCaptureCleanupOnlyRemovesOldQuickShotPNGs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let old = now.addingTimeInterval(-25 * 60 * 60)
        func make(_ name: String, modified: Date) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let expired = try make("QuickShot-old.png", modified: old)
        let fresh = try make("QuickShot-new.png", modified: now)
        let foreign = try make("Notes.png", modified: old)
        let otherType = try make("QuickShot-old.txt", modified: old)
        let link = folder.appendingPathComponent("QuickShot-link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)

        try QuickShotCapture.removeExpiredCaptures(in: folder, now: now)

        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        XCTAssertFalse(exists(expired))
        XCTAssertTrue(exists(fresh))
        XCTAssertTrue(exists(foreign))
        XCTAssertTrue(exists(otherType))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testCommandChordFiresOncePerPressAndIgnoresOtherModifiers() {
        var detector = CommandChordDetector()
        XCTAssertFalse(detector.update(leftDown: true, rightDown: false, otherModifierDown: false))
        XCTAssertTrue(detector.update(leftDown: true, rightDown: true, otherModifierDown: false))
        XCTAssertFalse(detector.update(leftDown: true, rightDown: true, otherModifierDown: false), "Holding must not repeat")
        XCTAssertFalse(detector.update(leftDown: false, rightDown: false, otherModifierDown: false))

        // Shift held during the chord, or ⌘ used to type a key, cancels it until release.
        XCTAssertFalse(detector.update(leftDown: true, rightDown: false, otherModifierDown: true))
        XCTAssertFalse(detector.update(leftDown: true, rightDown: true, otherModifierDown: false))
        _ = detector.update(leftDown: false, rightDown: false, otherModifierDown: false)
        _ = detector.update(leftDown: true, rightDown: false, otherModifierDown: false)
        detector.cancel()
        XCTAssertFalse(detector.update(leftDown: true, rightDown: true, otherModifierDown: false))

        // Keys already held when the listener reconnects don't count as a press.
        detector.resynchronize(leftDown: true, rightDown: true)
        XCTAssertFalse(detector.update(leftDown: true, rightDown: true, otherModifierDown: false))
    }

    func testShortcutRulesRejectTypingKeysAndTabShortcuts() throws {
        let keymap = Keymap()
        XCTAssertNotNil(QuickShotShortcutRules.problem(with: try KeyChord("shift-s"), keymap: keymap))
        XCTAssertNotNil(QuickShotShortcutRules.problem(with: try KeyChord("s"), keymap: keymap))
        XCTAssertNotNil(QuickShotShortcutRules.problem(with: try KeyChord("fn-cmd-s"), keymap: keymap))
        let taken = try XCTUnwrap(keymap.chord(.newTab))
        XCTAssertNotNil(QuickShotShortcutRules.problem(with: taken, keymap: keymap))
        XCTAssertNil(QuickShotShortcutRules.problem(with: try KeyChord("ctrl-alt-cmd-s"), keymap: keymap))
        XCTAssertNil(QuickShotShortcutRules.problem(with: try KeyChord("ctrl-alt-cmd-f5"), keymap: keymap))
    }

    func testActivationRegistersConfigurationPageAndUninstallRemovesIt() throws {
        let dirs = try ModelFixtures.profile()
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in nil }
        addTeardownBlock { try? FileManager.default.removeItem(at: dirs.root) }
        XCTAssertFalse(model.plugins.hasSettingsView(for: .quickshot))

        let plugin = QuickShotPlugin()
        model.plugins.activate(plugin: plugin)
        XCTAssertTrue(model.plugins.hasSettingsView(for: .quickshot))
        XCTAssertTrue(model.rightSidebarPanels.isEmpty, "QuickShot adds no sidebar panel")

        // A settings change reaches the plugin without reloading it.
        var settings = model.settings
        let config = QuickShotConfig(trigger: .shortcut, shortcut: nil, destination: .temporary)
        try settings.plugins.encodeConfig(config, for: .quickshot)
        model.apply(settings: settings)
        XCTAssertEqual(plugin.config, config)
        XCTAssertEqual(plugin.status.trigger, .unavailable("Record a shortcut"))

        model.plugins.deactivate(.quickshot)
        XCTAssertFalse(model.plugins.hasSettingsView(for: .quickshot))
    }
}
