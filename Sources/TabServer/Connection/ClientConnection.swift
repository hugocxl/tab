import Foundation
import TabProtocol

/// One client on one byte stream. A reader thread handles input, acks and
/// pings at once and hands other requests to an ordered worker; a writer
/// thread sends what the outbox yields.
final class ClientConnection: @unchecked Sendable {
    let number: Int
    unowned let server: Server
    let frames: FrameConnection
    let outbox = Outbox()
    let worker: DispatchQueue
    let jobs = ExecJobs()

    let lock = NSLock()
    private(set) var origin: ConnectionOrigin
    private var handshaken: Bool
    private var identity: SessionClient
    private var channels: [ChannelId: Channel] = [:]
    private var lastChannel: UInt32 = 0
    private var closed = false
    // Which sessions this client shows; see `Server.syncReferences`.
    var references = References()
    private var reported: Set<SessionId> = []
    private var created: Set<SessionId> = []
    /// When this client started showing each session; the earliest owns it.
    private var positions: [SessionId: UInt64] = [:]
    private var watchesCatalog = false
    private var watchesActivity = false
    private var colors: TerminalColors?
    private var sentMetadata: [SessionId: SessionMetadata] = [:]
    private var sentProgress: [SessionId: SessionProgress] = [:]

    struct Channel {
        let owner: SessionOwner
        let attachment: UInt64
        let sink: ChannelSink
    }

    init(number: Int, server: Server, stream: ByteStream, origin: ConnectionOrigin) {
        self.number = number
        self.server = server
        self.origin = origin
        frames = FrameConnection(stream: stream)
        worker = DispatchQueue(label: "tab.connection.\(number)", qos: .userInitiated)
        if case .mobile = origin {
            let hello = (stream as? MobileStream)?.hello
            handshaken = true
            identity = SessionClient(id: hello?.clientId ?? ClientId(), kind: .mobile)
        } else {
            handshaken = false
            identity = SessionClient(id: ClientId(), kind: .desktop)
        }
    }

    // MARK: Lifecycle

    func start() {
        let writer = Thread { [self] in
            while let data = outbox.next() {
                do {
                    try frames.send(encoded: data)
                } catch {
                    break
                }
            }
            frames.close()
        }
        writer.name = "tab.connection.\(number).writer"
        writer.qualityOfService = .userInitiated
        writer.start()
        frames.start(name: "tab.connection.\(number).reader", onFrame: { [self] frame in
            received(frame)
        }, onClose: { [self] error in
            if let error, !(error is TransportError) {
                ServerLog.info("client \(number) closed: \(error)")
            }
            disconnect()
        })
    }

    /// Ends the connection: detaches channels, releases its sessions and
    /// stops its jobs and service watches.
    func disconnect() {
        let detached: [Channel]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            let detached = Array(channels.values)
            channels = [:]
            positions = [:]
            return detached
        }
        guard let detached else { return }
        for channel in detached { channel.owner.detach(channel.attachment) }
        jobs.cancelAll()
        outbox.close()
        frames.close()
        server.connectionClosed(self)
    }

    /// Stops after sending what is already queued.
    func finish() {
        outbox.finish()
    }

    var isClosed: Bool { lock.withLock { closed } }
    var client: SessionClient { lock.withLock { identity } }
    var isHandshaken: Bool { lock.withLock { handshaken && !closed } }
    var device: DeviceId? {
        if case .mobile(let device) = origin { return device }
        return nil
    }

    // MARK: Reading

    private func received(_ frame: IncomingFrame) {
        guard lock.withLock({ handshaken }) else {
            handshake(frame)
            return
        }
        switch frame {
        case .message(.request(let id, let body)):
            request(id, body)
        case .session(let channel, let message):
            session(channel, message)
        case .input(let channel, let data):
            guard let target = attached(channel) else { return }
            do {
                try Validation.input(data)
            } catch {
                fatal("Input exceeds the limit")
                return
            }
            target.owner.input(data)
        case .other:
            break
        case .message, .screen:
            fatal("Misplaced client message")
        }
    }

    private func handshake(_ frame: IncomingFrame) {
        guard case .message(.request(let id, .hello(let hello))) = frame else {
            fatal("Expected hello first")
            return
        }
        guard !hello.versions.isEmpty, let version = ProtocolVersion.negotiate(hello.versions) else {
            outbox.push(.reply(id, .versionUnsupported(supported: ProtocolVersion.supported)))
            outbox.finish()
            return
        }
        lock.withLock {
            handshaken = true
            identity = SessionClient(id: hello.clientId ?? ClientId(), kind: hello.client.isKnown ? hello.client : .desktop)
        }
        outbox.push(.reply(id, .hello(HelloReply(version: version, server: server.info))))
    }

    /// Ends the connection because of malformed traffic.
    func fatal(_ message: String) {
        ServerLog.error("client \(number): \(message)")
        outbox.push(.event(.fatal(ErrorReply(code: .badRequest, message: message))))
        outbox.finish()
    }

    /// A channel this connection attached, or `nil` for a detached one.
    /// Channels it never opened end the connection.
    private func attached(_ channel: ChannelId) -> Channel? {
        let (known, target) = lock.withLock { (channel.rawValue <= lastChannel, channels[channel]) }
        if !known { fatal("Unknown channel \(channel)") }
        return target
    }

    private func session(_ channel: ChannelId, _ message: SessionMessage) {
        guard let target = attached(channel) else { return }
        do {
            try message.validate()
        } catch {
            fatal("Invalid session message")
            return
        }
        switch message {
        case .input(let input): target.owner.input(input)
        case .resize(let size): target.owner.resize(size)
        case .ack(let seq): outbox.ack(seq, on: channel)
        case .scroll(let scroll): target.owner.scroll(scroll)
        case .cellSize(let cell): target.owner.setCellSize(cell)
        case .requestHistory: target.owner.requestHistory(target.attachment)
        case .clear: target.owner.clearScreen()
        case .unknown: break
        case .metadata, .ended, .resized: fatal("Misplaced session message")
        }
    }

    func reply(_ id: RequestId, _ body: ReplyBody) {
        outbox.push(.reply(id, body))
    }

    func reply(_ id: RequestId, _ result: Result<ReplyBody, Error>) {
        switch result {
        case .success(let body): reply(id, body)
        case .failure(let error): reply(id, .error(errorReply(error)))
        }
    }

    // MARK: Channels

    /// Opens a channel for `owner` and asks it to attach.
    func attach(_ owner: SessionOwner, size: Size?, request: RequestId) {
        let (channel, sink, colors): (ChannelId, ChannelSink, TerminalColors?) = lock.withLock {
            lastChannel += 1
            let channel = ChannelId(lastChannel)
            let sink = ChannelSink(connection: self, channel: channel, request: request)
            channels[channel] = Channel(owner: owner, attachment: server.nextAttachment(), sink: sink)
            created.remove(owner.info.id)
            references.released.remove(owner.info.id)
            return (channel, sink, self.colors)
        }
        outbox.openChannel(channel)
        refreshPositions()
        if let colors { owner.setColors(colors) }
        guard let attachment = lock.withLock({ channels[channel]?.attachment }) else { return }
        owner.attach(attachment, sink: sink, size: size)
    }

    func detach(_ channel: ChannelId) throws {
        guard let removed = lock.withLock({ channels.removeValue(forKey: channel) }) else {
            throw ServiceError.unknownChannel(channel)
        }
        removed.owner.detach(removed.attachment)
        outbox.closeChannel(channel)
        refreshPositions()
    }

    /// The session behind a channel.
    func owner(of channel: ChannelId) throws -> SessionOwner {
        guard let channel = lock.withLock({ channels[channel] }) else { throw ServiceError.unknownChannel(channel) }
        return channel.owner
    }

    /// A channel's session ended or its attach failed.
    func channelClosed(_ channel: ChannelId, flush: Bool = false) {
        guard lock.withLock({ channels.removeValue(forKey: channel) }) != nil else { return }
        outbox.closeChannel(channel, flush: flush)
        refreshPositions()
    }

    func detachSession(_ session: SessionId) {
        let removed: [(ChannelId, Channel)] = lock.withLock {
            created.remove(session)
            let matching = channels.filter { $0.value.owner.info.id == session }
            for (channel, _) in matching { channels[channel] = nil }
            return Array(matching)
        }
        for (channel, target) in removed {
            target.owner.detach(target.attachment)
            outbox.closeChannel(channel)
        }
        refreshPositions()
    }

    /// The colors the app set, for sessions it creates.
    var colorsForNewSession: TerminalColors? { lock.withLock { colors } }

    func setColors(_ colors: TerminalColors) {
        let owners = lock.withLock { () -> [SessionOwner] in
            self.colors = colors
            return channels.values.map(\.owner)
        }
        for owner in owners { owner.setColors(colors) }
    }

    func setKind(_ kind: ClientKind) -> SessionClient {
        let (client, changed) = lock.withLock { () -> (SessionClient, Bool) in
            let changed = identity.kind != kind
            identity.kind = kind
            return (identity, changed && !positions.isEmpty)
        }
        if changed { server.sessionsChanged() }
        return client
    }

    // MARK: Shown sessions

    func createdSession(_ session: SessionId) {
        lock.withLock {
            guard !closed else { return }
            created.insert(session)
        }
        refreshPositions()
    }

    func setReferences(_ references: References, reported: [SessionId]?, acknowledgeCreation: Bool) {
        let shown: Set<SessionId> = lock.withLock {
            created = created.filter { !acknowledgeCreation && !references.sessions.contains($0) }
            if let reported { self.reported = Set(reported) }
            self.reported.formIntersection(references.sessions)
            sentMetadata = sentMetadata.filter { references.sessions.contains($0.key) }
            sentProgress = sentProgress.filter { references.sessions.contains($0.key) }
            self.references = references
            return references.sessions
        }
        outbox.dropSessionEvents(keeping: shown)
        refreshPositions()
        for session in shown {
            guard let owner = server.owner(session) else { continue }
            sessionMetadata(session, owner.metadata)
            sessionProgress(session, owner.progress)
        }
    }

    /// Whether this client shows `session`: in its references or, with
    /// `includeChannels`, created by it or attached and not released.
    func shows(_ session: SessionId, includeChannels: Bool) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if references.sessions.contains(session) { return true }
            guard includeChannels else { return false }
            return created.contains(session)
                || (!references.released.contains(session) && channels.values.contains { $0.owner.info.id == session })
        }
    }

    func isReleased(_ session: SessionId) -> Bool {
        lock.withLock { references.owner != nil && references.released.contains(session) }
    }

    /// When this client started showing `session`, if it does.
    func position(of session: SessionId) -> (UInt64, SessionClient)? {
        lock.withLock { closed ? nil : positions[session].map { ($0, identity) } }
    }

    var hasPositions: Bool { lock.withLock { !positions.isEmpty } }

    private func refreshPositions() {
        let changed: Bool = lock.withLock {
            guard !closed else { return false }
            var shown = reported.union(created)
            for channel in channels.values where !references.released.contains(channel.owner.info.id) {
                shown.insert(channel.owner.info.id)
            }
            let before = positions.count
            positions = positions.filter { shown.contains($0.key) }
            var changed = before != positions.count
            for session in shown where positions[session] == nil {
                positions[session] = server.nextPosition()
                changed = true
            }
            return changed
        }
        if changed { server.sessionsChanged() }
    }

    // MARK: Events

    func watchCatalog() { lock.withLock { watchesCatalog = true } }
    func watchActivity() { lock.withLock { watchesActivity = true } }
    var watchingCatalog: Bool { lock.withLock { watchesCatalog } }
    var watchingActivity: Bool { lock.withLock { watchesActivity } }

    func sessionMetadata(_ session: SessionId, _ metadata: SessionMetadata) {
        let send: Bool = lock.withLock {
            guard references.sessions.contains(session), sentMetadata[session] != metadata else { return false }
            sentMetadata[session] = metadata
            return true
        }
        if send { outbox.push(.event(.sessionMetadata(session: session, metadata: metadata))) }
    }

    func sessionProgress(_ session: SessionId, _ progress: SessionProgress) {
        let send: Bool = lock.withLock {
            guard references.sessions.contains(session), (sentProgress[session] ?? SessionProgress()) != progress
            else { return false }
            sentProgress[session] = progress
            return true
        }
        if send { outbox.push(.event(.progress(session: session, progress: progress))) }
    }

    /// The session ended: forget it, close its channels, tell the client.
    func sessionEnded(_ session: SessionId, reason: ExitReason) {
        let channels: [ChannelId] = lock.withLock {
            guard !closed else { return [] }
            created.remove(session)
            references.sessions.remove(session)
            reported.remove(session)
            sentMetadata[session] = nil
            sentProgress[session] = nil
            let matching = self.channels.filter { $0.value.owner.info.id == session }.map(\.key)
            for channel in matching { self.channels[channel] = nil }
            return matching
        }
        for channel in channels { outbox.closeChannel(channel) }
        outbox.dropSessionEvents(keeping: lock.withLock { references.sessions })
        refreshPositions()
        outbox.push(.event(.sessionEnded(session: session, reason: reason)))
    }
}

/// Which sessions a client shows. Apps with several connections share one
/// owner; the newest revision wins.
struct References {
    var owner: OperationId?
    var revision: UInt64 = 0
    var sessions: Set<SessionId> = []
    /// Sessions the client stopped showing; attaching them again needs a new reference.
    var released: Set<SessionId> = []

    mutating func update(owner: OperationId?, revision: UInt64, sessions: [SessionId]) {
        let next = Set(sessions)
        released.formUnion(self.sessions.subtracting(next))
        released.subtract(next)
        self.owner = owner
        self.revision = revision
        self.sessions = next
    }
}

/// One attached channel, as the session sees it.
final class ChannelSink: SessionSink, @unchecked Sendable {
    private weak var connection: ClientConnection?
    let channel: ChannelId
    private let request: RequestId

    init(connection: ClientConnection, channel: ChannelId, request: RequestId) {
        self.connection = connection
        self.channel = channel
        self.request = request
    }

    func attached(_ snapshot: AttachSnapshot, process: ForegroundProcess?) -> Bool {
        guard let connection, !connection.outbox.isClosed else { return false }
        var snapshot = snapshot
        snapshot.channel = channel
        connection.reply(request, .attached(snapshot: snapshot, process: process))
        return true
    }

    func frame(_ frame: ScreenFrame) -> Bool {
        connection?.outbox.push(frame, on: channel) ?? false
    }

    func metadata(_ event: MetadataEvent) -> Bool {
        connection?.outbox.push(.metadata(event), on: channel) ?? false
    }

    func resized(_ size: Size) -> Bool {
        connection?.outbox.push(.resized(size), on: channel) ?? false
    }

    func ended(_ reason: ExitReason) {
        guard let connection else { return }
        connection.outbox.push(.ended(reason), on: channel)
        connection.channelClosed(channel, flush: true)
    }

    func failed(_ error: ErrorReply) {
        guard let connection else { return }
        connection.reply(request, .error(error))
        connection.channelClosed(channel)
    }
}
