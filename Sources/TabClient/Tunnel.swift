import Foundation
import TabProtocol

/// A TCP connection the server made for this client, such as a remote
/// browser page's. Read `bytes` and call `consumed` once they are written
/// on, which grants the server more; `write` waits while the server's window
/// is full. `bytes` finishes when the server's side ended or the tunnel
/// closed, with `failure` saying why when it failed.
public final class Tunnel: @unchecked Sendable {
    public let channel: ChannelId
    /// The server's bytes, in order.
    public let bytes: AsyncStream<Data>

    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let send: @Sendable (Data) -> Bool
    private let closeRequest: @Sendable () -> Void
    private var sendCredit = Limits.tunnelWindow
    private var ungranted: UInt32 = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var closedWith: TunnelFailure??
    private var writeEnded = false

    /// Credit goes back once this much was consumed, which stays below the
    /// window so the server never waits on a remainder.
    private static let creditBatch: UInt32 = 64 * 1024

    init(channel: ChannelId, send: @escaping @Sendable (Data) -> Bool, close: @escaping @Sendable () -> Void) {
        self.channel = channel
        self.send = send
        closeRequest = close
        (bytes, continuation) = AsyncStream<Data>.makeStream()
    }

    /// Why the tunnel stopped, once it did: `nil` inside for a clean end.
    public var failure: TunnelFailure? { lock.withLock { closedWith ?? nil } }

    /// Sends `data`, waiting for credit as needed. Throws once closed.
    public func write(_ data: Data) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let allowed = try await reserve(min(data.endIndex - offset, Limits.maxStreamChunk))
            let chunk = data[offset ..< offset + allowed]
            guard send(frame(FrameKind.stream, Data(chunk))) else { throw ClientError.disconnected }
            offset += allowed
        }
    }

    /// Waits for credit, then takes up to `wanted` bytes of it.
    private func reserve(_ wanted: Int) async throws -> Int {
        while true {
            let taken: Int? = try lock.withLock {
                if closedWith != nil || writeEnded { throw ClientError.disconnected }
                guard sendCredit > 0 else { return nil }
                let taken = min(Int(sendCredit), wanted)
                sendCredit -= UInt32(taken)
                return taken
            }
            if let taken { return taken }
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                lock.lock()
                if closedWith != nil {
                    lock.unlock()
                    waiter.resume(throwing: ClientError.disconnected)
                } else if sendCredit > 0 {
                    lock.unlock()
                    waiter.resume()
                } else {
                    waiters.append(waiter)
                    lock.unlock()
                }
            }
        }
    }

    /// `count` bytes from `bytes` were written on; the server may send more.
    public func consumed(_ count: Int) {
        let grant: UInt32? = lock.withLock {
            guard closedWith == nil else { return nil }
            ungranted += UInt32(clamping: count)
            guard ungranted >= Self.creditBatch else { return nil }
            defer { ungranted = 0 }
            return ungranted
        }
        if let grant { _ = send(message(.credit(grant))) }
    }

    /// Sends no more; the server's side stays open.
    public func finishWriting() {
        let first: Bool = lock.withLock {
            defer { writeEnded = true }
            return !writeEnded && closedWith == nil
        }
        if first { _ = send(message(.streamEnd)) }
    }

    /// Closes the tunnel at once.
    public func close() {
        guard ended(nil) else { return }
        closeRequest()
    }

    // MARK: From the connection

    func received(_ data: Data) {
        continuation.yield(data)
    }

    func credited(_ bytes: UInt32) {
        let waiting: [CheckedContinuation<Void, Error>] = lock.withLock {
            sendCredit = min(Limits.tunnelWindow, sendCredit &+ bytes)
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func serverEnded() {
        continuation.finish()
    }

    /// The tunnel is gone. False when it already was.
    @discardableResult
    func ended(_ failure: TunnelFailure?) -> Bool {
        let waiting: [CheckedContinuation<Void, Error>]? = lock.withLock {
            guard closedWith == nil else { return nil }
            closedWith = .some(failure)
            defer { waiters = [] }
            return waiters
        }
        guard let waiting else { return false }
        continuation.finish()
        for waiter in waiting { waiter.resume(throwing: ClientError.disconnected) }
        return true
    }

    private func frame(_ kind: FrameKind, _ payload: Data) -> Data {
        (try? FrameEncoder.encode(kind: kind, channel: channel, payload: payload)) ?? Data()
    }

    private func message(_ message: SessionMessage) -> Data {
        (try? FrameEncoder.encode(message, channel: channel)) ?? Data()
    }
}

/// Something that happened on an attached device's channel.
public enum DeviceChannelEvent: Sendable {
    /// Decode and show it, then `ack` its `seq` so the server sends the next one.
    case frame(VideoFrame)
    /// The device shut down; the channel is closed.
    case stopped
}

/// An attached device's screen stream: its format and its channel's events,
/// which end on detach, when the device stops, or when the connection closes.
public struct DeviceAttachment: Sendable {
    public let stream: DeviceStream
    public let events: AsyncStream<DeviceChannelEvent>
}

extension ServerClient {
    // MARK: Tunnels

    /// Connects to `host:port` from the server, where `host` resolves.
    /// Throws a `TunnelFailure` when the server can't connect.
    public func openTunnel(host: String, port: UInt16) async throws -> Tunnel {
        let reply = try await request(.openTunnel(host: host, port: port), timeout: max(defaultTimeout, 15))
        switch reply {
        case .tunnelOpened(let channel):
            guard let tunnel = claimTunnel(channel) else { throw ClientError.disconnected }
            return tunnel
        case .tunnelFailed(let failure):
            throw failure
        default:
            throw unexpected(reply)
        }
    }

    // MARK: Devices

    public func listDevices() async throws -> [DeviceInfo] {
        let reply = try await request(.listDevices, timeout: max(defaultTimeout, 30))
        guard case .devices(let devices) = reply else { throw unexpected(reply) }
        return devices
    }

    /// Runs an action and returns the device's settings afterwards.
    public func deviceAction(_ action: DeviceAction, on device: DeviceRef) async throws -> DeviceSettings {
        let reply = try await request(.deviceAction(device: device, action: action), timeout: max(defaultTimeout, 60))
        guard case .deviceSettings(let settings) = reply else { throw unexpected(reply) }
        return settings
    }

    /// The device's screen as a PNG.
    public func deviceScreenshot(_ device: DeviceRef) async throws -> Data {
        let reply = try await request(.deviceScreenshot(device), timeout: max(defaultTimeout, 30))
        guard case .deviceScreenshot(let png) = reply else { throw unexpected(reply) }
        return png
    }

    public func attachDevice(_ request: AttachDevice) async throws -> DeviceAttachment {
        let reply = try await self.request(.attachDevice(request), timeout: max(defaultTimeout, 30))
        guard case .deviceAttached(let stream) = reply, let events = claimDeviceChannel(stream.channel) else {
            throw unexpected(reply)
        }
        return DeviceAttachment(stream: stream, events: events)
    }

    /// Stops a device's stream; its events finish. A channel the server no
    /// longer knows counts as detached.
    public func detachDevice(channel: ChannelId) async throws {
        defer { finishDeviceChannel(channel) }
        let reply = try await request(.detachDevice(channel))
        guard case .deviceDetached = reply else { throw unexpected(reply) }
    }

    /// Sends touches, keys and buttons to an attached device, in order.
    public func sendDeviceInput(channel: ChannelId, _ input: [DeviceInput]) throws {
        try sendChannelMessage(.deviceInput(input), channel: channel)
    }

    /// Asks for a keyframe next, such as after a decode error.
    public func requestKeyframe(channel: ChannelId) throws {
        try sendChannelMessage(.requestKeyframe, channel: channel)
    }
}
