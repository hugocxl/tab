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
        let index = SettingsCatalog.searchIndex()
        XCTAssertEqual(Set(index.map(\.id)).count, index.count, "row ids must be unique")
        for item in index {
            let results = SettingsCatalog.search(item.label)
            XCTAssertTrue(results.contains(item), "searching “\(item.label)” misses \(item.id)")
        }
        XCTAssertTrue(SettingsCatalog.search("ligatures").contains { $0.id == "font-ligatures" })
        XCTAssertTrue(SettingsCatalog.search("zzz-no-such-setting").isEmpty)
    }

    func testEveryRowAPageShowsIsInTheSearchIndex() async throws {
        let store = makeStore()
        store.updateRemoteAccess(RemoteAccessState(revision: 1, settings: RemoteAccessSettings(enabled: true), status: .listening))
        store.loadServerSettings()
        try await Task.sleep(nanoseconds: 50_000_000)
        let page = SettingsModel(store: store)
        var shown = Set<String>()
        for category in SettingsCategory.allCases {
            page.select(category)
            let build = try XCTUnwrap(page.lastBuild)
            XCTAssertEqual(build.unknownIds, [], "\(category) shows rows missing from the catalog")
            XCTAssertTrue(category == .changelog || !build.groups.isEmpty, "\(category) shows nothing")
            shown.formUnion(build.rowIds)
        }
        let conditional: Set<String> = ["terminal-import-notes"]
        for item in SettingsCatalog.items where !conditional.contains(item.id) {
            XCTAssertTrue(shown.contains(item.id), "\(item.id) is in the catalog but no page shows it")
        }

        page.search("font")
        let search = try XCTUnwrap(page.lastBuild)
        XCTAssertTrue(search.rowIds.contains("font-family"))
        XCTAssertTrue(search.rowIds.contains("shortcut.increase_font_size"))
        XCTAssertFalse(search.rowIds.contains("close-behavior"))
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
        let page = SettingsModel(store: store)
        let original = store.settings.keymap.binding("split_right")
        guard case .shortcut(let spec) = page.shortcutRecorder(rowId: "shortcut.split_right", action: "split_right", chord: original, placeholder: "Not assigned", label: "Split right") else {
            return XCTFail("not a recorder")
        }
        let recorder = ShortcutRecorder(chord: spec.chord, placeholder: spec.placeholder, label: spec.label)
        recorder.onRecord = spec.record
        recorder.onError = spec.error
        recorder.record(try XCTUnwrap(store.settings.keymap.binding("split_down")))
        XCTAssertEqual(recorder.chord, original)
        XCTAssertNotNil(store.errors["shortcut.split_right"])
    }

    // MARK: Saving

    func testChangesSaveImmediatelyAndKeepOtherSections() throws {
        try Data(#"{"futureSection": {"kept": true}}"#.utf8).write(to: dirs.settings)
        let store = makeStore()
        store.setCloseBehavior(.detach)
        store.updateAppearance("sidebar") { $0.sidebarExpanded = false }

        let saved = try Settings.load(dirs.settings)
        XCTAssertEqual(saved.window.closeBehavior, .detach)
        XCTAssertFalse(saved.appearance.sidebarExpanded)
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

    func testBrokenTerminalFileIsReportedAndNeverOverwritten() throws {
        let broken = Data("{ not json".utf8)
        try broken.write(to: dirs.terminalSettings)
        let store = makeStore()
        XCTAssertNotNil(store.errors["configuration"])
        store.setTerminal("font-size", "15")
        XCTAssertEqual(try Data(contentsOf: dirs.terminalSettings), broken)
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
        var state = try AppState.bootstrap()
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try state.addProject(server: .local, directory: project.path)
        host.state = try AppStateStore.encode(state)

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
            controller.select(category)
            XCTAssertEqual(controller.category, category)
            XCTAssertEqual(controller.model.title, category.title)
            XCTAssertEqual(controller.model.selection, category)
            XCTAssertEqual(controller.model.lastBuild?.unknownIds, [])
        }

        controller.search("theme")
        XCTAssertTrue(controller.model.lastBuild?.rowIds.contains("dark-theme") ?? false)
        XCTAssertNil(controller.model.selection)
        XCTAssertEqual(controller.model.title, "Search")
        controller.select(.general)
        XCTAssertEqual(controller.model.query, "", "opening a page ends the search")
        XCTAssertTrue(controller.model.lastBuild?.rowIds.contains("close-behavior") ?? false)
    }

    func testBackAndForwardWalkVisitedPages() {
        let model = SettingsModel(store: makeStore())
        XCTAssertFalse(model.canGoBack)
        model.select(.terminal)
        model.select(.mobile)
        model.select(.mobile)
        model.select(.backup)
        model.goBack()
        XCTAssertEqual(model.category, .mobile)
        model.goBack()
        XCTAssertEqual(model.category, .terminal)
        XCTAssertTrue(model.canGoForward)
        model.goForward()
        XCTAssertEqual(model.category, .mobile)
        model.select(.backup)
        XCTAssertFalse(model.canGoForward, "a new page drops the forward pages")
        model.goBack()
        model.goBack()
        model.goBack()
        XCTAssertEqual(model.category, .general)
        XCTAssertFalse(model.canGoBack)
    }

    func testSidebarListsEveryPageOnceWithoutTheServerRow() {
        let listed = SettingsSidebar.groups.flatMap { $0 }
        XCTAssertEqual(Set(listed), Set(SettingsCategory.allCases).subtracting([.server]))
        XCTAssertEqual(listed.count, Set(listed).count)
        XCTAssertEqual(SettingsSidebar.groups.map { $0.first }, [.general, .terminal, .browser, .backup])
        XCTAssertEqual(SettingsSidebar.groups.last?.last, .changelog)
    }
}
