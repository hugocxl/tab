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
