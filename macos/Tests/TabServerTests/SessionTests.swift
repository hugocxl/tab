import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class SessionTests: XCTestCase {
    func testATypedCommandReachesAFrameAndTheSessionOutlivesItsClient() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let home = try client.home()
        let info = try client.createSession(project: home, directory: server.root.path)
        let snapshot = try client.attach(info.id)
        let channel = snapshot.channel
        try client.wait("a prompt") {
            client.screen(channel).contains { $0.contains("$") } ? true : nil
        }

        try client.type("echo hi\r", on: channel)
        try client.waitForRow("hi", on: channel)

        guard case .detached = try client.request(.detach(channel)) else { return XCTFail("detach") }
        XCTAssertTrue(try client.sessions().contains { $0.id == info.id }, "detaching keeps the session running")

        client.close()
        let other = try server.connect()
        XCTAssertTrue(try other.sessions().contains { $0.id == info.id }, "disconnecting keeps it running too")
        guard case .sessionEnded = try other.request(.endSession(info.id)) else { return XCTFail("end") }
        XCTAssertFalse(try other.sessions().contains { $0.id == info.id })
    }

    func testTheEnvironmentNamesTabAndTheSession() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path)
        let channel = try client.attach(info.id).channel
        try client.type("echo \"$TERM_PROGRAM:$TERM:$TAB_SESSION_ID\"\r", on: channel)
        try client.waitForRow("tab:xterm-256color:\(info.id)", on: channel)
    }

    func testTheFirstClientsSizeIsSharedAndAResizeReachesEveryone() throws {
        let server = try CoreTestServer()
        let first = try server.connect()
        let second = try server.connect()
        let info = try first.createSession(project: try first.home(), directory: server.root.path)
        let firstChannel = try first.attach(info.id, size: Size(cols: 80, rows: 24)).channel
        let joined = try second.attach(info.id, size: Size(cols: 120, rows: 40))
        XCTAssertEqual(joined.size, Size(cols: 80, rows: 24), "a second client gets the session's size")

        let larger = Size(cols: 100, rows: 30)
        try second.connection.send(.resize(larger), on: joined.channel)
        try first.wait("the resize") {
            first.messages(firstChannel).contains(.resized(larger)) ? true : nil
        }
        let frame = try first.wait("a full frame") {
            first.frames(firstChannel).last { $0.size == larger }
        }
        XCTAssertTrue(frame.reset, "a resize sends the whole screen")
    }

    func testASlowClientGetsOneMergedFrameInsteadOfAQueue() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path)
        let channel = try client.attach(info.id).channel
        let first = try client.wait("the first frame") { client.frames(channel).first }

        try client.type("i=0; while [ $i -lt 300 ]; do echo line$i; i=$((i+1)); done; echo done\r", on: channel)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(client.frames(channel).count, 1, "nothing more is sent before the client acks")

        try client.ack(first.seq, on: channel)
        try client.waitForRow("done", on: channel)
        XCTAssertLessThan(client.frames(channel).count, 30, "output merged into few frames")
    }

    func testEndingAProgramReportsHowItExited() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path,
                                            command: "exit 3")
        _ = try client.request(.syncSessionReferences(owner: nil, revision: 1, sessions: [info.id]))
        let reason = try client.wait("the end") { () -> ExitReason? in
            for event in client.events {
                if case .sessionEnded(info.id, let reason) = event { return reason }
            }
            return nil
        }
        XCTAssertEqual(reason, .exited(3))
    }

    func testDeletingAProjectEndsItsSessions() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let folder = server.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = ProjectDescriptor.new(directory: ServerPath(folder.path))
        _ = try client.request(.mutateProject(ProjectIntent(mutation: .create(project))))
        let info = try client.createSession(project: project.id, directory: folder.path)

        let reply = try client.request(.mutateProject(ProjectIntent(mutation: .delete(project.id))))
        guard case .projectMutated = reply else { return XCTFail("\(reply)") }
        XCTAssertFalse(try client.sessions().contains { $0.id == info.id })
        XCTAssertEqual(try client.request(.readSavedScreen(info.id)).errorCode, .savedContentUnavailable,
                       "the project's saved output is gone too")
    }

    func testHistorySearchFindsOutputThatScrolledAway() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path)
        let channel = try client.attach(info.id, size: Size(cols: 80, rows: 10)).channel
        try client.type("echo NEEDLE; i=0; while [ $i -lt 40 ]; do echo filler; i=$((i+1)); done; echo end\r",
                        on: channel)
        try client.waitForRow("end", on: channel)

        let reply = try client.request(.searchHistory(source: .live(channel), query: "needle", ignoreCase: true,
                                                      before: nil, maxResults: 10))
        guard case .searchPage(let page) = reply else { return XCTFail("\(reply)") }
        XCTAssertFalse(page.matches.isEmpty)
        let exact = try client.request(.searchHistory(source: .live(channel), query: "needle", ignoreCase: false,
                                                      before: nil, maxResults: 10))
        guard case .searchPage(let none) = exact else { return XCTFail("\(exact)") }
        XCTAssertTrue(none.matches.isEmpty, "a case-sensitive search tells NEEDLE from needle")

        let history = try client.request(.historyPage(channel: channel, before: nil, maxRows: 100))
        guard case .historyPage(let rows) = history else { return XCTFail("\(history)") }
        XCTAssertTrue(rows.rows.contains { $0.runs.map(\.text).joined().contains("NEEDLE") })
    }
}
