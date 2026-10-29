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
