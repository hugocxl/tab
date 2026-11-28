import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

private actor ShellConnectionPair: ServerConnector {
    private var clients: [ServerAPI]

    init(_ clients: [ServerAPI]) { self.clients = clients }

    func connect() async throws -> ServerAPI {
        guard !clients.isEmpty else { throw ClientError.disconnected }
        return clients.removeFirst()
    }
}

@MainActor
final class AppShellConnectionTests: XCTestCase {
    func testSideWatchEventsReachTheModelAndSideDisconnectReconnectsBothClients() async throws {
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let catalog = CatalogPage(server: identity, home: home.id, revision: 1, projects: [home])
        let main = ModelFakeServer(identity: identity, catalog: catalog)
        let side = ModelFakeServer(identity: identity, catalog: catalog)
        let connector = ShellConnectionPair([main, side])
        let connection = ServerConnection(id: .local, connector: connector, backoff: { _ in 60 })
        defer { connection.disconnect() }
        var gitEvents = 0
        var fileEvents = 0
        var changedEvents = 0
        var reconnecting = false
        connection.onEvent = { _, event in
            switch event {
            case .gitChanged: gitEvents += 1
            case .filesChanged: fileEvents += 1
            case .changed: changedEvents += 1
            default: break
            }
        }
        connection.onStateChange = { connection in
            if case .reconnecting = connection.state { reconnecting = true }
        }
        connection.start()
        let ready = await ModelFixtures.wait { connection.state.isReady }
        XCTAssertTrue(ready, "Expected ready; state=\(connection.state)")
        side.send(.gitChanged(project: home.id))
        side.send(.filesChanged(project: home.id, changes: FileChanges(rescan: true)))
        side.send(.changed(topic: .activity, revision: 1))
        main.send(.changed(topic: .activity, revision: 1))
        let delivered = await ModelFixtures.wait { gitEvents == 1 && fileEvents == 1 && changedEvents == 1 }
        XCTAssertTrue(delivered, "side watch events must be routed without duplicating global change events")
        side.send(.disconnected(.disconnected))
        let dropped = await ModelFixtures.wait { reconnecting }
        XCTAssertTrue(dropped)
        XCTAssertNil(connection.main)
        XCTAssertNil(connection.side)
    }

    /// A restart the server announced reconnects at once, without the
    /// backoff of a dropped connection, and counts as restarting, not offline.
    func testAnAnnouncedRestartReconnectsAtOnce() async throws {
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let catalog = CatalogPage(server: identity, home: home.id, revision: 1, projects: [home])
        let servers = (0..<4).map { _ in ModelFakeServer(identity: identity, catalog: catalog) }
        let connection = ServerConnection(id: .local, connector: ShellConnectionPair(servers), backoff: { _ in 60 })
        defer { connection.disconnect() }
        connection.start()
        let ready = await ModelFixtures.wait { connection.state.isReady }
        XCTAssertTrue(ready)
        XCTAssertFalse(connection.isRestarting)

        servers[0].send(.serverRestarting)
        let announced = await ModelFixtures.wait { connection.isRestarting }
        XCTAssertTrue(announced)
        XCTAssertFalse(connection.isRestartingSlowly, "a quick restart goes unmentioned")
        servers[0].send(.disconnected(.disconnected))
        let back = await ModelFixtures.wait { connection.state.isReady && connection.main === servers[2] }
        XCTAssertTrue(back, "reconnected without the 60 second backoff; state=\(connection.state)")
        XCTAssertFalse(connection.isRestarting)
    }
}
