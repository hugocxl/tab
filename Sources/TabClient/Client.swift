import Foundation
import TabCore
import TabProtocol

/// Something the server announced on the control channel, or the end of the
/// connection.
public enum ClientEvent: Hashable, Sendable {
    /// Shared state (catalog, sessions, activity, remote access) changed; read it again.
    case changed(topic: Topic, revision: UInt64)
    case sessionMetadata(session: SessionId, metadata: SessionMetadata)
    case progress(session: SessionId, progress: SessionProgress)
    case sessionEnded(session: SessionId, reason: ExitReason)
    case gitChanged(project: ProjectId)
    case filesChanged(project: ProjectId, changes: FileChanges)
    /// The server is about to restart; connect again.
    case serverRestarting
    /// The connection closed; always the last event.
    case disconnected(ClientError)
}

/// Something that happened on an attached session's channel.
public enum ChannelEvent: Hashable, Sendable {
    /// Draw it, then `ack` its `seq` so the server sends the next one.
    case frame(ScreenFrame)
    case metadata(MetadataEvent)
    /// The session's program ended; the channel is closed.
    case ended(ExitReason)
    /// Another client resized the session.
    case resized(Size)
}

/// An attached session: its first screen and its channel's events, which end
/// on detach, when the session ends, or when the connection closes.
public struct Attachment: Sendable {
    public let session: SessionId
    public let channel: ChannelId
    public let snapshot: AttachSnapshot
    public let process: ForegroundProcess?
    public let events: AsyncStream<ChannelEvent>
}

/// A connection to a Tab server over any byte stream: a Unix socket, SSH
/// stdio or TLS. Requests get ids and await their reply; events arrive on
/// `events`; each attached session gets its own event stream. Writes go
/// through one serial queue in call order, so callers never block on the
/// socket.
public final class ServerClient: @unchecked Sendable {
    /// What the server said in the handshake.
    public let hello: HelloReply
    /// Control-channel events, for one consumer. Finishes after `disconnected`.
    public let events: AsyncStream<ClientEvent>
    /// The default reply budget for requests without one of their own.
    public let defaultTimeout: TimeInterval

    let connection: FrameConnection
    private let state: State
    private let writer: DispatchQueue

    /// The server build and identity.
    public var server: ServerInfo { hello.server }
    public var version: ProtocolVersion { hello.version }

    public func supports(_ feature: Feature) -> Bool { hello.features.contains(feature) }

    public var isConnected: Bool { state.isOpen }

    // MARK: Connecting

    /// Starts the protocol on `stream` and shakes hands. Throws
    /// `versionUnsupported` when the server shares no version with this build.
    public static func connect(stream: ByteStream, kind: ClientKind, clientId: ClientId? = nil,
                               build: BuildInfo = BuildInfo(version: Release.version),
                               timeout: TimeInterval = 5) async throws -> ServerClient {
        let connection = FrameConnection(stream: stream)
        let state = State()
        let (events, continuation) = AsyncStream<ClientEvent>.makeStream()
        state.events = continuation
        let writer = DispatchQueue(label: "TabClient.writer")
        state.start(connection: connection, writer: writer)
        let hello = Hello(versions: ProtocolVersion.supported, client: kind, clientId: clientId, build: build)
        let reply: ReplyBody
        do {
            reply = try await state.request(.hello(hello), timeout: timeout)
        } catch {
            state.close(ClientError(error))
            throw ClientError(error)
        }
        switch reply {
        case .hello(let accepted) where ProtocolVersion.supported.contains(accepted.version):
            return ServerClient(hello: accepted, events: events, connection: connection, state: state,
                                writer: writer, timeout: timeout)
        case .hello(let accepted):
            state.close(.versionUnsupported(server: [accepted.version]))
            throw ClientError.versionUnsupported(server: [accepted.version])
        case .versionUnsupported(let supported):
            state.close(.versionUnsupported(server: supported))
            throw ClientError.versionUnsupported(server: supported)
        default:
            let error = ClientError.protocolViolation("expected a hello reply, got \(reply.typeName)")
            state.close(error)
            throw error
        }
    }

    private init(hello: HelloReply, events: AsyncStream<ClientEvent>, connection: FrameConnection, state: State,
                 writer: DispatchQueue, timeout: TimeInterval) {
        self.hello = hello
        self.events = events
        self.connection = connection
        self.state = state
        self.writer = writer
        defaultTimeout = timeout
    }

    deinit {
        state.close(.disconnected)
    }

    /// Closes the connection: pending requests fail with `disconnected`,
    /// streams finish, and close handlers run.
    public func close() {
        state.close(.disconnected)
    }

    /// Runs `handler` once the connection closes, such as ending the ssh
    /// process that carries it. Runs at once if it already closed.
    public func onClose(_ handler: @escaping @Sendable (ClientError) -> Void) {
        state.addCloseHandler(handler)
    }

    /// Waits until the connection closes, such as when a stopping server has
    /// ended its terminals and gone; false after `timeout`.
    public func waitUntilClosed(timeout: TimeInterval) async -> Bool {
        let closed = AsyncStream<Void> { continuation in
            onClose { _ in continuation.finish() }
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in closed {}
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: Requests

    /// Sends `body` and returns the server's reply; an `error` reply throws
    /// `ClientError.server`. `timeout` defaults to `defaultTimeout`.
    public func request(_ body: RequestBody, timeout: TimeInterval? = nil) async throws -> ReplyBody {
        do {
            try body.validate()
        } catch {
            throw ClientError.invalid(error)
        }
        let reply = try await state.request(body, timeout: timeout ?? defaultTimeout)
        if case .error(let error) = reply { throw ClientError.server(error) }
        return reply
    }

    // MARK: Session channels

    /// Sends input to an attached session; the server encodes keys, mouse,
    /// text and pastes for the terminal.
    public func sendInput(channel: ChannelId, _ input: TerminalInput) throws {
        try send(.input(input), channel: channel)
    }

    /// Sends bytes as they are to an attached session's terminal.
    public func sendRaw(channel: ChannelId, _ bytes: Data) throws {
        guard !channel.isControl else { throw ClientError.invalid(.unknownChannel) }
        guard bytes.count <= Limits.maxInput else { throw ClientError.invalid(.badRequest) }
        try enqueue(FrameEncoder.encode(input: bytes, channel: channel))
    }

    /// Tells the server frame `seq` was drawn, so it may send the next one.
    public func ack(channel: ChannelId, seq: UInt64) throws {
        try send(.ack(seq), channel: channel)
    }

    public func resize(channel: ChannelId, size: Size) throws {
        try send(.resize(size), channel: channel)
    }

    public func scroll(channel: ChannelId, _ scroll: ScrollRequest) throws {
        try send(.scroll(scroll), channel: channel)
    }

    public func sendCellSize(channel: ChannelId, _ cell: CellSize) throws {
        try send(.cellSize(cell), channel: channel)
    }

    /// Asks for a `history` metadata event with the current total.
    public func requestHistory(channel: ChannelId) throws {
        try send(.requestHistory, channel: channel)
    }

    /// Clears the screen through the engine (Cmd+K).
    public func clear(channel: ChannelId) throws {
        try send(.clear, channel: channel)
    }

    private func send(_ message: SessionMessage, channel: ChannelId) throws {
        guard !channel.isControl else { throw ClientError.invalid(.unknownChannel) }
        do {
            try message.validate()
        } catch {
            throw ClientError.invalid(error)
        }
        try enqueue(FrameEncoder.encode(message, channel: channel))
    }

    private func enqueue(_ data: Data) throws {
        guard state.isOpen else { throw ClientError.disconnected }
        state.write(data)
    }

    func registerChannel(_ channel: ChannelId) -> AsyncStream<ChannelEvent>? {
        state.channelStream(channel)
    }

    func finishChannel(_ channel: ChannelId) {
        state.finishChannel(channel)
    }
}

// MARK: - Connection state

/// Everything the reader thread and callers share, behind one lock.
private final class State: @unchecked Sendable {
    private struct Pending {
        var continuation: CheckedContinuation<ReplyBody, Error>
    }

    private let lock = NSLock()
    private var nextId: UInt32 = 1
    private var pending: [RequestId: Pending] = [:]
    /// Streams of attached channels, created when the `attached` reply is
    /// read so no frame after it is missed.
    private var channels: [ChannelId: AsyncStream<ChannelEvent>.Continuation] = [:]
    private var unclaimed: [ChannelId: AsyncStream<ChannelEvent>] = [:]
    private var closeHandlers: [@Sendable (ClientError) -> Void] = []
    private var closedWith: ClientError?
    private var connection: FrameConnection?
    private var writer: DispatchQueue?
    var events: AsyncStream<ClientEvent>.Continuation?

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedWith == nil
    }

    func start(connection: FrameConnection, writer: DispatchQueue) {
        self.connection = connection
        self.writer = writer
        connection.start(name: "TabClient.reader", onFrame: { [weak self] frame in
            self?.receive(frame)
        }, onClose: { [weak self] error in
            self?.close(error.map(ClientError.init) ?? .disconnected)
        })
    }

    func write(_ data: Data) {
        guard let connection, let writer else { return }
        writer.async { [weak self] in
            do {
                try connection.send(encoded: data)
            } catch {
                self?.close(ClientError(error))
            }
        }
    }

    func request(_ body: RequestBody, timeout: TimeInterval) async throws -> ReplyBody {
        let id = try reserveId()
        let data: Data
        do {
            data = try FrameEncoder.encode(Message.request(id, body))
        } catch {
            throw ClientError(error)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ReplyBody, Error>) in
                lock.lock()
                if let closedWith {
                    lock.unlock()
                    continuation.resume(throwing: closedWith)
                    return
                }
                pending[id] = Pending(continuation: continuation)
                lock.unlock()
                write(data)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.fail(id, ClientError.timeout)
                }
            }
        } onCancel: { [weak self] in
            self?.fail(id, CancellationError())
        }
    }

    private func reserveId() throws -> RequestId {
        try lock.withLock {
            if let closedWith { throw closedWith }
            var id = RequestId(nextId)
            while pending[id] != nil {
                nextId &+= 1
                id = RequestId(nextId)
            }
            nextId &+= 1
            return id
        }
    }

    private func fail(_ id: RequestId, _ error: Error) {
        lock.lock()
        let waiting = pending.removeValue(forKey: id)
        lock.unlock()
        waiting?.continuation.resume(throwing: error)
    }

    private func resolve(_ id: RequestId, _ body: ReplyBody) {
        lock.lock()
        let waiting = pending.removeValue(forKey: id)
        if waiting != nil, case .attached(let snapshot, _) = body {
            openChannel(snapshot.channel)
        }
        lock.unlock()
        waiting?.continuation.resume(returning: body)
    }

    /// Call with the lock held.
    private func openChannel(_ channel: ChannelId) {
        channels.removeValue(forKey: channel)?.finish()
        let (stream, continuation) = AsyncStream<ChannelEvent>.makeStream()
        channels[channel] = continuation
        unclaimed[channel] = stream
    }

    func channelStream(_ channel: ChannelId) -> AsyncStream<ChannelEvent>? {
        lock.lock()
        defer { lock.unlock() }
        return unclaimed.removeValue(forKey: channel)
    }

    func finishChannel(_ channel: ChannelId) {
        lock.lock()
        let continuation = channels.removeValue(forKey: channel)
        unclaimed.removeValue(forKey: channel)
        lock.unlock()
        continuation?.finish()
    }

    private func yield(_ event: ChannelEvent, on channel: ChannelId) {
        lock.lock()
        let continuation = channels[channel]
        lock.unlock()
        continuation?.yield(event)
    }

    func addCloseHandler(_ handler: @escaping @Sendable (ClientError) -> Void) {
        lock.lock()
        guard let closedWith else {
            closeHandlers.append(handler)
            lock.unlock()
            return
        }
        lock.unlock()
        handler(closedWith)
    }

    // MARK: Reading

    private func receive(_ frame: IncomingFrame) {
        switch frame {
        case .message(let message):
            receive(message)
        case .session(let channel, let message):
            receive(message, on: channel)
        case .screen(let channel, let screen):
            do {
                try screen.validate()
            } catch {
                return violation("invalid screen frame on channel \(channel)")
            }
            yield(.frame(screen), on: channel)
        case .input, .other:
            break
        }
    }

    private func receive(_ message: Message) {
        switch message {
        case .reply(let id, let body):
            do {
                try body.validate()
            } catch {
                return violation("invalid \(body.typeName) reply")
            }
            resolve(id, body)
        case .event(let body):
            receive(body)
        case .request, .unknown:
            break
        }
    }

    private func receive(_ event: EventBody) {
        do {
            try event.validate()
        } catch {
            return violation("invalid event")
        }
        let mapped: ClientEvent
        switch event {
        case .changed(let topic, let revision): mapped = .changed(topic: topic, revision: revision)
        case .sessionMetadata(let session, let metadata): mapped = .sessionMetadata(session: session, metadata: metadata)
        case .progress(let session, let progress): mapped = .progress(session: session, progress: progress)
        case .sessionEnded(let session, let reason): mapped = .sessionEnded(session: session, reason: reason)
        case .gitChanged(let project): mapped = .gitChanged(project: project)
        case .filesChanged(let project, let changes): mapped = .filesChanged(project: project, changes: changes)
        case .serverRestarting: mapped = .serverRestarting
        case .fatal(let error):
            return close(.server(error))
        case .unknown:
            return
        }
        lock.lock()
        let events = events
        lock.unlock()
        events?.yield(mapped)
    }

    private func receive(_ message: SessionMessage, on channel: ChannelId) {
        do {
            try message.validate()
        } catch {
            return violation("invalid message on channel \(channel)")
        }
        switch message {
        case .metadata(let event):
            yield(.metadata(event), on: channel)
        case .resized(let size):
            yield(.resized(size), on: channel)
        case .ended(let reason):
            yield(.ended(reason), on: channel)
            finishChannel(channel)
        case .input, .resize, .ack, .scroll, .cellSize, .requestHistory, .clear, .unknown:
            break
        }
    }

    private func violation(_ message: String) {
        Log.client.error("closing the connection: \(message, privacy: .public)")
        close(.protocolViolation(message))
    }

    // MARK: Closing

    func close(_ error: ClientError) {
        lock.lock()
        guard closedWith == nil else {
            lock.unlock()
            return
        }
        closedWith = error
        let waiting = pending
        pending = [:]
        let channels = channels
        self.channels = [:]
        unclaimed = [:]
        let handlers = closeHandlers
        closeHandlers = []
        let events = events
        self.events = nil
        let connection = connection
        lock.unlock()
        connection?.close()
        for request in waiting.values {
            request.continuation.resume(throwing: error)
        }
        for channel in channels.values {
            channel.finish()
        }
        events?.yield(.disconnected(error))
        events?.finish()
        for handler in handlers {
            handler(error)
        }
    }
}

extension ReplyBody {
    /// The reply's `type`, for messages.
    var typeName: String {
        guard let data = try? WireJSON.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return "reply" }
        return type
    }
}
