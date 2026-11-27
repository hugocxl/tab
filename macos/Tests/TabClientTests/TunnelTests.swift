import Darwin
import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabClient
@testable import TabServer

/// Tunnels through a real server core over a socket pair, to TCP servers on
/// this Mac's loopback.
final class TunnelTests: XCTestCase {
    private var root: URL!
    private var server: Server!
    private var client: ServerClient!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-tunnel-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dirs = TabDirs(root: root)
        try WireJSON.encode(ServerSettingsDoc(startupCommand: ["/bin/cat"], shellIntegration: false)).write(to: dirs.serverSettings)
        server = try Server(configuration: ServerConfiguration(dirs: dirs, uploads: root.appendingPathComponent("uploads")))
        client = try await connect()
    }

    override func tearDown() async throws {
        client?.close()
        server?.endAllSessions()
        server?.closeConnections()
        try? FileManager.default.removeItem(at: root)
    }

    private func connect() async throws -> ServerClient {
        let (serverSide, clientSide) = try FileDescriptorStream.socketPair()
        server.accept(stream: serverSide, origin: .local)
        return try await ServerClient.connect(stream: clientSide, kind: .desktop)
    }

    func testBytesEchoThroughATunnelBothWays() async throws {
        let echo = try LoopbackServer { socket in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(socket, &buffer, buffer.count)
                guard count > 0 else { return }
                _ = buffer.withUnsafeBytes { write(socket, $0.baseAddress, count) }
            }
        }
        let tunnel = try await client.openTunnel(host: "127.0.0.1", port: echo.port)
        try await tunnel.write(Data("hello through the server".utf8))
        let echoed = try await readTunnel(tunnel, count: 24)
        XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "hello through the server")
        tunnel.finishWriting()
        var rest = Data()
        for await chunk in tunnel.bytes { rest.append(chunk) }
        XCTAssertTrue(rest.isEmpty, "the echo server ends after the client's end")
    }

    func testALargeDownloadStaysWithinTheWindowAndTerminalsKeepAnswering() async throws {
        let total = 50 * 1024 * 1024
        let source = try LoopbackServer { socket in
            let chunk = [UInt8](repeating: 0x5A, count: 256 * 1024)
            var sent = 0
            while sent < total {
                let count = chunk.withUnsafeBytes { write(socket, $0.baseAddress, min(chunk.count, total - sent)) }
                guard count > 0 else { return }
                sent += count
            }
        }
        let tunnel = try await client.openTunnel(host: "localhost", port: source.port)
        var received = 0
        var consumed = 0
        var largestOutstanding = 0
        var pings: [TimeInterval] = []
        for await chunk in tunnel.bytes {
            received += chunk.count
            largestOutstanding = max(largestOutstanding, received - consumed)
            if received / (5 * 1024 * 1024) != (received - chunk.count) / (5 * 1024 * 1024) {
                let start = Date()
                try await client.ping()
                pings.append(Date().timeIntervalSince(start))
            }
            consumed += chunk.count
            tunnel.consumed(chunk.count)
        }
        XCTAssertEqual(received, total)
        XCTAssertNil(tunnel.failure)
        XCTAssertLessThanOrEqual(largestOutstanding, Int(Limits.tunnelWindow), "the server never sends past the window")
        XCTAssertFalse(pings.isEmpty)
        XCTAssertLessThan(pings.max() ?? 0, 1, "control requests go before tunnel bytes")
    }

    func testAClosedPortAndAnUnknownNameAreReportedAsSuch() async throws {
        let closed = try LoopbackServer { _ in }
        let port = closed.port
        closed.stop()
        do {
            _ = try await client.openTunnel(host: "127.0.0.1", port: port)
            XCTFail("nothing listens")
        } catch let failure as TunnelFailure {
            XCTAssertEqual(failure, .refused)
        }
        do {
            _ = try await client.openTunnel(host: "no-such-host.invalid", port: 80)
            XCTFail("the name doesn't resolve")
        } catch let failure as TunnelFailure {
            XCTAssertEqual(failure, .nameNotFound)
        }
    }

    func testTunnelsCloseWithTheirConnection() async throws {
        let ended = expectation(description: "the server's socket closed")
        let target = try LoopbackServer { socket in
            var byte: UInt8 = 0
            while Darwin.read(socket, &byte, 1) > 0 {}
            ended.fulfill()
        }
        let tunnel = try await client.openTunnel(host: "127.0.0.1", port: target.port)
        try await tunnel.write(Data("x".utf8))
        client.close()
        await fulfillment(of: [ended], timeout: 5)
        for await _ in tunnel.bytes {}
        XCTAssertNotNil(tunnel.failure)
    }

    func testAClientFreeingATunnelClosesItsSocket() async throws {
        let ended = expectation(description: "the server's socket closed")
        let target = try LoopbackServer { socket in
            var byte: UInt8 = 0
            while Darwin.read(socket, &byte, 1) > 0 {}
            ended.fulfill()
        }
        let tunnel = try await client.openTunnel(host: "127.0.0.1", port: target.port)
        tunnel.close()
        await fulfillment(of: [ended], timeout: 5)
        try await client.ping()
    }

    private func readTunnel(_ tunnel: Tunnel, count: Int) async throws -> Data {
        var data = Data()
        for await chunk in tunnel.bytes {
            data.append(chunk)
            tunnel.consumed(chunk.count)
            if data.count >= count { break }
        }
        return data
    }
}

/// A TCP server on 127.0.0.1 that runs `serve` on its own thread for each
/// connection.
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32

    init(_ serve: @escaping @Sendable (Int32) -> Void) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        self.descriptor = descriptor
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard bound, listen(descriptor, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        port = UInt16(bigEndian: address.sin_port)
        let listener = descriptor
        Thread {
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread {
                    serve(connection)
                    close(connection)
                }.start()
            }
        }.start()
    }

    private let lock = NSLock()
    private var stopped = false

    func stop() {
        let first = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }

    deinit { stop() }
}
