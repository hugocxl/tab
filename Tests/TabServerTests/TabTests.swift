import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

/// Two apps connected to one server share its tabs.
final class TabTests: XCTestCase {
    private func tabs(_ client: CoreTestClient) throws -> TabsSnapshot {
        guard case .tabs(let snapshot) = try client.request(.readTabs) else { throw CoreTestError.unexpected("tabs") }
        return snapshot
    }

    @discardableResult
    private func mutate(_ client: CoreTestClient, _ mutation: TabMutation,
                        operation: OperationId = OperationId()) throws -> ReplyBody {
        try client.request(.mutateTabs(TabIntent(operation: operation, mutation: mutation)))
    }

    private func panes(_ snapshot: TabsSnapshot) -> [Pane] { snapshot.projects.flatMap(\.tabs).flatMap(\.panes) }

    private func create(_ client: CoreTestClient, project: ProjectId, pane: Pane, root: URL) throws -> SessionInfo {
        let request = CreateSession(project: project, operation: pane.id.creationToken, directory: ServerPath(root.path),
                                    size: Size(cols: 80, rows: 24), pane: pane.id, input: pane.launch?.command)
        guard case .sessionCreated(let info) = try client.request(.createSession(request)) else {
            throw CoreTestError.unexpected("session")
        }
        return info
    }

    func testATabMadeByOneAppReachesTheOtherAndSurvivesARestart() throws {
        let server = try CoreTestServer()
        let first = try server.connect()
        let second = try server.connect()
        let home = try first.home()
        XCTAssertTrue(try tabs(second).projects.isEmpty)
        let tab = Tab(pane: Pane(content: .browser(BrowserPane(url: "https://example.com"))))
        let operation = OperationId()
        guard case .tabsMutated(let revision) = try mutate(first, .createTab(project: home, tab: tab, after: nil),
                                                         operation: operation)
        else { return XCTFail("not created") }
        try second.wait("the tabs change") {
            second.events.contains(.changed(topic: .tabs, revision: revision)) ? true : nil
        }
        let seen = try tabs(second)
        XCTAssertEqual(seen.revision, revision)
        XCTAssertTrue(seen.applied.contains(operation))
        XCTAssertEqual(seen.tabs(home).map(\.id), [tab.id])
        XCTAssertNotNil(seen.tabs(home).first?.createdAt)

        guard case .tabsMutated(let again) = try mutate(first, .createTab(project: home, tab: tab, after: nil),
                                                      operation: operation)
        else { return XCTFail("a retry is refused") }
        XCTAssertEqual(again, revision, "a retried change is applied once")
        guard case .error = try mutate(first, .equalize(tab.id), operation: operation) else {
            return XCTFail("an operation id can't name another change")
        }

        first.close()
        second.close()
        try server.restart()
        let later = try server.connect()
        XCTAssertEqual(try tabs(later).tabs(home).map(\.id), [tab.id], "browser tabs are kept across restarts")
    }

    func testClosingAPaneOnOneAppEndsItsTerminalWhileAnotherAppShowsIt() throws {
        let server = try CoreTestServer()
        let first = try server.connect()
        let second = try server.connect()
        let home = try first.home()
        let pane = Pane(content: .terminal(session: nil), launch: TerminalLaunch(command: "echo started-once"))
        try mutate(first, .createTab(project: home, tab: Tab(pane: pane), after: nil))
        let info = try create(first, project: home, pane: pane, root: server.root)
        let raced = try create(second, project: home, pane: pane, root: server.root)
        XCTAssertEqual(raced.id, info.id, "two apps starting the same pane get one terminal")
        XCTAssertEqual(panes(try tabs(second)).first?.content, .terminal(session: info.id))
        XCTAssertNil(panes(try tabs(second)).first?.launch)

        let channel = try second.attach(info.id).channel
        try second.waitForRow("started-once", on: channel)
        XCTAssertEqual(second.screen(channel).filter { $0.contains("started-once") && !$0.contains("echo") }.count, 1,
                       "the startup command runs once")
        guard case .sessionReferencesSynced = try second.request(.syncSessionReferences(owner: nil, revision: 0,
                                                                                         sessions: [info.id]))
        else { return XCTFail("references") }

        try mutate(first, .removePane(pane.id, keepSession: false))
        try first.wait("the terminal to end") {
            (try? first.sessions().contains { $0.id == info.id }) == false ? true : nil
        }
        XCTAssertTrue(try tabs(second).projects.isEmpty)
    }

    func testAPaneClosedBeforeItsTerminalStartsGetsNone() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let home = try client.home()
        let pane = Pane(content: .terminal(session: nil))
        try mutate(client, .createTab(project: home, tab: Tab(pane: pane), after: nil))
        try mutate(client, .removePane(pane.id, keepSession: false))
        let request = CreateSession(project: home, operation: pane.id.creationToken, directory: ServerPath(server.root.path),
                                    size: Size(cols: 80, rows: 24), pane: pane.id)
        guard case .error = try client.request(.createSession(request)) else { return XCTFail("started anyway") }
        XCTAssertTrue(try client.sessions().isEmpty)
    }

    func testAnEndedTerminalClosesItsPaneButAStoppingServerKeepsThemUntilItStarts() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let home = try client.home()
        let exiting = Pane(content: .terminal(session: nil))
        let running = Pane(content: .terminal(session: nil))
        let browser = Pane(content: .browser(BrowserPane()))
        var tab = Tab(pane: exiting)
        tab.layout.split(exiting.id, new: running.id, edge: .right)
        tab.layout.split(running.id, new: browser.id, edge: .right)
        tab.panes += [running, browser]
        try mutate(client, .createTab(project: home, tab: tab, after: nil))
        let ending = try create(client, project: home, pane: exiting, root: server.root)
        let kept = try create(client, project: home, pane: running, root: server.root)
        guard case .sessionEnded = try client.request(.endSession(ending.id)) else { return XCTFail("end") }
        try client.wait("the pane to close") {
            (try? self.panes(self.tabs(client)).map(\.id)) == [running.id, browser.id] ? true : nil
        }

        let saved = server.root.appendingPathComponent("sessions/tabs.json")
        client.close()
        server.stop()
        let onDisk = try JSONDecoder().decode(TabStore.State.self, from: Data(contentsOf: saved))
        XCTAssertEqual(onDisk.projects.flatMap(\.tabs).flatMap(\.panes).first?.content, .terminal(session: kept.id),
                       "a stopping server's terminals keep their panes")
        try server.restart()
        let later = try server.connect()
        XCTAssertEqual(panes(try tabs(later)).map(\.id), [browser.id], "they ended with the server")
    }

    func testPanesShowOnlyRunningTerminalsOfTheirProject() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let home = try client.home()
        let other = ProjectDescriptor.new(directory: ServerPath(server.root.appendingPathComponent("uploads").path))
        try FileManager.default.createDirectory(atPath: other.directory.rawValue, withIntermediateDirectories: true)
        guard case .projectMutated = try client.request(.mutateProject(ProjectIntent(mutation: .create(other)))) else {
            return XCTFail("project")
        }
        let info = try client.createSession(project: home, directory: server.root.path)
        guard case .error = try mutate(client, .createTab(project: other.id, tab: Tab(pane: Pane(content: .terminal(session: info.id))), after: nil))
        else { return XCTFail("another project's terminal") }
        guard case .error = try mutate(client, .createTab(project: home, tab: Tab(pane: Pane(content: .terminal(session: SessionId()))), after: nil))
        else { return XCTFail("a terminal that doesn't run") }
        let dead = Pane(content: .terminal(session: SessionId()))
        let live = Pane(content: .terminal(session: info.id))
        var kept = Tab(pane: dead)
        kept.layout.split(dead.id, new: live.id, edge: .right)
        kept.panes.append(live)
        try mutate(client, .adoptTabs(project: home, tabs: [kept]))
        XCTAssertEqual(panes(try tabs(client)).map(\.id), [live.id], "adopted tabs leave out ended terminals")

        guard case .projectMutated = try client.request(.mutateProject(ProjectIntent(mutation: .delete(other.id)))) else {
            return XCTFail("delete")
        }
        try mutate(client, .createTab(project: home, tab: Tab(pane: Pane(content: .browser(BrowserPane()))), after: nil))
        XCTAssertNil(try tabs(client).projects.first { $0.project == other.id })
    }

    func testADamagedTabsFileStopsTheServerInsteadOfLosingTabs() throws {
        let root = try makeShortTemporaryFolder()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: sessions.appendingPathComponent("tabs.json"))
        XCTAssertThrowsError(try TabStore(directory: sessions, home: ProjectId(), isProject: { _ in true }, isLive: { _ in true }))
        XCTAssertEqual(try String(contentsOf: sessions.appendingPathComponent("tabs.json"), encoding: .utf8), "{ not json")
    }
}
