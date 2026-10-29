import Darwin
import XCTest
@testable import TabProtocol

final class TransportTests: XCTestCase {
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [IncomingFrame] = []
        private var closeError: Error?
        let received = XCTestExpectation(description: "frames")
        let closed = XCTestExpectation(description: "closed")

        func add(_ frame: IncomingFrame) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
            received.fulfill()
        }

        func close(_ error: Error?) {
            lock.lock()
            closeError = error
            lock.unlock()
            closed.fulfill()
        }

        var all: [IncomingFrame] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return closeError
        }
    }

    func testFramesCrossASocketPairInOrderAndPeerCloseIsClean() throws {
        let (left, right) = try FileDescriptorStream.socketPair()
        let sender = FrameConnection(stream: left)
        let receiver = FrameConnection(stream: right)
        let inbox = Inbox()
        inbox.received.expectedFulfillmentCount = 4
        receiver.start(onFrame: { inbox.add($0) }, onClose: { inbox.close($0) })

        let screen = ScreenFrame(size: Size(cols: 2, rows: 1), seq: 1, reset: true,
                                 rows: [Row(index: 0, runs: [Run(text: "hi", width: 2)])], cursor: Cursor())
        try sender.send(.request(RequestId(1), .ping))
        try sender.send(.ack(1), on: ChannelId(4))
        try sender.send(screen: screen, on: ChannelId(4))
        try sender.send(input: Data("ls\r".utf8), on: ChannelId(4))
        wait(for: [inbox.received], timeout: 5)
        XCTAssertEqual(inbox.all, [
            .message(.request(RequestId(1), .ping)), .session(ChannelId(4), .ack(1)),
            .screen(ChannelId(4), screen), .input(ChannelId(4), Data("ls\r".utf8)),
        ])

        sender.close()
        wait(for: [inbox.closed], timeout: 5)
        XCTAssertNil(inbox.error)
    }

    func testCloseWakesABlockedReader() throws {
        let (left, right) = try FileDescriptorStream.socketPair()
        let connection = FrameConnection(stream: right)
        let inbox = Inbox()
        connection.start(onFrame: { inbox.add($0) }, onClose: { inbox.close($0) })
        connection.close()
        wait(for: [inbox.closed], timeout: 5)
        XCTAssertEqual(inbox.error as? TransportError, .closed)
        XCTAssertThrowsError(try connection.send(.event(.serverRestarting)))
        withExtendedLifetime(left) {}
    }

    func testCloseWakesABlockedPipeRead() throws {
        var pipe: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&pipe), 0)
        let stream = try FileDescriptorStream(readDescriptor: pipe[0], writeDescriptor: pipe[1])
        let done = expectation(description: "read returned")
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 16)
            do {
                _ = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
                XCTFail("read returned after close")
            } catch {
                XCTAssertEqual(error as? TransportError, .closed)
            }
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        stream.close()
        wait(for: [done], timeout: 5)
    }

    func testLargeFrameAcrossManyReads() throws {
        let (left, right) = try FileDescriptorStream.socketPair()
        let sender = FrameConnection(stream: left)
        let receiver = FrameConnection(stream: right)
        let payload = Data((0 ..< 8 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        DispatchQueue.global().async {
            try? sender.send(input: payload, on: ChannelId(2))
        }
        XCTAssertEqual(try receiver.receive(), .input(ChannelId(2), payload))
    }

    func testOversizedFrameFromPeerClosesWithAnError() throws {
        let (left, right) = try FileDescriptorStream.socketPair()
        let receiver = FrameConnection(stream: right, maxFrame: 16)
        try left.write(FrameEncoder.encode(input: Data(count: 17), channel: ChannelId(1)))
        XCTAssertThrowsError(try receiver.receive()) { error in
            XCTAssertEqual(error as? FramingError, .frameTooLarge(length: 17, limit: 16))
        }
    }

    func testWritingToAClosedPeerFailsWithoutSignal() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        close(fds[1])
        // Created after the peer left, when socket options can no longer be set.
        let socket = try FileDescriptorStream(socket: fds[0])
        XCTAssertThrowsError(try socket.write(Data(count: 1024)))

        var pipe: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&pipe), 0)
        close(pipe[0])
        let pipeStream = try FileDescriptorStream(readDescriptor: dup(0), writeDescriptor: pipe[1])
        XCTAssertThrowsError(try pipeStream.write(Data(count: 1024)))
    }

    func testUnixSocketListener() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("tabp-\(getpid())-\(UInt16.random(in: 0 ... .max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s").path

        let listener = try UnixSocketListener(path: path)
        let accepted = expectation(description: "accepted")
        let serverSide = LockedBox<FileDescriptorStream>()
        DispatchQueue.global().async {
            serverSide.value = try? listener.accept()
            accepted.fulfill()
        }
        let client = FrameConnection(stream: try FileDescriptorStream.connect(unixSocket: path))
        wait(for: [accepted], timeout: 5)
        let server = FrameConnection(stream: try XCTUnwrap(serverSide.value))
        try client.send(.request(RequestId(9), .listSessions))
        XCTAssertEqual(try server.receive(), .message(.request(RequestId(9), .listSessions)))
        try server.send(.reply(RequestId(9), .sessions([])))
        XCTAssertEqual(try client.receive(), .message(.reply(RequestId(9), .sessions([]))))

        // A second server finds this one alive. Its probe connection must not hurt it.
        XCTAssertThrowsError(try UnixSocketListener(path: path)) { error in
            XCTAssertEqual(error as? TransportError, .addressInUse(path))
        }
        let probe = try listener.accept()
        XCTAssertThrowsError(try probe.write(Data(count: 1024 * 1024)))

        let stopped = expectation(description: "accept stopped")
        DispatchQueue.global().async {
            do {
                _ = try listener.accept()
                XCTFail("accepted after close")
            } catch {
                XCTAssertEqual(error as? TransportError, .closed)
            }
            stopped.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        listener.close()
        wait(for: [stopped], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testStaleSocketFileIsReplaced() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("tabq-\(getpid())-\(UInt16.random(in: 0 ... .max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s").path

        // A bound socket nobody listens on, as a crashed server leaves behind.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(fd)

        let listener = try UnixSocketListener(path: path)
        XCTAssertNoThrow(try FileDescriptorStream.connect(unixSocket: path))
        listener.close()
    }

    func testSocketPathTooLong() {
        XCTAssertThrowsError(try FileDescriptorStream.connect(unixSocket: "/" + String(repeating: "a", count: 200)))
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

extension TransportTests {
    /// A replaced server that closes late must not remove the socket file a
    /// newer server bound at the same path.
    func testClosingAReplacedListenerKeepsTheNewerSocketFile() throws {
        let path = "/tmp/tab-\(UInt32.random(in: 0...UInt32.max)).sock"
        defer { unlink(path) }
        let stale = try UnixSocketListener(path: path)
        unlink(path)
        let fresh = try UnixSocketListener(path: path)
        stale.close()
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0, "the newer server's socket file was removed")
        fresh.close()
        XCTAssertNotEqual(lstat(path, &info), 0, "the owner removes its own socket file")
    }
}
