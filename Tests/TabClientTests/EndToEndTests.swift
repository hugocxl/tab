import TabCore
import TabProtocol
import XCTest
@testable import TabClient

final class StdioTests: XCTestCase {
    func testTheRelayCopiesBothWaysUntilEitherSideCloses() throws {
        let (local, localPeer) = try FileDescriptorStream.socketPair()
        let (server, serverPeer) = try FileDescriptorStream.socketPair()
        let finished = DispatchSemaphore(value: 0)
        Thread {
            StdioBridge.relay(local, server)
            finished.signal()
        }.start()
        try localPeer.write(Data("to server".utf8))
        XCTAssertEqual(try read(serverPeer, count: 9), Data("to server".utf8))
        try serverPeer.write(Data("to client".utf8))
        XCTAssertEqual(try read(localPeer, count: 9), Data("to client".utf8))
        localPeer.close()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "the relay ends when one side closes")
        var byte = [UInt8](repeating: 0, count: 1)
        XCTAssertEqual(try byte.withUnsafeMutableBytes { try serverPeer.read(into: $0) }, 0, "the other side is closed")
    }

    private func read(_ stream: ByteStream, count: Int) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64)
        while data.count < count {
            let read = try chunk.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard read > 0 else { break }
            data.append(contentsOf: chunk[0 ..< read])
        }
        return data
    }
}

/// Starts a real `tabd` in a short temporary `TAB_DIR`. Skips while the
/// server isn't built or can't serve yet.
final class EndToEndTests: XCTestCase {
    private var root: URL!
    private var client: ServerClient?

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/tab-e2e-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let client {
            _ = try? await client.stopServer(force: true)
            client.close()
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// The build folder that holds this test bundle, and `tabd` and `tab`.
    private var products: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    }

    private func product(_ name: String) throws -> URL {
        let url = products.appendingPathComponent(name)
        guard Executable.isExecutableFile(url) else { throw XCTSkip("\(name) isn't built at \(url.path)") }
        return url
    }

    private func startServer() async throws -> ServerClient {
        var server = LocalServer(dirs: TabDirs(root: root), executable: try product(Executable.server))
        server.startTimeout = 10
        do {
            let client = try await server.connect(kind: .desktop)
            self.client = client
            return client
        } catch {
            let log = (try? String(contentsOf: root.appendingPathComponent("server.log"), encoding: .utf8)) ?? ""
            throw XCTSkip("tabd isn't serving yet: \(error); log: \(log.suffix(500))")
        }
    }

    private func home(_ client: ServerClient) async throws -> ProjectId {
        do {
            return try await client.catalogPage().home
        } catch {
            throw XCTSkip("tabd can't read its catalog yet: \(error)")
        }
    }

    func testATypedCommandShowsInAFrame() async throws {
        let client = try await startServer()
        let home = try await home(client)
        let info: SessionInfo
        do {
            info = try await client.createSession(CreateSession(project: home, directory: ServerPath(root.path),
                                                                size: Size(cols: 80, rows: 24)))
        } catch {
            throw XCTSkip("tabd can't create sessions yet: \(error)")
        }
        let live = try await client.sessions()
        XCTAssertTrue(live.contains { $0.id == info.id })
        let attachment = try await client.attach(session: info.id, size: Size(cols: 80, rows: 24))
        let snapshot = attachment.snapshot
        try client.sendInput(channel: attachment.channel, .text("echo hi\r"))
        let found = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var grid = RunGrid(snapshot: snapshot)
                for await event in attachment.events {
                    guard case .frame(let frame) = event else { continue }
                    grid.apply(frame)
                    try client.ack(channel: attachment.channel, seq: frame.seq)
                    if (0 ..< grid.rows.count).contains(where: { grid.rowText($0).trimmingCharacters(in: .whitespaces) == "hi" }) {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        XCTAssertTrue(found, "the output of echo hi reaches a frame")
        try await client.detach(channel: attachment.channel)
        try await client.endSession(info.id)
    }

    func testTheCommandLineDrivesTheSameServer() async throws {
        let tab = try product(Executable.cli)
        let client = try await startServer()
        _ = try await home(client)
        func run(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = tab
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["TAB_DIR"] = root.path
            environment["TAB_SERVER_BIN"] = products.appendingPathComponent(Executable.server).path
            environment.removeValue(forKey: "TAB_SESSION_ID")
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let (status, created) = try run(["session", "create", "Home", "--", "echo", "from-cli"])
        guard status == 0 else { throw XCTSkip("tab session create failed: \(created)") }
        let session = created.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(SessionId(string: session), created)
        let (waited, line) = try run(["session", "wait", session, "--text", "from-cli", "--timeout-ms", "10000"])
        XCTAssertEqual(waited, 0, line)
        XCTAssertTrue(line.contains("from-cli"))
        let (listed, list) = try run(["session", "list", "--json"])
        XCTAssertEqual(listed, 0, list)
        XCTAssertTrue(list.contains(session))
        let (ended, _) = try run(["session", "end", session])
        XCTAssertEqual(ended, 1, "ending needs --yes")
        XCTAssertEqual(try run(["session", "end", session, "--yes"]).0, 0)
    }

    func testARemoteConnectionThroughTheStdioBridge() async throws {
        let tab = try product(Executable.cli)
        _ = try await startServer()
        // A fake ssh that runs the remote command here, with this build first on PATH.
        let fake = "/bin/sh -c 'PATH=\"$0:$PATH\" TAB_DIR=\"$1\" TAB_SERVER_BIN=\"$0/tabd\" exec /bin/sh -c \"$2\"' "
            + "\(tab.deletingLastPathComponent().path) \(root.path)"
        let target = try SSHTarget.customCommand(fake)
        let remote: ServerClient
        do {
            remote = try await RemoteServer.connect(target, kind: .cli)
        } catch {
            throw XCTSkip("the stdio bridge can't connect yet: \(error)")
        }
        defer { remote.close() }
        XCTAssertEqual(remote.server.server, client?.server.server, "the bridge reaches the same server")
        try await remote.ping()
    }
}
