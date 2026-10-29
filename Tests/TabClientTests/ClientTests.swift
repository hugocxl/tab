import TabProtocol
import XCTest
@testable import TabClient

/// The server side of a socket pair: answers requests with `respond` and
/// records what the client sent on session channels.
final class FakeServer: @unchecked Sendable {
    let connection: FrameConnection
    let client: FileDescriptorStream
    private let lock = NSLock()
    private var sessionMessages: [(ChannelId, SessionMessage)] = []
    private var rawInput: [(ChannelId, Data)] = []
    var respond: @Sendable (RequestId, RequestBody, FakeServer) -> Void

    init(respond: @escaping @Sendable (RequestId, RequestBody, FakeServer) -> Void = { FakeServer.standard($0, $1, $2) }) throws {
        let (server, client) = try FileDescriptorStream.socketPair()
        self.client = client
        connection = FrameConnection(stream: server)
        self.respond = respond
        connection.start(name: "FakeServer", onFrame: { [weak self] frame in
            guard let self else { return }
            switch frame {
            case .message(.request(let id, let body)): self.respond(id, body, self)
            case .session(let channel, let message): self.record(channel, message)
            case .input(let channel, let data): self.record(channel, data)
            default: break
            }
        }, onClose: { _ in })
    }

    static let serverInfo = ServerInfo(build: BuildInfo(version: "9.9.9"), instance: 7, server: ServerId())

    static func standard(_ id: RequestId, _ body: RequestBody, _ server: FakeServer) {
        switch body {
        case .hello: server.reply(id, .hello(HelloReply(version: .current, server: serverInfo)))
        case .ping: server.reply(id, .pong)
        default: server.reply(id, .error(ErrorReply(code: .unsupported, message: "not in this fake")))
        }
    }

    private func record(_ channel: ChannelId, _ message: SessionMessage) {
        lock.withLock { sessionMessages.append((channel, message)) }
    }

    private func record(_ channel: ChannelId, _ data: Data) {
        lock.withLock { rawInput.append((channel, data)) }
    }

    func reply(_ id: RequestId, _ body: ReplyBody) {
        try? connection.send(Message.reply(id, body))
    }

    func event(_ body: EventBody) {
        try? connection.send(Message.event(body))
    }

    var received: [(ChannelId, SessionMessage)] { lock.withLock { sessionMessages } }
    var input: [(ChannelId, Data)] { lock.withLock { rawInput } }

    func connect() async throws -> ServerClient {
        try await ServerClient.connect(stream: client, kind: .cli, timeout: 2)
    }
}

final class ClientTests: XCTestCase {
    func testHandshakeNegotiatesAVersionAndReportsWhatTheServerOffers() async throws {
        let server = try FakeServer()
        let client = try await server.connect()
        defer { client.close() }
        XCTAssertEqual(client.version, .current)
        XCTAssertEqual(client.server, FakeServer.serverInfo)
        XCTAssertTrue(client.supports(.terminalInput))
        try await client.ping()
    }

    func testServersWithoutASharedVersionAreRefused() async throws {
        let refusing = try FakeServer { id, body, server in
            server.reply(id, .versionUnsupported(supported: [ProtocolVersion(9)]))
        }
        do {
            _ = try await refusing.connect()
            XCTFail("no shared version")
        } catch ClientError.versionUnsupported(let versions) {
            XCTAssertEqual(versions, [ProtocolVersion(9)])
        }
        let newer = try FakeServer { id, _, server in
            server.reply(id, .hello(HelloReply(version: ProtocolVersion(99), server: FakeServer.serverInfo)))
        }
        do {
            _ = try await newer.connect()
            XCTFail("a version this build doesn't speak")
        } catch ClientError.versionUnsupported {}
        let silent = try FakeServer { _, _, _ in }
        do {
            _ = try await silent.connect()
            XCTFail("no answer")
        } catch ClientError.timeout {}
    }

    func testRepliesFindTheirRequestsInAnyOrderAndErrorsThrow() async throws {
        let held = Held()
        let server = try FakeServer { id, body, server in
            switch body {
            case .hello: FakeServer.standard(id, body, server)
            case .readSavedScreen: held.add(id)
            case .ping:
                server.reply(id, .pong)
                for waiting in held.take() {
                    server.reply(waiting, .error(ErrorReply(code: .unknownSession, message: "gone")))
                }
            default: FakeServer.standard(id, body, server)
            }
        }
        let client = try await server.connect()
        defer { client.close() }
        async let saved = client.readSavedScreen(SessionId())
        while held.count == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        try await client.ping()
        do {
            _ = try await saved
            XCTFail("an error reply throws")
        } catch let error as ClientError {
            XCTAssertEqual(error.serverCode, .unknownSession)
        }
        do {
            _ = try await client.sessions()
            XCTFail("unsupported")
        } catch let error as ClientError {
            XCTAssertEqual(error.serverCode, .unsupported)
        }
    }

    func testAnAttachedChannelGetsItsFramesAndSendsInputAcksAndResizes() async throws {
        let session = SessionId()
        let channel = ChannelId(4)
        let server = try FakeServer { id, body, server in
            guard case .attach(let requested, let size) = body, requested == session else {
                return FakeServer.standard(id, body, server)
            }
            let snapshot = AttachSnapshot(channel: channel, size: size, rows: [Row(index: 0, runs: [Run(text: "$ ",
                                                                                                         width: 2)])],
                                          cursor: Cursor(row: 0, col: 2), directory: "/tmp")
            server.reply(id, .attached(snapshot: snapshot, process: ForegroundProcess(name: "zsh", isShell: true)))
            // Frames right after the reply must not be lost.
            let frame = ScreenFrame(size: size, seq: 1, reset: false, rows: [Row(index: 0, runs: [Run(text: "$ hi",
                                                                                                     width: 4)])],
                                    cursor: Cursor(row: 0, col: 4))
            try? server.connection.send(screen: frame, on: channel)
            try? server.connection.send(SessionMessage.metadata(.title("hi")), on: channel)
            try? server.connection.send(SessionMessage.ended(.exited(3)), on: channel)
        }
        let client = try await server.connect()
        defer { client.close() }
        let attachment = try await client.attach(session: session, size: Size(cols: 80, rows: 24))
        XCTAssertEqual(attachment.channel, channel)
        XCTAssertEqual(attachment.process?.name, "zsh")
        var grid = RunGrid(snapshot: attachment.snapshot)
        var events: [ChannelEvent] = []
        for await event in attachment.events {
            events.append(event)
            if case .frame(let frame) = event {
                grid.apply(frame)
                try client.ack(channel: channel, seq: frame.seq)
            }
        }
        XCTAssertEqual(events.count, 3, "the stream ends with the session")
        XCTAssertEqual(events.last, .ended(.exited(3)))
        XCTAssertEqual(grid.rowText(0), "$ hi")
        try client.sendInput(channel: channel, .text("ls\r"))
        try client.resize(channel: channel, size: Size(cols: 100, rows: 30))
        try client.sendRaw(channel: channel, Data([3]))
        try await client.ping()
        let received = server.received
        XCTAssertEqual(received.map(\.0), [channel, channel, channel])
        XCTAssertEqual(received.map(\.1), [.ack(1), .input(.text("ls\r")), .resize(Size(cols: 100, rows: 30))])
        XCTAssertEqual(server.input.first?.1, Data([3]))
        XCTAssertThrowsError(try client.sendInput(channel: .control, .text("x")))
    }

    func testEventsArriveAndADroppedConnectionFailsWhatWaits() async throws {
        let server = try FakeServer { id, body, server in
            if case .hello = body { return FakeServer.standard(id, body, server) }
            server.event(.changed(topic: .catalog, revision: 4))
            server.connection.close()
        }
        let client = try await server.connect()
        do {
            _ = try await client.catalogPage()
            XCTFail("the server hung up")
        } catch ClientError.disconnected {}
        var events: [ClientEvent] = []
        for await event in client.events { events.append(event) }
        XCTAssertEqual(events, [.changed(topic: .catalog, revision: 4), .disconnected(.disconnected)])
        XCTAssertFalse(client.isConnected)
        do {
            try await client.ping()
            XCTFail("closed")
        } catch ClientError.disconnected {}
        let closed = Flag()
        client.onClose { _ in closed.set() }
        XCTAssertTrue(closed.isSet, "close handlers added late still run")
    }

    func testMalformedTrafficClosesTheConnection() async throws {
        let server = try FakeServer { id, body, server in
            if case .hello = body { return FakeServer.standard(id, body, server) }
            try? server.connection.send(Frame(kind: .screen, channel: .control, payload: Data([1, 2, 3])))
        }
        let client = try await server.connect()
        do {
            try await client.ping()
            XCTFail("broken traffic")
        } catch ClientError.protocolViolation {}
    }

    func testRequestsFailValidationBeforeTheyAreSent() async throws {
        let server = try FakeServer()
        let client = try await server.connect()
        defer { client.close() }
        do {
            _ = try await client.searchHistory(.saved(SessionId()), query: "", ignoreCase: false, maxResults: 10)
            XCTFail("an empty query is invalid")
        } catch ClientError.invalid(let code) {
            XCTAssertEqual(code, .badRequest)
        }
    }

    func testPendingClosesReplayInOrderAndKeepWhatFails() async throws {
        let gone = SessionId()
        let closed = SessionId()
        let failing = SessionId()
        let seen = Held()
        let server = try FakeServer { id, body, server in
            guard case .closeSession(let session, _) = body else { return FakeServer.standard(id, body, server) }
            seen.add(id)
            switch session {
            case gone: server.reply(id, .error(ErrorReply(code: .unknownSession, message: "gone")))
            case closed: server.reply(id, .sessionClosed)
            default: server.reply(id, .error(ErrorReply(code: .persistenceFailed, message: "disk full")))
            }
        }
        let client = try await server.connect()
        defer { client.close() }
        var closes = PendingCloses()
        for session in [gone, failing, closed] { closes.queue(session) }
        let result = await closes.replay(on: client)
        XCTAssertEqual(result.closed, [gone, closed])
        XCTAssertEqual(result.failed.map(\.0), [failing])
        XCTAssertFalse(result.disconnected)
        XCTAssertEqual(closes.sessions, [failing])
        XCTAssertEqual(seen.count, 3)
    }
}

final class Held: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [RequestId] = []
    func add(_ id: RequestId) { lock.withLock { ids.append(id) } }
    func take() -> [RequestId] { lock.withLock { defer { ids = [] }; return ids } }
    var count: Int { lock.withLock { ids.count } }
}
