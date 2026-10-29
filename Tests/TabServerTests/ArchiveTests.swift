import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class ArchiveTests: XCTestCase {
    func testTheSavedScreenAndHistoryAreReadableAfterTheSessionEnds() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path,
                                            size: Size(cols: 80, rows: 8))
        let channel = try client.attach(info.id, size: Size(cols: 80, rows: 8)).channel
        try client.type("echo OLDEST; i=0; while [ $i -lt 30 ]; do echo row$i; i=$((i+1)); done; echo LAST\r",
                        on: channel)
        try client.waitForRow("LAST", on: channel)
        guard case .sessionEnded = try client.request(.endSession(info.id)) else { return XCTFail("end") }

        let reply = try client.request(.readSavedScreen(info.id))
        guard case .savedScreen(let screen) = reply else { return XCTFail("\(reply)") }
        XCTAssertTrue(screen.text.contains { $0.trimmingCharacters(in: .whitespaces) == "LAST" })
        XCTAssertEqual(screen.reason, .ended)

        let page = try client.request(.savedHistoryPage(session: info.id, before: nil, maxRows: 200))
        guard case .historyPage(let history) = page else { return XCTFail("\(page)") }
        XCTAssertTrue(history.rows.contains { $0.runs.map(\.text).joined().contains("OLDEST") })
        XCTAssertNotNil(history.screen, "the first saved page carries the screen")

        let search = try client.request(.searchHistory(source: .saved(info.id), query: "oldest", ignoreCase: true,
                                                       before: nil, maxResults: 5))
        guard case .searchPage(let found) = search else { return XCTFail("\(search)") }
        XCTAssertTrue(found.matches.contains { $0.start == 0 }, "the output line matches")
    }

    func testTheScreenSurvivesAServerRestartAndExpiresAfterAWeek() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let home = try client.home()
        let info = try client.createSession(project: home, directory: server.root.path)
        let channel = try client.attach(info.id).channel
        try client.type("echo BEFORE-RESTART\r", on: channel)
        try client.waitForRow("BEFORE-RESTART", on: channel)
        client.close()

        try server.restart()
        let after = try server.connect()
        XCTAssertTrue(try after.sessions().isEmpty, "programs don't survive the server")
        let reply = try after.request(.readSavedScreen(info.id))
        guard case .savedScreen(let screen) = reply else { return XCTFail("\(reply)") }
        XCTAssertTrue(screen.text.contains { $0.trimmingCharacters(in: .whitespaces) == "BEFORE-RESTART" })
        XCTAssertEqual(screen.reason, .serverStopped)

        let listed = try after.request(.listProjectSessions(project: home, after: nil, revision: nil))
        guard case .projectSessions(let page) = listed else { return XCTFail("\(listed)") }
        XCTAssertEqual(page.sessions.first { $0.info.id == info.id }?.status, .ended)

        server.server.pruneExpiredSessions(now: Clock.now() + 6 * 24 * 60 * 60)
        XCTAssertTrue(server.server.archive.contains(info.id), "kept for a week")
        server.server.pruneExpiredSessions(now: Clock.now() + 8 * 24 * 60 * 60)
        XCTAssertFalse(server.server.archive.contains(info.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: server.configuration.dirs.sessions.appendingPathComponent(info.id.description).path))
        let gone = try after.request(.listProjectSessions(project: home, after: nil, revision: nil))
        guard case .projectSessions(let empty) = gone else { return XCTFail("\(gone)") }
        XCTAssertTrue(empty.sessions.isEmpty)
    }

    func testDiscardingDeletesTheSavedFiles() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path)
        guard case .sessionEnded = try client.request(.endSession(info.id)) else { return XCTFail("end") }
        XCTAssertTrue(server.server.archive.contains(info.id))
        guard case .sessionDiscarded = try client.request(.discardSession(info.id)) else { return XCTFail("discard") }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: server.configuration.dirs.sessions.appendingPathComponent(info.id.description).path))
    }
}
