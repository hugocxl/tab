import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

/// A server restart for an update keeps every terminal in its pane: the next
/// server reopens it in its folder with its output, and an idle-only restart
/// never cuts a running program short.
final class RestartKeepingTerminalsTests: XCTestCase {
    private func tabs(_ client: CoreTestClient) throws -> TabsSnapshot {
        guard case .tabs(let snapshot) = try client.request(.readTabs) else { throw CoreTestError.unexpected("tabs") }
        return snapshot
    }

    private func panes(_ client: CoreTestClient) throws -> [Pane] { try tabs(client).projects.flatMap(\.tabs).flatMap(\.panes) }

    /// A tab with one terminal pane, its terminal started in `server.root`.
    private func terminal(_ client: CoreTestClient, _ server: CoreTestServer) throws -> (Pane, SessionInfo) {
        let home = try client.home()
        let pane = Pane(content: .terminal(session: nil))
        guard case .tabsMutated = try client.request(.mutateTabs(TabIntent(operation: OperationId(),
            mutation: .createTab(project: home, tab: Tab(pane: pane), after: nil)))) else { throw CoreTestError.unexpected("tab") }
        let request = CreateSession(project: home, operation: pane.id.creationToken, directory: ServerPath(server.root.path),
                                    size: Size(cols: 80, rows: 24), pane: pane.id)
        guard case .sessionCreated(let info) = try client.request(.createSession(request)) else {
            throw CoreTestError.unexpected("session")
        }
        return (pane, info)
    }

    /// The terminal the pane shows after the restart, attached.
    private func reopened(_ pane: Pane, in server: CoreTestServer, replacing old: SessionId) throws
        -> (CoreTestClient, SessionId, ChannelId) {
        server.runner?.wait()
        try server.restart()
        let client = try server.connect()
        let shown = try XCTUnwrap(try panes(client).first { $0.id == pane.id }?.content.session, "the pane is kept")
        XCTAssertNotEqual(shown, old, "a new terminal")
        XCTAssertTrue(try client.sessions().contains { $0.id == shown }, "it runs")
        return (client, shown, try client.attach(shown).channel)
    }

    func testAnIdleRestartReopensTerminalsInTheirPanesWithTheirOutput() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let (pane, info) = try terminal(client, server)
        let channel = try client.attach(info.id).channel
        try client.type("echo carried-$((40+2))\r", on: channel)
        try client.waitForRow("carried-42", on: channel)

        XCTAssertEqual(try client.request(.restartServerKeepingTerminals(onlyWhenIdle: true)), .serverRestarting)
        try client.wait("the restart to be announced") { client.events.contains(.serverRestarting) ? true : nil }

        let (later, shown, reopened) = try reopened(pane, in: server, replacing: info.id)
        try later.waitForRow("carried-42", on: reopened)
        try later.waitForRow(TerminalCarryOver.note(stopped: nil), on: reopened)
        try later.type("echo alive-$((1+1))\r", on: reopened)
        try later.waitForRow("alive-2", on: reopened)
        XCTAssertFalse(server.server.archive.contains(info.id), "the old terminal's output lives on in the new one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TerminalCarryOver.url(server.configuration.dirs).path),
                       "the handoff is used once")
        _ = shown

        // A plain restart afterwards ends terminals as before.
        later.close()
        try server.restart()
        XCTAssertTrue(try panes(try server.connect()).isEmpty)
    }

    func testAnIdleOnlyRestartWaitsForARunningProgramAndAForcedOneReopensItsPane() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let (pane, info) = try terminal(client, server)
        let channel = try client.attach(info.id).channel
        try client.type("sleep 30\r", on: channel)
        let work = try client.wait("the program to count as work", timeout: 15) { () -> ServerWork? in
            let work = server.server.pendingWork()
            return work.programs.isEmpty ? nil : work
        }
        XCTAssertEqual(work.programs.map(\.name), ["sleep"])
        XCTAssertEqual(work.programs.first?.session, info.id)

        guard case .serverWorking(let busy) = try client.request(.restartServerKeepingTerminals(onlyWhenIdle: true)) else {
            return XCTFail("restarted while a program ran")
        }
        XCTAssertEqual(busy.programs.map(\.name), ["sleep"])
        XCTAssertEqual(try client.request(.ping), .pong, "the server keeps running")
        XCTAssertTrue(try client.sessions().contains { $0.id == info.id })

        XCTAssertEqual(try client.request(.restartServerKeepingTerminals(onlyWhenIdle: false)), .serverRestarting)
        let (later, _, reopened) = try reopened(pane, in: server, replacing: info.id)
        try later.waitForRow(TerminalCarryOver.note(stopped: "sleep"), on: reopened)
        XCTAssertTrue(later.screen(reopened).contains { $0.hasSuffix("sleep 30") }, "the program's line stays on screen")
    }

    func testAnIdleRestartLeavesIdleTerminalsOutOfTheWorkItReports() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        _ = try terminal(client, server)
        XCTAssertTrue(server.server.pendingWork().isIdle, "a shell at its prompt isn't work")
    }

    func testABackgroundJobOfAnIdleShellCountsAsWork() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let (_, info) = try terminal(client, server)
        let channel = try client.attach(info.id).channel
        try client.type("sleep 30 &\r", on: channel)
        let work = try client.wait("the background job to count as work") { () -> ServerWork? in
            let work = server.server.pendingWork()
            return work.programs.map(\.name) == ["sleep"] ? work : nil
        }
        XCTAssertEqual(work.programs.first?.session, info.id)
        XCTAssertTrue(SessionOwner.isShellHelper("zsh"))
        XCTAssertTrue(SessionOwner.isShellHelper("gitstatusd-darwin-arm64"))
        XCTAssertFalse(SessionOwner.isShellHelper("node"))
    }

    func testARestartAskedForAgainWhileStoppingKeepsTheFirstHandoff() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let (pane, info) = try terminal(client, server)
        let first = try client.send(.restartServerKeepingTerminals(onlyWhenIdle: true))
        let second = try client.send(.restartServerKeepingTerminals(onlyWhenIdle: false))
        XCTAssertEqual(try client.reply(to: first), .serverRestarting)
        XCTAssertEqual(try client.reply(to: second), .serverRestarting)
        _ = try reopened(pane, in: server, replacing: info.id)
    }

    func testAPhoneCantRestartTheServer() throws {
        let server = try CoreTestServer()
        let (serverSide, phoneSide) = try FileDescriptorStream.socketPair()
        server.server.accept(stream: serverSide, origin: .mobile(DeviceId()))
        let phone = CoreTestClient(stream: phoneSide)
        XCTAssertEqual(try phone.request(.restartServerKeepingTerminals(onlyWhenIdle: true)).errorCode, .unauthorized)
    }

    func testADamagedHandoffEndsTerminalsAsBefore() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        _ = try terminal(client, server)
        client.close()
        server.stop()
        try Data("{not json".utf8).write(to: TerminalCarryOver.url(server.configuration.dirs))
        try server.restart()
        XCTAssertTrue(try panes(try server.connect()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TerminalCarryOver.url(server.configuration.dirs).path))
    }
}
