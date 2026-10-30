import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class ModelRestoreTests: XCTestCase {
    private func homeCatalog(_ identity: ServerId) -> CatalogPage {
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        return CatalogPage(server: identity, home: home.id, revision: 1, projects: [home])
    }

    /// A project with two terminals, saved; after a restart one session is
    /// gone: its pane closes and its session is discarded, the other stays.
    func testRestoreClosesDeadPanesKeepsLiveOnesAndPersists() async throws {
        let dirs = try ModelFixtures.profile()
        let folder = try ModelFixtures.folder("app")
        let identity = ServerId()
        let server = ModelFakeServer(identity: identity, catalog: homeCatalog(identity))

        let first = ModelFixtures.model(dirs, server: server)
        first.start()
        let ready = await ModelFixtures.wait { first.connectionState(.local) == .ready && first.state.serverIdentity(.local) != nil }
        XCTAssertTrue(ready)
        let project = try XCTUnwrap(first.addProject(folder))
        let created = await ModelFixtures.wait { first.state.projectIntents(.local).isEmpty }
        XCTAssertTrue(created, "the project edit reaches the server")
        first.newTerminal(in: project)
        first.split(.right)
        let started = await ModelFixtures.wait {
            let panes = first.state.project(project)?.tabs.flatMap(\.panes) ?? []
            return panes.count == 2 && panes.allSatisfy { $0.content.session != nil }
        }
        XCTAssertTrue(started, "both terminals get sessions")
        let sessions = first.state.project(project)!.tabs.flatMap(\.panes).compactMap(\.content.session)
        first.saveNow()

        // The second terminal ended while the app was away.
        first.connection(.local)?.disconnect()
        let restarted = ModelFakeServer(identity: identity, catalog: server.catalogPage)
        restarted.live = server.live.filter { $0.id == sessions[0] }
        let second = ModelFixtures.model(dirs, server: restarted)
        XCTAssertEqual(second.state.project(project)?.tabs.flatMap(\.panes).count, 2, "state.json restores both panes")
        second.start()
        let restored = await ModelFixtures.wait {
            second.state.project(project)?.tabs.flatMap(\.panes).count == 1 && restarted.closed.contains(sessions[1])
        }
        XCTAssertTrue(restored, "the dead pane closes and its session is discarded")
        XCTAssertEqual(second.state.project(project)?.tabs.flatMap(\.panes).first?.content.session, sessions[0])
        let synced = await ModelFixtures.wait { restarted.references.last == [sessions[0]] }
        XCTAssertTrue(synced, "the server learns which sessions this app shows")
        second.saveNow()
        let saved = try AppStateStore.load(dirs.state)
        XCTAssertEqual(saved.project(project)?.tabs.flatMap(\.panes).count, 1)
    }

    /// A dropped connection keeps the projects and marks the server offline.
    func testOfflineServerKeepsProjects() async throws {
        let dirs = try ModelFixtures.profile()
        let folder = try ModelFixtures.folder("lib")
        let identity = ServerId()
        let server = ModelFakeServer(identity: identity, catalog: homeCatalog(identity))
        let model = ModelFixtures.model(dirs, server: server)
        model.start()
        _ = await ModelFixtures.wait { model.connectionState(.local) == .ready && model.state.serverIdentity(.local) != nil }
        let project = try XCTUnwrap(model.addProject(folder))
        _ = await ModelFixtures.wait { model.state.projectIntents(.local).isEmpty }
        server.send(.disconnected(.disconnected))
        let offline = await ModelFixtures.wait { model.connectionState(.local).isOffline }
        XCTAssertTrue(offline)
        XCTAssertEqual(model.state.project(project)?.status, .available)
        model.connection(.local)?.disconnect()
    }
}

@MainActor
final class ModelRestoreShellStateTests: XCTestCase {
    func testBackupReplacesPopulatedLayoutAndRemapsWorkspaceMembers() throws {
        let folder = try ModelFixtures.folder("restore-layout")
        var current = try AppState.bootstrap()
        let existing = try current.addProject(server: .local, directory: folder)
        _ = try current.openTerminalTab(existing)
        var imported = try AppState.bootstrap()
        let original = try imported.addProject(server: .local, directory: folder)
        _ = try imported.openTerminalTab(original)
        let workspace = try imported.createWorkspace("Saved")
        try imported.setWorkspaceMember(workspace, project: original, member: true)
        let savedPane = try XCTUnwrap(imported.project(original)?.tabs.first?.panes.first?.id)
        try imported.setPaneTitle(savedPane, "Imported terminal")
        let merged = try AppStateStore.decode(BackupStateMerge.merge(
            imported: BackupStateMerge.backup(imported), current: AppStateStore.encode(current)
        ))
        let restored = try XCTUnwrap(merged.project(existing)?.tabs.first?.panes.first)
        XCTAssertNotEqual(restored.id, savedPane, "a restore must use a fresh session creation token")
        XCTAssertEqual(restored.title, "Imported terminal")
        XCTAssertTrue(merged.project(existing)?.tabs.first?.layout.contains(restored.id) == true)
        XCTAssertEqual(merged.workspace(workspace)?.projects, [existing])
        XCTAssertNil(merged.project(original))
    }

    func testFontOverridesPersistPerPaneAndPruneClosedPanes() throws {
        let dirs = try ModelFixtures.profile()
        let model = AppModel(dirs: dirs)
        model.newHomeTerminal()
        let pane = try XCTUnwrap(model.activePane)
        model.terminalFontSizes[pane.description] = 21
        model.terminalFontSizes[PaneId().description] = 99
        model.saveNow()
        let restored = AppModel(dirs: dirs)
        XCTAssertEqual(restored.terminalFontSizes, [pane.description: 21])
    }
}

@MainActor
final class ModelRestoreActivationTests: XCTestCase {
    func testReturningToAppRefreshesMissingFolders() async throws {
        let dirs = try ModelFixtures.profile()
        let model = AppModel(dirs: dirs)
        let folder = try ModelFixtures.folder("moved")
        let project = try XCTUnwrap(model.addProject(folder))
        try FileManager.default.moveItem(atPath: folder, toPath: folder + "-away")
        model.windowDidChangeActive(true)
        let missing = await ModelFixtures.wait { model.state.project(project)?.status == .missing }
        XCTAssertTrue(missing)
        XCTAssertTrue(model.sidebarListing.groups.first(where: { $0.project == project })?.cards.isEmpty == true)
        try FileManager.default.moveItem(atPath: folder + "-away", toPath: folder)
        model.windowDidChangeActive(true)
        let restored = await ModelFixtures.wait { model.state.project(project)?.status == .available }
        XCTAssertTrue(restored)
    }

    func testMobileChangedEventRefreshesTheSettingsStore() async throws {
        let dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let model = ModelFixtures.model(dirs, server: server)
        model.start()
        defer { model.connection(.local)?.disconnect() }
        let ready = await ModelFixtures.wait { model.connectionState(.local).isReady }
        XCTAssertTrue(ready)
        let host = SettingsHostImpl(model: model)
        let store = SettingsStore(dirs: dirs, host: host, theme: model.theme)
        host.store = store
        XCTAssertNil(store.remoteAccess)
        server.send(.changed(topic: .remoteAccess, revision: 1))
        let refreshed = await ModelFixtures.wait { store.remoteAccess != nil }
        XCTAssertTrue(refreshed)
    }
}

@MainActor
final class ModelRestorePortableLayoutTests: XCTestCase {
    func testImportedProjectsRemainQueuedUntilTheServerRegistersThem() throws {
        var state = try AppState.bootstrap()
        let project = try state.addProject(server: .local, directory: ModelFixtures.folder("imported"))
        let data = try BackupStateMerge.merge(imported: BackupStateMerge.backup(state), current: nil)
        let restored = try AppStateStore.decode(data)
        XCTAssertTrue(restored.projectCreationPending(project))
        XCTAssertEqual(restored.projectIntents(.local).count, 1)
    }

    func testFreshProfileRestoresHomeWithNewPaneIDsAndItsFontSize() throws {
        var state = try AppState.bootstrap()
        _ = try state.openTerminalTab(state.home.id)
        let pane = try XCTUnwrap(state.home.tabs.first?.panes.first?.id)
        let exported = try BackupStateMerge.backup(state, terminalFontSizes: [pane.description: 22])
        let data = try BackupStateMerge.merge(imported: exported, current: nil)
        let restored = try AppStateStore.decode(data)
        let replacement = try XCTUnwrap(restored.home.tabs.first?.panes.first?.id)
        XCTAssertNotEqual(pane, replacement)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["terminalFontSizes"] as? [String: Double], [replacement.description: 22])
    }
}
