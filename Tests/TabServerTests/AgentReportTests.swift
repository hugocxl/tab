import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

final class AgentReportTests: XCTestCase {
    private func activity(_ client: CoreTestClient) throws -> ActivitySnapshot {
        guard case .activity(let snapshot) = try client.request(.readActivity) else {
            throw CoreTestError.unexpected("activity reply")
        }
        return snapshot
    }

    func testHookReportsDriveTheAgentStateAndAFinishedTurnNotifies() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path)
        let report = { (state: AgentState?) in
            try client.request(.reportAgentState(AgentStateReport(session: info.id, provider: .claude, state: state)))
        }

        XCTAssertEqual(try report(.working), .agentStateReported)
        try client.wait("working") { try? self.activity(client).agents.first { $0.state == .working } }
        _ = try report(.blocked)
        let attention = try client.wait("attention") { try? self.activity(client).events.first { $0.kind == .attention } }
        XCTAssertEqual(attention.provider, .claude)
        _ = try report(.working)
        _ = try report(.idle)
        try client.wait("completed") { try? self.activity(client).events.first { $0.kind == .completed } }

        _ = try report(nil)
        try client.wait("agent gone") { try? self.activity(client).agents.isEmpty ? true : nil }
        guard case .error(let error) = try client.request(.reportAgentState(
            AgentStateReport(session: SessionId(), provider: .codex, state: .idle))) else { return XCTFail("unknown session") }
        XCTAssertEqual(error.code, .unknownSession)
    }

    func testATurnEndingWithBackgroundWorkOnScreenKeepsWorkingUntilItFinishes() throws {
        let prompt = "\n────────────\n❯ \n────────────\n  [Opus] │ tab\n"
        let background = try reportTurnEnd(screen: "● Both agents are still running.\n\n✻ Baked for 1s · done 9:14 AM · 2 shells still running"
            + prompt)
        XCTAssertEqual(try activity(background.client).agents.first { $0.session == background.session }?.state, .working)
        XCTAssertNil(try activity(background.client).events.first { $0.kind == .completed }, "the turn's end is not the work's")

        let finished = try reportTurnEnd(screen: "● Done.\n\n✻ Baked for 1s" + prompt)
        try poll("completed") { try self.activity(finished.client).events.contains { $0.kind == .completed } }
    }

    /// Runs a stand-in `claude` that shows `screen`, then reports a turn that ended
    /// and waits past the time the server gives the screen to show background work.
    private func reportTurnEnd(screen: String) throws -> (server: CoreTestServer, client: CoreTestClient, session: SessionId) {
        let server = try CoreTestServer(services: ServerServices(detector: AgentDetector()))
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path)
        let channel = try client.attach(info.id).channel
        let screenFile = server.root.appendingPathComponent("screen.txt")
        try Data(screen.utf8).write(to: screenFile)
        // A program named like the agent: a shell script would count as a shell, and a copied
        // system program is killed for its signature.
        let agent = server.root.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: agent, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        try client.type("clear; cat '\(screenFile.path)'; '\(agent.path)' 30\r", on: channel)
        try poll("agent found") { try self.activity(client).agents.contains { $0.provider == .claude } }
        for state in [AgentState.working, .idle] {
            _ = try client.request(.reportAgentState(AgentStateReport(session: info.id, provider: .claude, state: state)))
        }
        Thread.sleep(forTimeInterval: SessionOwner.backgroundCheckDelay + 0.5)
        return (server, client, info.id)
    }

    /// Asks again until `check` holds; each request's reply would keep `wait` from timing out.
    private func poll(_ what: String, timeout: TimeInterval = 10, _ check: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !check() {
            guard Date() < deadline else { throw CoreTestError.unexpected(what) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func testAProgramsDesktopNotificationBecomesAnEvent() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path)
        let channel = try client.attach(info.id).channel

        try client.type("printf '\\033]777;notify;Build;Tests passed\\007'\r", on: channel)

        let event = try client.wait("notification") {
            try? self.activity(client).events.first { $0.kind == .notification }
        }
        XCTAssertEqual(event.session, info.id)
        XCTAssertEqual(event.title, "Build")
        XCTAssertEqual(event.body, "Tests passed")
    }

    func testAServerThatDidNotStopCleanlyIsReportedByTheNextOne() throws {
        let server = try CoreTestServer()
        let marker = server.configuration.dirs.serverRunning
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(server.server.info.previousStopUnclean, false)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a clean stop removes the marker")
        try server.restart()
        XCTAssertEqual(server.server.info.previousStopUnclean, false)

        server.stop()
        try Data("1\n".utf8).write(to: marker) // what a crash leaves behind
        try server.restart()
        XCTAssertEqual(server.server.info.previousStopUnclean, true)
    }
}
