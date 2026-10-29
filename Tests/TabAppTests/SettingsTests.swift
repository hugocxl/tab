import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class SettingsTests: XCTestCase {
    private var root: URL!
    private var dirs: TabDirs!
    private var host: PreviewSettingsHost!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dirs = TabDirs(root: root)
        host = PreviewSettingsHost()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(dirs: dirs, host: host, theme: AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true))
    }

    // MARK: Search

    func testSearchFindsEverySettingByItsLabel() {
        let commands = [CustomCommand(id: "tests", name: "Run tests", command: "swift test")]
        let index = SettingsCatalog.searchIndex(commands: commands)
        XCTAssertEqual(Set(index.map(\.id)).count, index.count, "row ids must be unique")
        for item in index {
            let results = SettingsCatalog.search(item.label, commands: commands)
            XCTAssertTrue(results.contains(item), "searching “\(item.label)” misses \(item.id)")
        }
        XCTAssertEqual(SettingsCatalog.search("Run tests", commands: commands).first?.id, "command.tests")
        XCTAssertTrue(SettingsCatalog.search("ligatures", commands: []).contains { $0.id == "font-ligatures" })
        XCTAssertTrue(SettingsCatalog.search("zzz-no-such-setting", commands: []).isEmpty)
    }

    func testEveryRowAPageShowsIsInTheSearchIndex() async throws {
        let store = makeStore()
        store.updateRemoteAccess(RemoteAccessState(revision: 1, settings: RemoteAccessSettings(enabled: true), status: .listening))
        store.loadServerSettings()
        try await Task.sleep(nanoseconds: 50_000_000)
        let page = SettingsPageView(store: store)
        var shown = Set<String>()
        for category in SettingsCategory.allCases {
            page.category = category
            page.reload()
            let build = try XCTUnwrap(page.lastBuild)
            XCTAssertEqual(build.unknownIds, [], "\(category) shows rows missing from the catalog")
            XCTAssertFalse(build.groups.isEmpty, "\(category) shows nothing")
            shown.formUnion(build.rowIds)
        }
        let conditional: Set<String> = ["terminal-import-notes"]
        for item in SettingsCatalog.items where !conditional.contains(item.id) && item.id != "add-command" {
            XCTAssertTrue(shown.contains(item.id), "\(item.id) is in the catalog but no page shows it")
        }

        page.query = "font"
        page.reload()
        let search = try XCTUnwrap(page.lastBuild)
        XCTAssertTrue(search.rowIds.contains("font-family"))
        XCTAssertTrue(search.rowIds.contains("shortcut.increase_font_size"))
        XCTAssertFalse(search.rowIds.contains("width"))
    }

    // MARK: Keyboard

    func testRecordingAShortcutRefusesConflicts() throws {
        let store = makeStore()
        let taken = try XCTUnwrap(store.settings.keymap.binding("split_down"))
        let before = store.settings.keymap

        let error = store.setBinding("split_right", taken)
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("already used") ?? false, error ?? "")
        XCTAssertEqual(store.settings.keymap, before)
        XCTAssertEqual(store.errors["split_right"], error)
        XCTAssertNil(try Settings.load(dirs.settings).keymap.overrides["split_right"])

        let free = try KeyChord("cmd-ctrl-alt-shift-f9")
        XCTAssertNil(store.setBinding("split_right", free))
        XCTAssertEqual(try Settings.load(dirs.settings).keymap.binding("split_right"), free)
        XCTAssertFalse(store.settings.keymap.isDefault("split_right"))
        XCTAssertEqual(host.appliedSettings.last?.keymap.binding("split_right"), free)

        XCTAssertNil(store.setBinding("split_right", nil))
        XCTAssertTrue(store.settings.keymap.isDefault("split_right"))
    }

    func testRecorderRejectsAConflictAndKeepsItsChord() throws {
        let store = makeStore()
        let page = SettingsPageView(store: store)
        let original = store.settings.keymap.binding("split_right")
        let recorder = page.shortcutRecorder(rowId: "shortcut.split_right", action: "split_right", chord: original, placeholder: "Not assigned", label: "Split right")
        recorder.record(try XCTUnwrap(store.settings.keymap.binding("split_down")))
        XCTAssertEqual(recorder.chord, original)
        XCTAssertNotNil(store.errors["shortcut.split_right"])
    }

    func testCommandShortcutsNeedAModifier() throws {
        let store = makeStore()
        XCTAssertTrue(store.saveCommand(CustomCommand(id: "build", name: "Build", command: "make")))
        XCTAssertNotNil(store.setBinding("command.build", try KeyChord("f5")))
        XCTAssertNil(store.setBinding("command.build", try KeyChord("cmd-alt-ctrl-b")))
        store.removeCommand("build")
        XCTAssertNil(store.settings.keymap.binding("command.build"))
        XCTAssertTrue(try Settings.load(dirs.settings).commands.isEmpty)
    }

    // MARK: Saving

    func testChangesSaveImmediatelyAndKeepOtherSections() throws {
        try Data(#"{"futureSection": {"kept": true}}"#.utf8).write(to: dirs.settings)
        let store = makeStore()
        store.setCloseBehavior(.detach)
        store.setWindowSize("width", "1400")
        store.setWindowSize("height", "12")
        store.updateAppearance("agents-panel-grouping") { $0.agentsPanelGrouping = .worktrees }

        let saved = try Settings.load(dirs.settings)
        XCTAssertEqual(saved.window.closeBehavior, .detach)
        XCTAssertEqual(saved.window.defaultSize.width, 1400)
        XCTAssertEqual(saved.window.defaultSize.height, 800, "an invalid height is refused")
        XCTAssertNotNil(store.errors["height"])
        XCTAssertEqual(saved.appearance.agentsPanelGrouping, .worktrees)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: dirs.settings)) as? [String: Any]
        XCTAssertNotNil(raw?["futureSection"])
    }

    func testTerminalPreviewDoesNotSaveUntilCommitted() throws {
        let store = makeStore()
        store.previewTerminal("font-size", "20")
        XCTAssertEqual(host.previews.last?.fontSize, 20)
        XCTAssertEqual(try TerminalSettings.load(dirs.terminalSettings).fontSize, TerminalSettings.defaultFontSize)
        store.setTerminal("font-size", "20")
        XCTAssertEqual(try TerminalSettings.load(dirs.terminalSettings).fontSize, 20)
        XCTAssertEqual(host.appliedTerminal.last?.fontSize, 20)
        XCTAssertTrue(store.terminalIsCustomized)
        store.resetTerminal()
        XCTAssertFalse(store.terminalIsCustomized)
    }

    func testBrokenTerminalFileKeepsLastGoodSettings() throws {
        let store = makeStore()
        store.setTerminal("font-size", "15")
        try Data("{ not json".utf8).write(to: dirs.terminalSettings)
        store.reloadTerminal()
        XCTAssertEqual(store.terminal.fontSize, 15)
        XCTAssertNotNil(store.errors["configuration"])

        var fixed = TerminalSettings()
        fixed.fontSize = 17
        try JSONEncoder().encode(fixed).write(to: dirs.terminalSettings)
        store.reloadTerminal()
        XCTAssertEqual(store.terminal.fontSize, 17)
        XCTAssertNil(store.errors["configuration"])
        XCTAssertEqual(host.appliedTerminal.last?.fontSize, 17)
    }

    // MARK: Backup

    func testBackupRoundTripAndRestore() throws {
        let store = makeStore()
        store.setCloseBehavior(.detach)
        store.setTerminal("font-size", "18")
        try FileManager.default.createDirectory(at: dirs.themes, withIntermediateDirectories: true)
        try Data("background = #000000\nforeground = #ffffff\n".utf8).write(to: dirs.themes.appendingPathComponent("Mine"))
        try Data(#"{"shell":"/bin/zsh"}"#.utf8).write(to: dirs.serverSettings)
        try Data(#"{"secret":true}"#.utf8).write(to: dirs.proxy)
        host.state = Data(#"{"projects":[{"name":"a"},{"name":"b"}]}"#.utf8)

        let file = root.appendingPathComponent("export.tab")
        store.exportBackup(to: file)
        XCTAssertNil(store.errors["backup-export"])
        let archive = try BackupArchive.read(file)
        XCTAssertEqual(archive.files["settings.json"], try Data(contentsOf: dirs.settings))
        XCTAssertEqual(archive.files["themes/Mine"].map { String(decoding: $0, as: UTF8.self) }, "background = #000000\nforeground = #ffffff\n")
        XCTAssertNil(archive.files["proxy.json"], "proxy settings are never backed up")
        XCTAssertNil(archive.files["remote.json"], "paired devices are never backed up")
        XCTAssertEqual(archive.projectCount, 2)
        XCTAssertEqual(try BackupArchive(data: archive.encoded()), archive)

        // Change things, then restore the backup at the next launch.
        store.setCloseBehavior(.closeSession)
        store.restoreBackup(from: file)
        XCTAssertTrue(BackupArchive.hasPending(dirs))
        var merged: (Data, Data?)?
        let recovery = try BackupArchive.applyPending(in: dirs) { imported, current in
            merged = (imported, current)
            return imported
        }
        XCTAssertFalse(BackupArchive.hasPending(dirs))
        XCTAssertEqual(try Settings.load(dirs.settings).window.closeBehavior, .detach)
        XCTAssertEqual(try TerminalSettings.load(dirs.terminalSettings).fontSize, 18)
        XCTAssertEqual(merged?.0, host.state)
        let recovered = try Settings.decode(Data(contentsOf: try XCTUnwrap(recovery).appendingPathComponent("settings.json")))
        XCTAssertEqual(recovered.window.closeBehavior, .closeSession, "the replaced settings are kept in Backups")
        XCTAssertNotNil(try? Data(contentsOf: dirs.proxy), "restore leaves proxy settings alone")
    }

    func testBackupRefusesUnexpectedFiles() throws {
        var archive = BackupArchive(files: ["settings.json": Data("{}".utf8)])
        XCTAssertNoThrow(try archive.validate())
        archive.files["../escape"] = Data()
        XCTAssertThrowsError(try archive.validate())
        archive.files = ["settings.json": Data("{}".utf8), "themes/../x": Data()]
        XCTAssertThrowsError(try archive.validate())
        XCTAssertThrowsError(try BackupArchive(data: Data("{\"format\":\"other\"}".utf8)))
    }

    // MARK: Window

    func testWindowOpensEveryPageWithoutAnApp() throws {
        let store = makeStore()
        let controller = SettingsWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frame.size.width, SettingsWindowController.defaultSize.width, accuracy: 1)
        for category in SettingsCategory.allCases {
            controller.select(category, section: nil)
            XCTAssertEqual(controller.category, category)
            XCTAssertEqual(controller.page.titleLabel.stringValue, category.title)
            XCTAssertEqual(controller.page.editLink?.title, category.configurationFile.map { "Edit in \($0)" })
            XCTAssertEqual(controller.page.lastBuild?.unknownIds, [])
        }
        controller.select(.general, section: "Window size")
        XCTAssertEqual(Set(controller.page.lastBuild?.rowIds ?? []), ["width", "height"])
        XCTAssertTrue(controller.sidebar.items.contains { $0.section == "Window size" && $0.isSelected })

        controller.search("theme")
        XCTAssertTrue(controller.page.lastBuild?.rowIds.contains("dark-theme") ?? false)
        XCTAssertFalse(controller.sidebar.items.contains { $0.isSelected })

        controller.page.editLink?.performClick()
        controller.select(.terminal, section: nil)
        controller.page.editLink?.performClick()
        XCTAssertEqual(host.openedFiles.map(\.lastPathComponent), ["terminal.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirs.terminalSettings.path))
    }

    func testServerTileFollowsTheHost() {
        let store = makeStore()
        let controller = SettingsWindowController(store: store)
        XCTAssertEqual(controller.sidebar.serverTile.stateText, "Running")
        store.updateServerState(.stopped)
        controller.reload()
        XCTAssertEqual(controller.sidebar.serverTile.stateText, "Stopped")
    }
}

extension LinkButton {
    func performClick() { _ = accessibilityPerformPress() }
}
