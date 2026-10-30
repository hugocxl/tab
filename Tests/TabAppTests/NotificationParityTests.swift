import AppKit
import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class NotificationParityTests: XCTestCase {
    private struct Delivered {
        var event: AgentEvent
        var server: ServerId
        var title: String
    }
    private var delivered: [Delivered] = []
    private var cleared: [UInt64] = []

    private func fixture() async throws -> (AppModel, ModelFakeServer, [SessionId]) {
        let dirs = try ModelFixtures.profile()
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let notifier = Notifier(deliver: { [weak self] event, server, title in
            self?.delivered.append(Delivered(event: event, server: server, title: title))
        }, clear: { [weak self] ids, _ in self?.cleared.append(contentsOf: ids) })
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true), notifier: notifier) { _, _ in FakeConnector(server: server) }
        model.windowActive = false
        let sessions = [SessionId(), SessionId()]
        model.edit { state in
            for session in sessions {
                _ = try state.openTerminalTab(state.home.id)
                try state.setPaneSession(try XCTUnwrap(state.window.activePane), session)
            }
        }
        server.live = sessions.map { SessionInfo(project: home.id, id: $0, directory: home.directory) }
        model.connection(.local)?.start()
        let ready = await ModelFixtures.wait { model.connections[.local]?.activityLoaded == true }
        XCTAssertTrue(ready)
        addTeardownBlock { @MainActor in
            model.connection(.local)?.disconnect()
            try? FileManager.default.removeItem(at: dirs.root)
        }
        return (model, server, sessions)
    }

    private func event(_ id: UInt64, session: SessionId, model: AppModel, kind: EventKind = .attention) -> AgentEvent {
        AgentEvent(id: id, session: session, project: model.state.home.id, provider: .claude, timestamp: id, kind: kind)
    }

    func testAttentionAndCompletionNotifyOnlyOnceAndOnlyForClaimedPaneSessions() async throws {
        let (model, server, sessions) = try await fixture()
        let detached = SessionId()
        server.claimResult = [1, 2]
        server.activitySnapshot = ActivitySnapshot(events: [event(1, session: sessions[0], model: model),
                                                           event(2, session: sessions[1], model: model, kind: .completed),
                                                           event(3, session: detached, model: model)])
        await model.refreshActivity(.local)
        XCTAssertEqual(delivered.map(\.event.id), [1, 2])
        XCTAssertEqual(server.claims.last, [1, 2])
        XCTAssertTrue(delivered.allSatisfy { $0.server == .local })
        await model.refreshActivity(.local)
        XCTAssertEqual(delivered.count, 2)
        server.claimResult = []
        server.activitySnapshot = ActivitySnapshot(events: [event(4, session: sessions[0], model: model)])
        await model.refreshActivity(.local)
        XCTAssertEqual(delivered.count, 2, "another claiming app owns this notification")
    }

    func testVisiblePaneIsAcknowledgedAndAnotherAppsReadClearsTheNotification() async throws {
        let (model, server, sessions) = try await fixture()
        model.windowActive = true
        let visible = try XCTUnwrap(model.focusedSession()?.1)
        let hidden = try XCTUnwrap(sessions.first { $0 != visible })
        server.activitySnapshot = ActivitySnapshot(events: [event(1, session: visible, model: model), event(2, session: hidden, model: model)])
        await model.refreshActivity(.local)
        let acknowledged = await ModelFixtures.wait { server.acknowledged.contains(1) }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(delivered.map(\.event.id), [2])
        var read = event(2, session: hidden, model: model)
        read.read = true
        server.activitySnapshot = ActivitySnapshot(events: [read])
        await model.refreshActivity(.local)
        XCTAssertTrue(cleared.contains(2))
    }

    func testClickFocusesThePaneAndClearsItsActivityEverywhere() async throws {
        let (model, server, sessions) = try await fixture()
        server.activitySnapshot = ActivitySnapshot(events: [event(1, session: sessions[0], model: model)])
        await model.refreshActivity(.local)
        model.windowActive = true
        model.openNotification(server: .local, session: sessions[0])
        let acknowledged = await ModelFixtures.wait { server.acknowledged.contains(1) }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(model.state.pane(try XCTUnwrap(model.activePane))?.content.session, sessions[0])
        XCTAssertTrue(cleared.contains(1))
    }

    func testDetachAndRemovedEventsClearAlreadyDeliveredNotifications() async throws {
        let (model, server, sessions) = try await fixture()
        server.activitySnapshot = ActivitySnapshot(events: [event(1, session: sessions[0], model: model), event(2, session: sessions[1], model: model)])
        await model.refreshActivity(.local)
        let pane = try XCTUnwrap(model.sessionPanes(.local, sessions[0]).first)
        model.detachTerminal(pane)
        XCTAssertTrue(cleared.contains(1))
        server.activitySnapshot = ActivitySnapshot()
        await model.refreshActivity(.local)
        XCTAssertTrue(cleared.contains(2))
    }

    func testClaimReplyRechecksWhetherThePaneBecameVisible() async throws {
        let (model, server, sessions) = try await fixture()
        server.beforeClaim = { @MainActor in
            model.windowActive = true
            model.openNotification(server: .local, session: sessions[0])
        }
        server.activitySnapshot = ActivitySnapshot(events: [event(1, session: sessions[0], model: model)])
        await model.refreshActivity(.local)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testPaletteCoveredTerminalNotifiesAndReturningToItAcknowledges() async throws {
        let (model, server, _) = try await fixture()
        let presenter = ActivityPresenter()
        model.presenter = presenter
        model.windowActive = true
        let visible = try XCTUnwrap(model.state.pane(try XCTUnwrap(model.activePane))?.content.session)
        server.activitySnapshot = ActivitySnapshot(events: [event(1, session: visible, model: model)])
        await model.refreshActivity(.local)
        XCTAssertEqual(delivered.map(\.event.id), [1])
        XCTAssertTrue(server.acknowledged.isEmpty)
        presenter.terminalActivityObscured = false
        model.acknowledgeFocusedActivity()
        let acknowledged = await ModelFixtures.wait { server.acknowledged.contains(1) }
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(cleared.contains(1))
    }

    func testRemoteNotificationsKeepTheirServerIdentityAndHomeTitle() async throws {
        let (model, _, _) = try await fixture()
        let entry = ServerEntry(name: "box", ssh: "box")
        var settings = model.settings
        settings.servers = [entry]
        model.apply(settings: settings)
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: "/home/remote")
        let catalog = CatalogPage(server: identity, home: home.id, revision: 1, projects: [home])
        let server = ModelFakeServer(identity: identity, catalog: catalog)
        let connection = ServerConnection(id: entry.id, connector: FakeConnector(server: server))
        model.connections[entry.id] = connection
        defer { connection.disconnect() }
        let session = SessionId()
        model.edit { state in
            try state.applyCatalog(entry.id, catalog)
            _ = try state.openTerminalTab(home.id)
            try state.setPaneSession(try XCTUnwrap(state.window.activePane), session)
        }
        connection.start()
        let ready = await ModelFixtures.wait { connection.state.isReady }
        XCTAssertTrue(ready)
        await model.refreshActivity(entry.id)
        server.activitySnapshot = ActivitySnapshot(events: [AgentEvent(id: 1, session: session, project: home.id, provider: .claude,
                                                                     timestamp: 1, kind: .completed)])
        await model.refreshActivity(entry.id)
        XCTAssertEqual(delivered.last?.server, entry.id)
        XCTAssertEqual(delivered.last?.title, "Claude Code · Home · box")
        XCTAssertNotEqual(Notifier.identifier(entry.id, 1), Notifier.identifier(.local, 1))
    }

    func testInitialActivitySnapshotDoesNotNotifyAboutOldEvents() async throws {
        let (model, server, sessions) = try await fixture()
        model.connections[.local]?.activityLoaded = false
        server.activitySnapshot = ActivitySnapshot(events: [event(9, session: sessions[0], model: model)])
        await model.refreshActivity(.local)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(server.claims.isEmpty)
        server.activitySnapshot = ActivitySnapshot(events: [event(10, session: sessions[0], model: model)])
        await model.refreshActivity(.local)
        XCTAssertEqual(delivered.map(\.event.id), [10])
    }
}

@MainActor
private final class ActivityPresenter: AppPresenter {
    var window: NSWindow? { nil }
    var terminalActivityObscured = true
    func confirm(title: String, message: String, confirm: String, destructive: Bool) async -> Bool { false }
    func showToast(_ message: String, error: Bool) {}
    func showRemoteFolderBrowser(_ server: ServerId) {}
    func bringToFront() {}
}
