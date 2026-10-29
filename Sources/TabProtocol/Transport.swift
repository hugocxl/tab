import Darwin
import Foundation

/// An ordered, reliable byte stream: a Unix socket, a pipe pair (SSH stdio),
/// or a TLS session. `read` and `write` block; they may run on different
/// threads at once. `close` wakes both and makes later calls fail.
public protocol ByteStream: AnyObject, Sendable {
    /// Reads at least one byte into `buffer`; 0 means the peer closed.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    /// Writes all of `data`.
    func write(_ data: Data) throws
    func close()
}

public enum TransportError: Error, Hashable, Sendable, CustomStringConvertible {
    /// This side closed the stream.
    case closed
    /// A system call failed with `errno`.
    case system(operation: String, errno: Int32)
    /// A Unix socket path longer than `sockaddr_un` holds.
    case pathTooLong(String)
    /// Another server already listens on the socket.
    case addressInUse(String)

    public var description: String {
        switch self {
        case .closed: "connection closed"
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        case .pathTooLong(let path): "socket path too long: \(path)"
        case .addressInUse(let path): "already in use: \(path)"
        }
    }

    static func last(_ operation: String) -> TransportError {
        .system(operation: operation, errno: errno)
    }
}

/// A byte stream over POSIX file descriptors: one socket for both
/// directions, or separate read and write descriptors such as a child's
/// stdout and stdin, or this process's own stdin and stdout.
public final class FileDescriptorStream: ByteStream, @unchecked Sendable {
    public let readDescriptor: Int32
    public let writeDescriptor: Int32
    private let ownsDescriptors: Bool
    private let writesToSocket: Bool
    /// Written by `close` to wake a blocked `poll`.
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
    private var isClosed = false

    /// - Parameter ownsDescriptors: close the descriptors when the stream is released.
    public init(readDescriptor: Int32, writeDescriptor: Int32, ownsDescriptors: Bool = true) throws {
        self.readDescriptor = readDescriptor
        self.writeDescriptor = writeDescriptor
        self.ownsDescriptors = ownsDescriptors
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { throw TransportError.last("pipe") }
        wakeRead = pipe[0]
        wakeWrite = pipe[1]
        for descriptor in [wakeRead, wakeWrite] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        // A peer that went away must fail the write, not kill the process:
        // sockets write with MSG_NOSIGNAL, pipes are marked here.
        var info = stat()
        writesToSocket = fstat(writeDescriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
        if !writesToSocket { _ = fcntl(writeDescriptor, F_SETNOSIGPIPE, 1) }
    }

    /// A connected socket used in both directions.
    public convenience init(socket: Int32, ownsDescriptor: Bool = true) throws {
        try self.init(readDescriptor: socket, writeDescriptor: socket, ownsDescriptors: ownsDescriptor)
    }

    deinit {
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
        guard ownsDescriptors else { return }
        Darwin.close(readDescriptor)
        if writeDescriptor != readDescriptor { Darwin.close(writeDescriptor) }
    }

    private var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    /// Waits until `descriptor` is ready for `events`; throws once closed.
    private func wait(for descriptor: Int32, events: Int16) throws {
        var fds = [
            pollfd(fd: descriptor, events: events, revents: 0),
            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            if closed { throw TransportError.closed }
            let result = poll(&fds, 2, -1)
            if result < 0 {
                if errno == EINTR { continue }
                throw TransportError.last("poll")
            }
            if fds[1].revents != 0 || closed { throw TransportError.closed }
            if fds[0].revents != 0 { return }
        }
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        while true {
            try wait(for: readDescriptor, events: Int16(POLLIN))
            let count = Darwin.read(readDescriptor, base, buffer.count)
            if count >= 0 { return count }
            if errno == EINTR || errno == EAGAIN { continue }
            if closed { throw TransportError.closed }
            if errno == ECONNRESET { return 0 }
            throw TransportError.last("read")
        }
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(for: writeDescriptor, events: Int16(POLLOUT))
                let chunk = min(bytes.count - offset, 256 * 1024)
                let count = writesToSocket
                    ? send(writeDescriptor, base + offset, chunk, MSG_NOSIGNAL)
                    : Darwin.write(writeDescriptor, base + offset, chunk)
                if count >= 0 {
                    offset += count
                    continue
                }
                if errno == EINTR || errno == EAGAIN { continue }
                if closed { throw TransportError.closed }
                throw TransportError.last("write")
            }
        }
    }

    public func close() {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !wasClosed else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
        // Wakes the peer and any blocked call on sockets; harmless on pipes.
        _ = shutdown(readDescriptor, SHUT_RDWR)
        if writeDescriptor != readDescriptor { _ = shutdown(writeDescriptor, SHUT_RDWR) }
    }

    /// Two connected Unix sockets.
    public static func socketPair() throws -> (FileDescriptorStream, FileDescriptorStream) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw TransportError.last("socketpair") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (try FileDescriptorStream(socket: fds[0]), try FileDescriptorStream(socket: fds[1]))
    }

    /// Connects to a Unix socket.
    public static func connect(unixSocket path: String) throws -> FileDescriptorStream {
        var address = try UnixSocketAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.last("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let result = address.withSockaddr { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let error = TransportError.last("connect")
            Darwin.close(fd)
            throw error
        }
        return try FileDescriptorStream(socket: fd)
    }
}

/// A listening Unix socket. A stale socket file left by a crashed server is
/// replaced; a live one makes `init` throw `addressInUse`.
public final class UnixSocketListener: @unchecked Sendable {
    public let path: String
    private let descriptor: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
    private var isClosed = false

    public init(path: String) throws {
        self.path = path
        var address = try UnixSocketAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.last("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        if address.withSockaddr({ bind(fd, $0, $1) }) != 0 {
            guard errno == EADDRINUSE else {
                let error = TransportError.last("bind")
                Darwin.close(fd)
                throw error
            }
            if (try? FileDescriptorStream.connect(unixSocket: path)) != nil {
                Darwin.close(fd)
                throw TransportError.addressInUse(path)
            }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0,
                  address.withSockaddr({ bind(fd, $0, $1) }) == 0 else {
                let error = TransportError.last("bind")
                Darwin.close(fd)
                throw error
            }
        }
        guard listen(fd, 64) == 0 else {
            let error = TransportError.last("listen")
            Darwin.close(fd)
            throw error
        }
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else {
            let error = TransportError.last("pipe")
            Darwin.close(fd)
            throw error
        }
        descriptor = fd
        wakeRead = pipe[0]
        wakeWrite = pipe[1]
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
    }

    /// Blocks until a client connects; throws `closed` after `close()`.
    public func accept() throws -> FileDescriptorStream {
        var fds = [
            pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            lock.lock()
            let closed = isClosed
            lock.unlock()
            if closed { throw TransportError.closed }
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                throw TransportError.last("poll")
            }
            if fds[1].revents != 0 { throw TransportError.closed }
            guard fds[0].revents != 0 else { continue }
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
                throw TransportError.last("accept")
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            return try FileDescriptorStream(socket: client)
        }
    }

    /// Stops accepting and removes the socket file.
    public func close() {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !wasClosed else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
        unlink(path)
    }
}

private struct UnixSocketAddress {
    var storage = sockaddr_un()

    init(_ path: String) throws {
        storage.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: storage.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { throw TransportError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &storage.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        storage.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    }

    mutating func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

// MARK: - Frame connection

/// Frames over a byte stream: a reader thread that decodes and delivers
/// incoming frames in order, and writes that are serialized and blocking.
public final class FrameConnection: @unchecked Sendable {
    public let stream: ByteStream
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var reader: FrameReader
    private var started = false

    /// - Parameter maxFrame: the largest payload accepted from the peer, e.g.
    ///   smaller before a phone authenticates.
    public init(stream: ByteStream, maxFrame: Int = Limits.maxFrame) {
        self.stream = stream
        reader = FrameReader(maxFrame: maxFrame)
    }

    /// Starts the reader thread. `onFrame` runs on it for every frame, in
    /// order; `onClose` runs once after the last frame, with `nil` when the
    /// peer closed cleanly, or the error (malformed traffic, I/O, `close()`).
    /// The stream is closed before `onClose` runs.
    public func start(name: String = "TabProtocol.FrameConnection",
                      onFrame: @escaping @Sendable (IncomingFrame) -> Void,
                      onClose: @escaping @Sendable (Error?) -> Void) {
        stateLock.lock()
        let alreadyStarted = started
        started = true
        stateLock.unlock()
        precondition(!alreadyStarted, "FrameConnection started twice")
        let thread = Thread { [self] in
            var failure: Error?
            do {
                while let frame = try receive() { onFrame(frame) }
            } catch {
                failure = error
            }
            stream.close()
            onClose(failure)
        }
        thread.name = name
        thread.start()
    }

    /// Reads the next frame, blocking; `nil` when the peer closed cleanly.
    /// For synchronous use (a CLI handshake) without `start`.
    public func receive() throws -> IncomingFrame? {
        guard let frame = try receiveFrame() else { return nil }
        return try frame.decoded()
    }

    /// The next raw frame, blocking; `nil` when the peer closed cleanly.
    public func receiveFrame() throws -> Frame? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let frame = try reader.next() { return frame }
            let count = try chunk.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 {
                try reader.finish()
                return nil
            }
            chunk.withUnsafeBytes { reader.append(UnsafeRawBufferPointer(rebasing: $0[0 ..< count])) }
        }
    }

    /// Writes one encoded frame; safe from any thread.
    public func send(encoded data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try stream.write(data)
    }

    public func send(_ frame: Frame) throws {
        try send(encoded: try FrameEncoder.encode(frame))
    }

    public func send(_ message: Message) throws {
        try send(encoded: try FrameEncoder.encode(message))
    }

    public func send(_ message: SessionMessage, on channel: ChannelId) throws {
        try send(encoded: try FrameEncoder.encode(message, channel: channel))
    }

    public func send(screen: ScreenFrame, on channel: ChannelId) throws {
        try send(encoded: try FrameEncoder.encode(screen: screen, channel: channel))
    }

    public func send(input: Data, on channel: ChannelId) throws {
        try send(encoded: try FrameEncoder.encode(input: input, channel: channel))
    }

    /// Closes the stream, waking the reader thread, which then calls `onClose`.
    public func close() {
        stream.close()
    }
}
