import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class SettingsStoreRegressionTests: XCTestCase {
    private var root: URL!
    private var dirs: TabDirs!
    private var host: SettingsWriteHost!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-writes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dirs = TabDirs(root: root)
        host = SettingsWriteHost()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store() -> SettingsStore {
        SettingsStore(dirs: dirs, host: host)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Settings work did not finish")
    }

    func testServerWritesKeepBothEditsAndDoNotResaveARejectedValue() async throws {
        let store = store()
        store.loadServerSettings()
        try await settle { store.serverSettings != nil }
        host.rejectNextServerWrite = true
        store.setServer("startup-command", "/bin/bash")
        try await settle { host.writes.count == 1 && store.errors["startup-command"] != nil }
        XCTAssertNotNil(store.errors["startup-command"])
        XCTAssertEqual(store.serverSettings?.startupCommand, [])
        store.setServer("startup-command", #"tmux new -A -s "my work""#)
        try await settle { host.writes.count == 2 && store.serverSettings?.startupCommand.isEmpty == false }
        XCTAssertNil(store.errors["startup-command"])
        XCTAssertEqual(host.base.serverSettings.startupCommand, ["tmux", "new", "-A", "-s", "my work"])
        XCTAssertEqual(store.serverSettings, host.base.serverSettings)
        store.setServer("startup-command", #"zsh "unclosed"#)
        XCTAssertNotNil(store.errors["startup-command"])
        XCTAssertEqual(host.writes.count, 2, "a command that doesn't parse is never written")
    }

    func testMobileWriteFailureClearsBusyAndCanBeRetried() async throws {
        let store = store()
        store.loadRemoteAccess()
        try await settle { store.remoteAccess != nil }
        host.rejectNextMobileWrite = true
        store.setMobileEnabled(true)
        try await settle { !store.mobileBusy }
        XCTAssertNotNil(store.errors["mobile-access"])
        XCTAssertEqual(store.remoteAccess?.settings.enabled, false)
        store.setMobileEnabled(true)
        try await settle { !store.mobileBusy }
        XCTAssertNil(store.errors["mobile-access"])
        XCTAssertEqual(store.remoteAccess?.settings.enabled, true)
        XCTAssertEqual(store.remoteAccess?.settings, host.base.remoteAccess.settings)
    }

    func testPairingIsCancelledWhenItsCodeLeavesTheScreen() async throws {
        host.base.remoteAccess.settings.enabled = true
        let store = store()
        let controller = SettingsWindowController(store: store)
        controller.select(.mobile)
        try await settle { store.remoteAccess != nil }
        store.startPairing()
        try await settle { store.pairing != nil }
        controller.select(.general)
        try await settle { host.cancelledPairings == 1 }
        XCTAssertNil(store.pairing)
        controller.select(.mobile)
        store.startPairing()
        try await settle { store.pairing != nil }
        controller.window?.close()
        try await settle { host.cancelledPairings == 2 }
        XCTAssertNil(store.pairing)
    }

    func testClosingSettingsBeforeThePairingReplyDoesNotExposeACode() async throws {
        host.base.remoteAccess.settings.enabled = true
        host.delayPairing = true
        let store = store()
        let controller = SettingsWindowController(store: store)
        controller.select(.mobile)
        try await settle { store.remoteAccess != nil }
        store.startPairing()
        try await settle { host.pairingStarted }
        controller.window?.close()
        try await settle { host.cancelledPairings == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.pairing)
        XCTAssertFalse(store.pairingBusy)
        XCTAssertFalse(store.mobileBusy)
    }

    func testSearchLoadsServerAndMobileControlsBeforeVisitingTheirPages() async throws {
        let store = store()
        let controller = SettingsWindowController(store: store)
        defer { controller.window?.close() }
        try await settle { store.serverSettings != nil && store.remoteAccess != nil }
        controller.search("Startup command")
        XCTAssertEqual(controller.model.lastBuild?.rowIds, ["startup-command"])
        controller.search("Allow mobile devices")
        XCTAssertEqual(controller.model.lastBuild?.rowIds, ["mobile-access"])
    }

    func testClosingSettingsSavesFieldsBeingTyped() throws {
        let controller = SettingsWindowController(store: store())
        for (category, id, text) in [(SettingsCategory.general, "worktree-template", "../{branch}")] {
            controller.select(category)
            let field = try XCTUnwrap(controller.model.fields[id])
            controller.model.editing(id) { field.commit(text) }
        }
        controller.window?.close()
        XCTAssertEqual(try Settings.load(dirs.settings).worktrees.defaultLocation.pathTemplate, "../{branch}")
    }

    private func buttons(in control: SettingControl?) -> [ButtonSpec] {
        (control?.leaves ?? []).compactMap {
            if case .button(let button) = $0 { return button }
            return nil
        }
    }

    private func buttons(on page: SettingsModel) -> [ButtonSpec] {
        (page.lastBuild?.rows ?? []).flatMap { buttons(in: $0.control) }
    }

    func testProfileRenameEnablesWhileTypingAndDefaultSavesToBrowserSettings() throws {
        host.base.profiles.append(BrowserProfileSummary(id: "work", name: "Work"))
        let store = store()
        store.refreshBrowserProfiles()
        let page = SettingsModel(store: store)
        page.select(.browser)
        let field = try XCTUnwrap(page.fields["browser-profiles"])
        XCTAssertFalse(try XCTUnwrap(buttons(on: page).last { $0.title == "Rename to Name Below" }).enabled)
        field.change?("Personal")
        let rename = try XCTUnwrap(buttons(on: page).last { $0.title == "Rename to Name Below" })
        XCTAssertTrue(rename.enabled)
        rename.action()
        XCTAssertEqual(host.base.profiles.last?.name, "Personal")
        page.reload()
        let makeDefault = try XCTUnwrap(buttons(on: page).first { $0.title == "Make Default" })
        makeDefault.action()
        XCTAssertEqual(try Settings.load(dirs.settings).browser.defaultProfile, "work")
        XCTAssertEqual(store.settings.browser.defaultProfile, "work")
    }

    func testRefusedShortcutResetShowsItsErrorOnTheKeyboardRow() throws {
        let store = store()
        let original = try XCTUnwrap(store.settings.keymap.binding("split_right"))
        XCTAssertNil(store.setBinding("split_right", try KeyChord("cmd-ctrl-alt-f9")))
        XCTAssertNil(store.setBinding("split_down", original))
        let page = SettingsModel(store: store)
        page.select(.keyboard)
        let row = try XCTUnwrap(page.lastBuild?.rows.first { $0.id == "shortcut.split_right" })
        let reset = try XCTUnwrap(buttons(in: row.control).first)
        reset.action()
        XCTAssertNotNil(store.errors["shortcut.split_right"])
        XCTAssertEqual(try Settings.load(dirs.settings).keymap, store.settings.keymap)
        XCTAssertFalse(store.settings.keymap.isDefault("split_right"))
    }

    func testRefusedTerminalChangesKeepTheSavedFileAndShowOnTheRow() throws {
        let store = store()
        store.updateTerminal("font-size") { $0.fontSize = 20 }
        let saved = try Data(contentsOf: dirs.terminalSettings)
        store.updateTerminal("font-size") { $0.fontSize = 500 }
        XCTAssertNotNil(store.errors["font-size"])
        XCTAssertEqual(store.terminal.fontSize, 20)
        XCTAssertEqual(try Data(contentsOf: dirs.terminalSettings), saved)
        XCTAssertEqual(host.base.appliedTerminal.last?.fontSize, 20)
        store.updateTerminal("font-size") { $0.fontSize = 14 }
        XCTAssertNil(store.errors["font-size"])
        XCTAssertEqual(try TerminalSettings.load(dirs.terminalSettings).fontSize, 14)
    }

    func testBackupRejectsInvalidServerSettingsBeforeStaging() throws {
        for server in [#"{"startupCommand":[""]}"#, #"{"historyBudgetBytes":68719476737}"#, #"{"shellIntegration":"yes"}"#] {
            let archive = BackupArchive(files: ["settings.json": Data("{}".utf8), "server.json": Data(server.utf8)])
            XCTAssertThrowsError(try archive.stage(in: dirs))
            XCTAssertFalse(BackupArchive.hasPending(dirs))
        }
        XCTAssertNoThrow(try BackupArchive(files: ["settings.json": Data("{}".utf8), "server.json": Data("{}".utf8)]).validate())
        XCTAssertThrowsError(try BackupArchive(files: ["settings.json": Data("{}".utf8), "state.json": Data(#"{"projects":[]}"#.utf8)]).stage(in: dirs))
        XCTAssertFalse(BackupArchive.hasPending(dirs))
    }

    func testBackupFailureRollsBackAlreadyReplacedFiles() throws {
        let original = Data(#"{"window":{"closeBehavior":"detach"}}"#.utf8)
        try original.write(to: dirs.settings)
        try FileManager.default.createDirectory(at: dirs.terminalSettings, withIntermediateDirectories: true)
        let marker = dirs.terminalSettings.appendingPathComponent("original")
        try Data("kept".utf8).write(to: marker)
        let archive = BackupArchive(files: ["settings.json": Data("{}".utf8), "terminal.json": try JSONEncoder().encode(TerminalSettings())])
        try archive.stage(in: dirs)
        XCTAssertThrowsError(try BackupArchive.applyPending(in: dirs) { imported, _ in imported })
        XCTAssertEqual(try Data(contentsOf: dirs.settings), original)
        XCTAssertEqual(try Data(contentsOf: marker), Data("kept".utf8))
        XCTAssertTrue(BackupArchive.hasPending(dirs))
    }

    func testExportDoesNotSilentlyReplaceUnreadableConfigurationWithDefaults() throws {
        try FileManager.default.createDirectory(at: dirs.settings, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupArchive.collect(from: dirs, state: nil))
    }
}

/// A server that refuses one write, then accepts later edits.
@MainActor
private final class SettingsWriteHost: SettingsHost {
    let base = PreviewSettingsHost()
    var rejectNextServerWrite = false
    var rejectNextMobileWrite = false
    var writes: [ServerSettingsDoc] = []
    var cancelledPairings = 0
    var delayPairing = false
    var pairingStarted = false
    var serverState: ServerConnectionState { base.serverState }
    func settingsDidChange(_ settings: Settings) { base.settingsDidChange(settings) }
    func terminalSettingsDidChange(_ settings: TerminalSettings) { base.terminalSettingsDidChange(settings) }
    func connectServer() { base.connectServer() }
    func readServerSettings() async throws -> ServerSettingsDoc { try await base.readServerSettings() }
    func writeServerSettings(_ settings: ServerSettingsDoc) async throws {
        writes.append(settings)
        await Task.yield()
        if rejectNextServerWrite {
            rejectNextServerWrite = false
            throw SettingsError("server", "Server refused the write")
        }
        try await base.writeServerSettings(settings)
    }
    func stopServer() async throws { try await base.stopServer() }
    func restartServer() async throws { try await base.restartServer() }
    func readRemoteAccess() async throws -> RemoteAccessState { try await base.readRemoteAccess() }
    func writeRemoteAccess(_ settings: RemoteAccessSettings) async throws {
        if rejectNextMobileWrite {
            rejectNextMobileWrite = false
            throw SettingsError("mobile", "Server refused the write")
        }
        try await base.writeRemoteAccess(settings)
    }
    func startPairing() async throws -> PairingOffer {
        pairingStarted = true
        if delayPairing { try await Task.sleep(nanoseconds: 50_000_000) }
        return try await base.startPairing()
    }
    func cancelPairing() async {
        cancelledPairings += 1
        await base.cancelPairing()
    }
    func revokeDevice(_ device: DeviceId) async throws { try await base.revokeDevice(device) }
    func browserProfiles() -> [BrowserProfileSummary] { base.browserProfiles() }
    func addBrowserProfile(named name: String) throws -> BrowserProfileSummary { try base.addBrowserProfile(named: name) }
    func renameBrowserProfile(_ id: String, to name: String) throws { try base.renameBrowserProfile(id, to: name) }
    func deleteBrowserProfile(_ id: String) async throws { try await base.deleteBrowserProfile(id) }
    func clearBrowserProfileData(_ id: String) async throws { try await base.clearBrowserProfileData(id) }
    func browserImportSources() -> [BrowserImportSource] { [] }
    func importBrowserData(from source: BrowserImportSource, cookies: Bool) async throws {}
    func agentIntegrations() async throws -> [AgentIntegrationStatus] { try await base.agentIntegrations() }
    func setAgentIntegration(_ enabled: Bool) async throws -> [AgentIntegrationStatus] { try await base.setAgentIntegration(enabled) }
    func migrationSources() -> [TerminalMigration.Source] { base.migrationSources() }
    func openAgent(prompt: String) throws { try base.openAgent(prompt: prompt) }
    func backupState() throws -> Data { try base.backupState() }
}
