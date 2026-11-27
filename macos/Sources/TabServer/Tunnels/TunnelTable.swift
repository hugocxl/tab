import Darwin
import Foundation
import TabProtocol

/// One connection's tunnels: TCP connections the server makes for the
/// client, such as a remote browser pane loading `localhost:3000`. Everything
/// runs on `queue`; name lookups and connects run on a separate queue, so
/// the connection's reader only hands frames over and never blocks.
///
/// Credit flows both ways: the server reads from a socket only as much as
/// the client granted, and grants the client more as it writes the client's
/// bytes to the socket. A download can't fill the connection's buffers, and a
/// stalled page can't hold up terminals.
final class TunnelTable: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connecting: DispatchQueue
    private let outbox: Outbox
    /// Ends the connection over traffic that breaks the protocol.
    private let violation: @Sendable (String) -> Void
    private var tunnels: [ChannelId: Tunnel] = [:]
    private var opening = 0
    private var closed = false

    /// How long a name lookup and connect may take together.
    static let connectTimeout: TimeInterval = 10
    /// Credit goes back once this much was written, or the socket caught up.
    private static let creditBatch: UInt32 = 64 * 1024

    init(number: Int, outbox: Outbox, violation: @escaping @Sendable (String) -> Void) {
        queue = DispatchQueue(label: "tab.connection.\(number).tunnels", qos: .userInitiated)
        connecting = DispatchQueue(label: "tab.connection.\(number).tunnels.connect", qos: .utility, attributes: .concurrent)
        self.outbox = outbox
        self.violation = violation
    }

    private final class Tunnel {
        let channel: ChannelId
        let descriptor: Int32
        let reader: DispatchSourceRead
        let writer: DispatchSourceWrite
        var readerSuspended = true
        var writerSuspended = true
        /// Bytes the client may still receive.
        var sendCredit = Limits.tunnelWindow
        /// The client's bytes not yet written to the socket.
        var pending: [Data] = []
        var pendingBytes = 0
        /// Bytes written to the socket and not yet granted back.
        var ungranted: UInt32 = 0
        /// The client sends no more.
        var clientEnded = false
        /// The socket sends no more; the client was told.
        var socketEnded = false
        var shutWrite = false

        init(channel: ChannelId, descriptor: Int32, queue: DispatchQueue) {
            self.channel = channel
            self.descriptor = descriptor
            reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        }

        /// What the client sent and the server hasn't granted back yet.
        var outstanding: Int { pendingBytes + Int(ungranted) }
    }

    // MARK: Requests

    /// Connects to `host:port` and replies with the tunnel's channel or why
    /// it failed. `channel` allocates the channel once connected.
    func open(host: String, port: UInt16, channel: @escaping @Sendable () -> ChannelId,
              reply: @escaping @Sendable (ReplyBody) -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            guard tunnels.count + opening < Limits.maxTunnelsPerConnection else {
                reply(.tunnelFailed(.tooMany))
                return
            }
            opening += 1
            connecting.async { [self] in
                let result = Self.connect(host: host, port: port, timeout: Self.connectTimeout)
                queue.async { [self] in
                    opening -= 1
                    switch result {
                    case .failure(let failure):
                        reply(.tunnelFailed(failure))
                    case .success(let descriptor):
                        guard !closed else {
                            Darwin.close(descriptor)
                            return
                        }
                        start(descriptor, channel: channel(), reply: reply)
                    }
                }
            }
        }
    }

    private func start(_ descriptor: Int32, channel: ChannelId, reply: (ReplyBody) -> Void) {
        let tunnel = Tunnel(channel: channel, descriptor: descriptor, queue: queue)
        tunnels[channel] = tunnel
        outbox.openStream(channel)
        let cancelled = CancelCount(descriptor)
        tunnel.reader.setEventHandler { [weak self, weak tunnel] in
            guard let self, let tunnel else { return }
            readSocket(tunnel)
        }
        tunnel.writer.setEventHandler { [weak self, weak tunnel] in
            guard let self, let tunnel else { return }
            writeSocket(tunnel)
        }
        tunnel.reader.setCancelHandler { cancelled.done() }
        tunnel.writer.setCancelHandler { cancelled.done() }
        // The reply goes first: the client knows the channel before any bytes on it.
        reply(.tunnelOpened(channel: channel))
        resumeReader(tunnel)
    }

    /// The client freed the tunnel.
    func close(_ channel: ChannelId) {
        queue.async { [self] in
            guard let tunnel = tunnels.removeValue(forKey: channel) else { return }
            outbox.closeStream(channel)
            free(tunnel)
        }
    }

    /// The connection ended: every tunnel closes.
    func closeAll() {
        queue.async { [self] in
            closed = true
            for tunnel in tunnels.values { free(tunnel) }
            tunnels = [:]
        }
    }

    // MARK: From the client

    /// Bytes for the socket.
    func received(_ data: Data, on channel: ChannelId) {
        queue.async { [self] in
            guard let tunnel = tunnels[channel] else { return }
            guard !tunnel.clientEnded, data.count <= Limits.maxStreamChunk,
                  tunnel.outstanding + data.count <= Int(Limits.tunnelWindow) else {
                violation("Tunnel \(channel) sent past its window")
                return
            }
            guard !data.isEmpty else { return }
            tunnel.pending.append(data)
            tunnel.pendingBytes += data.count
            resumeWriter(tunnel)
        }
    }

    /// The client wrote `bytes` more to its socket.
    func credit(_ bytes: UInt32, on channel: ChannelId) {
        queue.async { [self] in
            guard let tunnel = tunnels[channel] else { return }
            tunnel.sendCredit = min(Limits.tunnelWindow, tunnel.sendCredit &+ bytes)
            if !tunnel.socketEnded { resumeReader(tunnel) }
        }
    }

    /// The client sends no more; the socket's write side shuts once its bytes are out.
    func clientEnded(_ channel: ChannelId) {
        queue.async { [self] in
            guard let tunnel = tunnels[channel], !tunnel.clientEnded else { return }
            tunnel.clientEnded = true
            if tunnel.pending.isEmpty { shutWrite(tunnel) }
        }
    }

    // MARK: Sockets

    private func readSocket(_ tunnel: Tunnel) {
        let wanted = min(Int(tunnel.sendCredit), Limits.maxStreamChunk)
        guard wanted > 0 else {
            suspendReader(tunnel)
            return
        }
        var buffer = Data(count: wanted)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(tunnel.descriptor, $0.baseAddress, wanted) }
        if count > 0 {
            buffer.count = count
            tunnel.sendCredit -= UInt32(count)
            outbox.push(stream: buffer, on: tunnel.channel)
            if tunnel.sendCredit == 0 { suspendReader(tunnel) }
        } else if count == 0 {
            tunnel.socketEnded = true
            suspendReader(tunnel)
            outbox.push(streamMessage: .streamEnd, on: tunnel.channel)
            finishIfDone(tunnel)
        } else if errno != EAGAIN, errno != EINTR {
            fail(tunnel, .failed)
        }
    }

    private func writeSocket(_ tunnel: Tunnel) {
        var written: UInt32 = 0
        while let first = tunnel.pending.first {
            let count = first.withUnsafeBytes { send(tunnel.descriptor, $0.baseAddress, first.count, 0) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { break }
                fail(tunnel, .failed)
                return
            }
            written += UInt32(count)
            tunnel.pendingBytes -= count
            if count == first.count {
                tunnel.pending.removeFirst()
            } else {
                tunnel.pending[0] = first.dropFirst(count)
                break
            }
        }
        tunnel.ungranted += written
        let caughtUp = tunnel.pending.isEmpty
        if tunnel.ungranted > 0, caughtUp || tunnel.ungranted >= Self.creditBatch {
            outbox.push(.credit(tunnel.ungranted), on: tunnel.channel)
            tunnel.ungranted = 0
        }
        guard caughtUp else { return }
        suspendWriter(tunnel)
        if tunnel.clientEnded { shutWrite(tunnel) }
    }

    private func shutWrite(_ tunnel: Tunnel) {
        guard !tunnel.shutWrite else { return }
        tunnel.shutWrite = true
        shutdown(tunnel.descriptor, SHUT_WR)
        finishIfDone(tunnel)
    }

    /// Both directions ended: the server frees the channel.
    private func finishIfDone(_ tunnel: Tunnel) {
        guard tunnel.socketEnded, tunnel.shutWrite, tunnels[tunnel.channel] === tunnel else { return }
        tunnels[tunnel.channel] = nil
        outbox.push(streamMessage: .streamClosed(nil), on: tunnel.channel)
        outbox.closeStream(tunnel.channel, flush: true)
        free(tunnel)
    }

    private func fail(_ tunnel: Tunnel, _ failure: TunnelFailure) {
        guard tunnels[tunnel.channel] === tunnel else { return }
        tunnels[tunnel.channel] = nil
        outbox.push(streamMessage: .streamClosed(failure), on: tunnel.channel)
        outbox.closeStream(tunnel.channel, flush: true)
        free(tunnel)
    }

    /// Cancels the sources; the last cancel handler closes the socket.
    private func free(_ tunnel: Tunnel) {
        tunnel.reader.cancel()
        tunnel.writer.cancel()
        resumeReader(tunnel)
        resumeWriter(tunnel)
    }

    private func resumeReader(_ tunnel: Tunnel) {
        guard tunnel.readerSuspended else { return }
        tunnel.readerSuspended = false
        tunnel.reader.resume()
    }

    private func suspendReader(_ tunnel: Tunnel) {
        guard !tunnel.readerSuspended, !tunnel.reader.isCancelled else { return }
        tunnel.readerSuspended = true
        tunnel.reader.suspend()
    }

    private func resumeWriter(_ tunnel: Tunnel) {
        guard tunnel.writerSuspended else { return }
        tunnel.writerSuspended = false
        tunnel.writer.resume()
    }

    private func suspendWriter(_ tunnel: Tunnel) {
        guard !tunnel.writerSuspended, !tunnel.writer.isCancelled else { return }
        tunnel.writerSuspended = true
        tunnel.writer.suspend()
    }

    // MARK: Connecting

    /// Resolves `host` on this computer and connects to the first address
    /// that answers, within `timeout`. Blocks; call on `connecting`.
    static func connect(host: String, port: UInt16, timeout: TimeInterval) -> Result<Int32, TunnelFailure> {
        let deadline = Date().addingTimeInterval(timeout)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let first = list else {
            return .failure(status == EAI_NONAME || status == EAI_NODATA ? .nameNotFound : .unreachable)
        }
        defer { freeaddrinfo(list) }
        var failure = TunnelFailure.unreachable
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let address = entry {
            entry = address.pointee.ai_next
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .failure(.timedOut) }
            switch connect(address.pointee, timeout: remaining) {
            case .success(let descriptor): return .success(descriptor)
            case .failure(let reason): failure = reason
            }
        }
        return .failure(failure)
    }

    private static func connect(_ address: addrinfo, timeout: TimeInterval) -> Result<Int32, TunnelFailure> {
        let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard descriptor >= 0 else { return .failure(.failed) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var code: Int32 = 0
        if Darwin.connect(descriptor, address.ai_addr, address.ai_addrlen) != 0 {
            code = errno
            if code == EINPROGRESS {
                var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&poller, 1, Int32(max(1, timeout * 1000)))
                if ready == 0 {
                    code = ETIMEDOUT
                } else {
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &length)
                }
            }
        }
        guard code != 0 else { return .success(descriptor) }
        Darwin.close(descriptor)
        switch code {
        case ECONNREFUSED: return .failure(.refused)
        case ETIMEDOUT: return .failure(.timedOut)
        case ENETUNREACH, EHOSTUNREACH, EADDRNOTAVAIL, ENETDOWN, EHOSTDOWN: return .failure(.unreachable)
        default: return .failure(.failed)
        }
    }
}

/// Closes a descriptor once both of its sources are cancelled.
private final class CancelCount: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var remaining = 2

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func done() {
        let last = lock.withLock {
            remaining -= 1
            return remaining == 0
        }
        if last { Darwin.close(descriptor) }
    }
}
