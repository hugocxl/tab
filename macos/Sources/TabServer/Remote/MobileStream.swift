import Foundation
import Network
import TabProtocol

/// A paired phone's TLS connection as a blocking `ByteStream`.
///
/// Reads and writes block the calling thread until Network.framework
/// completes them, so call them from the connection's reader and writer
/// threads, never from `queue`. Bytes read during admission that belong to
/// later frames are returned first.
public final class MobileStream: ByteStream, @unchecked Sendable {
    /// The device that authenticated or paired on this connection; `nil`
    /// until admission finishes.
    public var device: DeviceId? {
        lock.lock()
        defer { lock.unlock() }
        return admittedDevice
    }

    /// The phone's handshake, already answered by `RemoteAccess`.
    public var hello: Hello? {
        lock.lock()
        defer { lock.unlock() }
        return admittedHello
    }

    let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var admittedDevice: DeviceId?
    private var admittedHello: Hello?
    private var pending = Data()
    private var closed = false
    private var peerClosed = false
    private var closeHandlers: [@Sendable () -> Void] = []
    private var finished = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the connection; returns once TLS is established, or `false`
    /// when it failed or `timeout` passed.
    func start(timeout: TimeInterval) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let signalled = MobileOnce()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if signalled.set() { ready.signal() }
            case .failed, .cancelled:
                if signalled.set() { ready.signal() }
                self?.finish()
            case .waiting:
                // A TLS or network failure before ready: give up rather than retry.
                self?.connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success, connection.state == .ready else {
            close()
            return false
        }
        return true
    }

    /// Runs `handler` once when the connection ends for any reason.
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            handler()
            return
        }
        closeHandlers.append(handler)
        lock.unlock()
    }

    func admitted(device: DeviceId, hello: Hello, leftover: Data) {
        lock.lock()
        admittedDevice = device
        admittedHello = hello
        pending = leftover + pending
        lock.unlock()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || finished
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard buffer.count > 0 else { return 0 }
        lock.lock()
        if !pending.isEmpty {
            let count = min(buffer.count, pending.count)
            pending.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: pending.startIndex ..< pending.startIndex + count)
            pending.removeFirst(count)
            lock.unlock()
            return count
        }
        if closed {
            lock.unlock()
            throw TransportError.closed
        }
        if peerClosed {
            lock.unlock()
            return 0
        }
        lock.unlock()

        let done = DispatchSemaphore(value: 0)
        let result = MobileBox<(Data?, Bool, NWError?)>((nil, false, nil))
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(buffer.count, 1)) { data, _, complete, error in
            result.value = (data, complete, error)
            done.signal()
        }
        done.wait()
        let (data, complete, error) = result.value
        lock.lock()
        defer { lock.unlock() }
        if let data, !data.isEmpty {
            let count = min(buffer.count, data.count)
            data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: data.startIndex ..< data.startIndex + count)
            if count < data.count { pending.append(data.dropFirst(count)) }
            if complete { peerClosed = true }
            return count
        }
        if closed { throw TransportError.closed }
        if let error { throw TransportError.system(operation: "read", errno: Self.code(error)) }
        if complete { peerClosed = true }
        return 0
    }

    public func write(_ data: Data) throws {
        guard !isClosed else { throw TransportError.closed }
        let done = DispatchSemaphore(value: 0)
        let failure = MobileBox<NWError?>(nil)
        connection.send(content: data, completion: .contentProcessed { error in
            failure.value = error
            done.signal()
        })
        done.wait()
        if let error = failure.value {
            if isClosed { throw TransportError.closed }
            throw TransportError.system(operation: "write", errno: Self.code(error))
        }
    }

    public func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        if first { connection.cancel() }
        finish()
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let handlers = closeHandlers
        closeHandlers.removeAll()
        lock.unlock()
        if !isClosedByUs { connection.cancel() }
        handlers.forEach { $0() }
    }

    private var isClosedByUs: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private static func code(_ error: NWError) -> Int32 {
        if case .posix(let code) = error { return code.rawValue }
        return ECONNRESET
    }
}

/// A value shared with a completion handler that a semaphore orders.
final class MobileBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Set once, from any thread.
final class MobileOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// `true` for the call that set it.
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
