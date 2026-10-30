import AppKit
import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class ShellParityTests: XCTestCase {
    private func fixture(entries: [ServerEntry] = []) throws -> (AppModel, ModelFakeServer) {
        let dirs = try ModelFixtures.profile()
        var settings = Settings()
        settings.servers = entries
        try AtomicFile.write(JSONEncoder().encode(settings), to: dirs.settings)
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in FakeConnector(server: server) }
        addTeardownBlock { @MainActor in
            for connection in model.connections.values { connection.disconnect() }
            try? FileManager.default.removeItem(at: dirs.root)
        }
        return (model, server)
    }

    func testPresentationEditsKeepTheConnectionAndSSHFieldEditsReplaceIt() async throws {
        let entry = ServerEntry(name: "box", ssh: "user@box")
        let (model, _) = try fixture(entries: [entry])
        model.connectOnDemand(entry.id)
        let ready = await ModelFixtures.wait { model.connectionState(entry.id).isReady }
        XCTAssertTrue(ready)
        let connection = try XCTUnwrap(model.connections[entry.id])
        var settings = model.settings
        settings.servers[0].name = "renamed"
        settings.servers[0].group = "Team"
        model.apply(settings: settings)
        XCTAssertTrue(model.connections[entry.id] === connection)
        XCTAssertTrue(connection.state.isReady)
        let edits: [(inout ServerEntry) -> Void] = [
            { $0.ssh = "other@host" }, { $0.port = 2222 }, { $0.identityFile = "/tmp/key" },
            { $0.passwordLogin = true }, { $0.ssh = ""; $0.sshCommand = "custom-ssh box" },
        ]
        for change in edits {
            var modified = entry
            change(&modified)
            XCTAssertFalse(entry.hasSameConnection(as: modified))
        }
        settings.servers[0].port = 2222
        model.apply(settings: settings)
        XCTAssertEqual(connection.state, .idle)
        XCTAssertFalse(model.connection(entry.id) === connection)
    }

    func testExplicitRemoteDisconnectForgetsMissingStatus() async throws {
        let entry = ServerEntry(name: "box", ssh: "box")
        let (model, server) = try fixture(entries: [entry])
        let descriptor = ProjectDescriptor(id: ProjectId(), directory: "/missing", name: "remote")
        server.catalogPage.projects.append(descriptor)
        model.connectOnDemand(entry.id)
        let ready = await ModelFixtures.wait { model.state.project(descriptor.id) != nil }
        XCTAssertTrue(ready)
        model.edit { try $0.setRemoteProjectStatus(descriptor.id, .missing) }
        model.disconnectRemoteServer(entry.id)
        XCTAssertTrue(model.connectionState(entry.id).isOffline)
        XCTAssertEqual(model.state.project(descriptor.id)?.status, .available)
    }

    func testRestartTransfersProxyBeforeSessionCreationAndConsumesChoice() async throws {
        let (model, server) = try fixture()
        model.connection(.local)?.start()
        let ready = await ModelFixtures.wait { model.connectionState(.local).isReady && model.state.serverIdentity(.local) != nil }
        XCTAssertTrue(ready)
        try model.proxy.save(ProxySettings(kind: .http, host: "localhost", port: 8080))
        model.newHomeTerminal()
        let pane = try XCTUnwrap(model.activePane)
        let started = await ModelFixtures.wait { model.state.pane(pane)?.content.session != nil }
        XCTAssertTrue(started)
        model.proxy.choose(pane, proxy: true)
        model.restartTerminal(pane)
        let restarted = await ModelFixtures.wait { model.activePane != pane && server.created.count == 2 }
        XCTAssertTrue(restarted)
        let replacement = try XCTUnwrap(model.activePane)
        XCTAssertEqual(server.created.last?.environment["http_proxy"], "http://localhost:8080")
        let created = await ModelFixtures.wait { model.state.pane(replacement)?.content.session != nil }
        XCTAssertTrue(created)
        XCTAssertTrue(model.state.pane(replacement)?.proxy == true)
        XCTAssertFalse(model.proxy.creationEnvironment(for: pane, localServer: true, serverSupportsEnvironment: true).proxied)
        XCTAssertFalse(model.proxy.creationEnvironment(for: replacement, localServer: true, serverSupportsEnvironment: true).proxied)
    }

    func testCancelledRestartDropsThePendingProxyChoice() async throws {
        let (model, _) = try fixture()
        try model.proxy.save(ProxySettings(kind: .http, host: "localhost", port: 8080))
        let absent = PaneId()
        model.proxy.choose(absent, proxy: true)
        model.restartTerminal(absent)
        let cleared = await ModelFixtures.wait {
            !model.proxy.creationEnvironment(for: absent, localServer: true, serverSupportsEnvironment: true).proxied
        }
        XCTAssertTrue(cleared)
    }

    func testDecliningTheRestartConfirmationClearsTheOverride() async throws {
        let (model, _) = try fixture()
        let refusing = RefusingRestartPane()
        model.panes.register(.terminal) { _ in refusing }
        try model.proxy.save(ProxySettings(kind: .http, host: "localhost", port: 8080))
        model.newHomeTerminal()
        let pane = try XCTUnwrap(model.activePane)
        model.proxy.choose(pane, proxy: true)
        model.restartTerminal(pane)
        let cleared = await ModelFixtures.wait {
            refusing.asked && !model.proxy.creationEnvironment(for: pane, localServer: true, serverSupportsEnvironment: true).proxied
        }
        XCTAssertTrue(cleared)
        XCTAssertEqual(model.activePane, pane)
    }

    func testDictationOverlayKeepsTheAttachmentAndReconnectsInvalidateIt() async throws {
        let (model, _) = try fixture()
        model.connection(.local)?.start()
        let ready = await ModelFixtures.wait { model.connectionState(.local).isReady && model.state.serverIdentity(.local) != nil }
        XCTAssertTrue(ready)
        model.newHomeTerminal()
        let pane = try XCTUnwrap(model.activePane)
        let started = await ModelFixtures.wait { model.state.pane(pane)?.content.session != nil }
        XCTAssertTrue(started)
        let terminal = try XCTUnwrap(model.controller(for: pane) as? TerminalPane)
        let session = try XCTUnwrap(terminal.session)
        let stream = AsyncStream<ChannelEvent>.makeStream()
        defer { stream.continuation.finish() }
        let channel = ChannelId(1)
        let snapshot = AttachSnapshot(channel: channel, size: Size(cols: 80, rows: 24), rows: [], cursor: Cursor(), directory: "/tmp")
        session.attached(TerminalAttachment(channel: channel, snapshot: snapshot, process: nil, events: stream.stream))
        XCTAssertFalse(terminal.hasFocus)
        XCTAssertNil(terminal.dictationTarget(overlayActive: false))
        let target = try XCTUnwrap(terminal.dictationTarget(overlayActive: true))
        let main = try XCTUnwrap(model.connections[.local]?.main)
        let changedSession = DictationTarget(pane: pane, server: .local, session: SessionId(), instance: main.server.instance,
                                            connection: ObjectIdentifier(main), channel: channel)
        XCTAssertNotEqual(target, changedSession)
        let changedInstance = DictationTarget(pane: pane, server: .local, session: session.session, instance: main.server.instance + 1,
                                             connection: ObjectIdentifier(main), channel: channel)
        XCTAssertNotEqual(target, changedInstance)
        let other = NSObject()
        let changedConnection = DictationTarget(pane: pane, server: .local, session: session.session, instance: main.server.instance,
                                               connection: ObjectIdentifier(other), channel: channel)
        XCTAssertNotEqual(target, changedConnection)
        model.connection(.local)?.disconnect()
        XCTAssertNil(terminal.dictationTarget(overlayActive: true))
    }

    func testRouteChangesPreserveCustomCommandsAndNeverConnectIdleServers() async throws {
        let direct = ServerEntry(name: "direct", ssh: "host")
        let custom = ServerEntry(name: "custom", ssh: "", sshCommand: "my-ssh host")
        let idle = ServerEntry(name: "idle", ssh: "idle")
        let denied = ServerEntry(name: "denied", ssh: "denied")
        let (model, _) = try fixture(entries: [direct, custom, idle, denied])
        let deniedConnection = ServerConnection(id: denied.id, connector: RefusedConnector(), sshTarget: try ServerForm.target(for: denied))
        model.connections[denied.id] = deniedConnection
        deniedConnection.start()
        let refused = await ModelFixtures.wait {
            if case .needsUser = deniedConnection.state { return true }
            return false
        }
        XCTAssertTrue(refused)
        model.connectOnDemand(direct.id)
        model.connectOnDemand(custom.id)
        let idleConnection = try XCTUnwrap(model.connection(idle.id))
        let ready = await ModelFixtures.wait { model.connectionState(direct.id).isReady && model.connectionState(custom.id).isReady }
        XCTAssertTrue(ready)
        let directConnection = try XCTUnwrap(model.connections[direct.id])
        let customConnection = try XCTUnwrap(model.connections[custom.id])
        try model.proxy.save(ProxySettings(kind: .http, host: "localhost", port: 8080, global: false))
        model.proxyDidChange(model.proxy)
        XCTAssertTrue(model.connections[direct.id] === directConnection)
        try model.proxy.save(ProxySettings(kind: .http, host: "localhost", port: 8080, global: true))
        model.proxyDidChange(model.proxy)
        XCTAssertFalse(model.connections[direct.id] === directConnection)
        XCTAssertTrue(model.connections[custom.id] === customConnection)
        XCTAssertTrue(customConnection.state.isReady)
        XCTAssertEqual(idleConnection.state, .idle)
        XCTAssertNil(model.connections[idle.id])
        XCTAssertNil(model.connections[denied.id], "a route edit must not retry a refused login")
        let replacement = model.connections[direct.id]
        model.proxyDidChange(model.proxy)
        XCTAssertTrue(model.connections[direct.id] === replacement)
    }

    func testRemoteProjectPaletteRetriesWhenServerBecomesReady() async throws {
        let entry = ServerEntry(name: "box", ssh: "box")
        let (model, server) = try fixture(entries: [entry])
        let source = PaletteSource(model: model)
        source.opened(.addProject(entry.id))
        let listed = await ModelFixtures.wait { !server.folderRequests.isEmpty }
        XCTAssertTrue(listed)
        let content = source.content(for: .addProject(entry.id), query: "")
        XCTAssertFalse(content.sections.isEmpty)
    }

    func testIdleStopUsesTheAtomicServerRequest() async throws {
        let (model, server) = try fixture()
        model.connection(.local)?.start()
        let ready = await ModelFixtures.wait { model.connectionState(.local).isReady }
        XCTAssertTrue(ready)
        let stopped = await model.stopLocalServerIfIdle()
        XCTAssertTrue(stopped)
        server.live = [SessionInfo(project: model.state.home.id, id: SessionId(), directory: "/tmp")]
        let busy = await model.stopLocalServerIfIdle()
        XCTAssertFalse(busy)
        XCTAssertEqual(server.idleStops, 2)
        XCTAssertEqual(server.stops, [])
    }

    func testRemoteLinkMenuUsesProjectRootsAndSidebarMarksTheLocation() async throws {
        let entry = ServerEntry(name: "box", ssh: "box")
        let (model, server) = try fixture(entries: [entry])
        let root = ProjectDescriptor(directory: "/remote/repo", name: "repo")
        let nested = ProjectDescriptor(directory: "/remote/repo/nested", name: "nested")
        server.catalogPage.projects += [root, nested]
        model.connectOnDemand(entry.id)
        let ready = await ModelFixtures.wait { model.state.project(nested.id) != nil }
        XCTAssertTrue(ready)
        XCTAssertEqual(RemoteFileCopy.project(for: "/remote/repo/nested/main.swift", server: entry.id, in: model.state.projects)?.id, nested.id)
        XCTAssertEqual(RemoteFileCopy.project(for: NSHomeDirectory() + "/notes.txt", server: entry.id, in: model.state.projects)?.id,
                       model.state.serverHome(entry.id)?.id)
        XCTAssertNil(RemoteFileCopy.project(for: "/outside-projects/file", server: entry.id, in: model.state.projects))
        model.newTerminal(in: root.id)
        let pane = try XCTUnwrap(model.activePane)
        let terminal = try XCTUnwrap(model.controller(for: pane) as? TerminalPane)
        let reachable = terminal.remoteFileMenu(path: "/remote/repo/nested/main.swift", line: 4, column: 2)
        XCTAssertEqual(reachable.items.map(\.title), ["Open a Copy", "Copy Path"])
        XCTAssertTrue(reachable.items[0].isEnabled)
        let outside = terminal.remoteFileMenu(path: "/outside-projects/file", line: nil, column: nil)
        XCTAssertFalse(outside.items[0].isEnabled)
        XCTAssertTrue(outside.items[1].isEnabled)
        let project = try XCTUnwrap(model.state.project(root.id))
        let row = ProjectHeaderRow(project: project, title: project.name, icon: nil, remoteName: entry.name, canCreateWorktree: false)
        XCTAssertEqual(row.toolTip, "box · /remote/repo")
        let marker = try XCTUnwrap(row.subviews.first { $0.toolTip?.hasPrefix("Remote project on ") == true })
        XCTAssertEqual(marker.toolTip, "Remote project on box · /remote/repo")
    }

    func testRemoteCopyDownloadsThroughTheSideAPIAndCannotWrite() async throws {
        let entry = ServerEntry(name: "box", ssh: "box")
        let (model, server) = try fixture(entries: [entry])
        server.fileReply = .bytes(FileBytes(path: "main.swift", bytes: Data("let value = 1\n".utf8)))
        let copy = try await RemoteFileCopy.download("/repo/main.swift", project: model.state.home.id, directory: "/repo", serverName: "box/one", through: server)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertEqual(copy.lastPathComponent, "main (copy from box-one).swift")
        XCTAssertEqual(try Data(contentsOf: copy), Data("let value = 1\n".utf8))
        XCTAssertEqual(server.fileRequests.last?.action, .readBytes("main.swift"))
        try XCTUnwrap(server.fileRequests.last).validate()
        XCTAssertNil(RemoteFileCopy.relative("/repo-other/file", to: "/repo"))
        XCTAssertNil(RemoteFileCopy.relative("/repo/../outside", to: "/repo"))
        let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o444)
        let transport = RemoteCopyTransport(url: copy)
        do {
            _ = try await transport.files(FilesRequest(project: model.state.home.id, action: .write(path: ServerPath(copy.path), content: "changed")))
            XCTFail("a downloaded copy was writable")
        } catch {}
        let pane = try XCTUnwrap(model.openEditor(project: model.state.home.id, path: copy.path, line: 1, column: 2))
        let editor = try XCTUnwrap(model.controller(for: pane) as? EditorPaneContent)
        let loaded = await ModelFixtures.wait { editor.controller.text == "let value = 1\n" }
        XCTAssertTrue(loaded)
        XCTAssertFalse(editor.controller.textView.isEditable)
        XCTAssertEqual(server.fileRequests.count, 1, "the local copy must never read through the project's remote transport")
    }
}

@MainActor
private final class RefusingRestartPane: PaneContentController {
    let view = NSView()
    let title = "Running terminal"
    var titleDidChange: (() -> Void)?
    var asked = false
    func focusContent() {}
    func didShow() {}
    func didHide() {}
    func willClose() async -> Bool { asked = true; return false }
}

private struct RefusedConnector: ServerConnector {
    func connect() async throws -> ServerAPI {
        throw ClientError.remote(RemoteFailure(reason: .authenticationFailed, destination: "denied", detail: ""))
    }
}
