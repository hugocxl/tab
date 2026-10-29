import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

final class CoreServerTests: XCTestCase {
    func testStopRefusesWhileTerminalsRunUnlessForced() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let info = try client.createSession(project: try client.home(), directory: server.root.path)
        XCTAssertEqual(try client.request(.stopServer(force: false)), .serverBusy)
        XCTAssertEqual(try client.request(.stopServerIfIdle), .serverBusy)
        XCTAssertTrue(try client.sessions().contains { $0.id == info.id })

        XCTAssertEqual(try client.request(.stopServer(force: true)), .serverStopping)
        server.runner?.wait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.configuration.socket.path))
        XCTAssertTrue(server.server.archive.contains(info.id), "stopping saves the sessions it ends")
    }

    func testAnIdleServerStopsWhenAsked() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        XCTAssertEqual(try client.request(.stopServerIfIdle), .serverStopping)
        server.runner?.wait()
        try client.wait("the connection to close") { client.isClosed ? true : nil }
    }

    func testOneServerPerProfile() throws {
        let server = try CoreTestServer()
        let second = try Server(configuration: server.configuration)
        XCTAssertThrowsError(try second.start()) { error in
            guard case ServerStartError.alreadyRunning = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try server.connect(), "the first server keeps serving")
    }

    func testAPeerWithoutACommonVersionIsRefused() throws {
        let server = try CoreTestServer()
        let stream = try FileDescriptorStream.connect(unixSocket: server.configuration.socket.path)
        let client = CoreTestClient(stream: stream)
        let reply = try client.request(.hello(Hello(versions: [ProtocolVersion(999)], client: .cli)))
        XCTAssertEqual(reply, .versionUnsupported(supported: ProtocolVersion.supported))
        try client.wait("the connection to close") { client.isClosed ? true : nil }
    }

    func testAPhoneCantManageTheServerOrRunPrograms() throws {
        let server = try CoreTestServer()
        let (serverSide, phoneSide) = try FileDescriptorStream.socketPair()
        server.server.accept(stream: serverSide, origin: .mobile(DeviceId()))
        let phone = CoreTestClient(stream: phoneSide)
        let home = try phone.home()

        XCTAssertEqual(try phone.request(.stopServer(force: true)).errorCode, .unauthorized)
        XCTAssertEqual(try phone.request(.restartServer).errorCode, .unauthorized)
        XCTAssertEqual(try phone.request(.writeServerSettings(ServerSettingsDoc())).errorCode, .unauthorized)
        XCTAssertEqual(try phone.request(.exec(ExecRequest(job: 1, project: home, argv: ["/bin/echo"]))).errorCode,
                       .unauthorized)
        XCTAssertEqual(try phone.request(.readRemoteAccess).errorCode, .unauthorized)
        XCTAssertEqual(try phone.request(.ping), .pong, "the phone is served without a hello")
        XCTAssertNotNil(server.runner, "the server still runs")
        XCTAssertEqual(try server.connect().request(.ping), .pong)
    }

    func testUnknownRequestsGetAnUnsupportedError() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        XCTAssertEqual(try client.request(.unknown("fromTheFuture")).errorCode, .unsupported)
        XCTAssertEqual(try client.request(.git(GitRequest(project: try client.home(), action: .summary))).errorCode,
                       .unsupported, "a server without Git says so")
    }

    func testSettingsRoundTripThroughTheFile() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let settings = ServerSettingsDoc(defaultShell: "/bin/zsh", historyBudgetBytes: 4 * 1024 * 1024,
                                         shellIntegration: false)
        XCTAssertEqual(try client.request(.writeServerSettings(settings)), .serverSettingsWritten)
        XCTAssertEqual(try client.request(.readServerSettings), .serverSettings(settings))
        XCTAssertEqual(try client.request(.writeServerSettings(ServerSettingsDoc(defaultShell: "/no/such/shell")))
            .errorCode, .badPath)

        let url = server.configuration.settings
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        json["addedByANewerBuild"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(try ServerSettingsStore(url: url).settings, settings, "unknown keys are ignored")

        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(try ServerSettingsStore(url: url).settings, ServerSettingsDoc(), "missing keys take defaults")
    }

    func testArgumentsComeFromTheCommandLineAndTheProfileFromTabDir() throws {
        let configuration = try ServerConfiguration.parse(
            ["--socket", "/tmp/s.sock", "--settings", "/tmp/s.json", "--log", "/tmp/s.log"],
            environment: ["TAB_DIR": "/tmp/profile", "HOME": "/Users/someone"])
        XCTAssertEqual(configuration.dirs.root.path, "/tmp/profile")
        XCTAssertEqual(configuration.socket.path, "/tmp/s.sock")
        XCTAssertEqual(configuration.log.path, "/tmp/s.log")
        XCTAssertEqual(configuration.homeDirectory, "/Users/someone")
        XCTAssertThrowsError(try ServerConfiguration.parse(["--socket"], environment: ["TAB_DIR": "/tmp/p"]))
        XCTAssertThrowsError(try ServerConfiguration.parse(["--verbose"], environment: ["TAB_DIR": "/tmp/p"]))
    }

    func testActivityEventsAreOnePerSessionAndClaimedOnce() {
        let activity = Activity()
        let session = SessionId()
        let project = ProjectId()
        activity.update(AgentActivity(session: session, project: project, provider: .claude, state: .working),
                        completed: false)
        activity.update(AgentActivity(session: session, project: project, provider: .claude, state: .blocked),
                        completed: false)
        activity.update(AgentActivity(session: session, project: project, provider: .claude, state: .idle),
                        completed: true)
        let events = activity.snapshot().events
        XCTAssertEqual(events.map(\.kind), [.completed], "a newer event replaces the session's unread one")
        let id = events[0].id
        XCTAssertEqual(activity.claim([id]), [id])
        XCTAssertEqual(activity.claim([id]), [], "only one app delivers a notification")
        activity.acknowledge([id])
        XCTAssertTrue(activity.snapshot().events.isEmpty)
    }
}
