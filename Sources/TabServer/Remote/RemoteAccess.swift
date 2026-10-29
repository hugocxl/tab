import Foundation
import Network
import Security
import TabCore
import TabProtocol

/// Mobile access: the opt-in TLS listener for paired phones, pairing codes,
/// and the paired devices in `remote.json`.
///
/// Admission contract with the server core: `RemoteAccess` itself answers the
/// first two control requests on every network connection, before any other
/// code sees it.
///
/// 1. `hello` is answered with `.hello(HelloReply)` for the newest shared
///    protocol version (or `.versionUnsupported`, closing the connection).
/// 2. `authenticate` is answered with `.authenticated`, or `pair` with
///    `.paired(Paired)`. Anything else, or a failure, is answered with an
///    `unauthorized` error and the connection closes.
///
/// Only then is the connection handed to `ConnectionAcceptor.accept(stream:
/// origin: .mobile(device))`. The stream is a `MobileStream` whose next bytes
/// are the phone's third frame onward, and whose `hello` holds the phone's
/// handshake (client kind and id). The core must therefore serve a `.mobile`
/// stream as already handshaken and authenticated: it must not wait for
/// `hello`, and it must refuse `authenticate`, `pair` and every other request
/// phones may not send. `revoke` and disabling access close these streams,
/// which the core sees as the peer closing.
///
/// Unauthenticated connections are limited to 16 at a time and 10 seconds,
/// with frames of at most 64 KiB.
public final class RemoteAccess: RemoteAccessProtocol, @unchecked Sendable {
    static let pairingLifetime: UInt64 = 5 * 60
    static let maxUnauthenticated = 16
    static let admissionTimeout: TimeInterval = 10
    static let unauthenticatedFrameLimit = 64 * 1024

    private let file: URL
    private let server: ServerInfo
    private weak var events: ServiceEvents?
    private let bindAddress: String?
    /// Unix seconds; replaced in tests to expire pairing codes.
    var clock: @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }

    private let lock = NSLock()
    /// Serializes listener changes, which wait for Network.framework.
    private let configuring = NSLock()
    private var store = RemoteStore()
    private var unreadable: String?
    private var status: ListenerStatus = .disabled
    private var offer: (code: Data, expiresAt: UInt64)?
    private var revision: UInt64 = 1
    private var acceptor: ConnectionAcceptor?
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: MobileStream] = [:]
    private var unauthenticated = 0

    /// - Parameters:
    ///   - file: `remote.json`, normally `TabDirs.remoteAccess`.
    ///   - server: This server's identity, sent in the `hello` reply and to paired phones.
    ///   - events: Receives `.changed(topic: .remoteAccess, revision:)` on every change.
    ///   - bindAddress: An IPv4 address to listen on instead of every interface,
    ///     such as `127.0.0.1` in tests.
    public init(file: URL, server: ServerInfo, events: ServiceEvents? = nil, bindAddress: String? = nil) {
        self.file = file
        self.server = server
        self.events = events
        self.bindAddress = bindAddress
        do {
            store = try RemoteStoreFile.load(file)
        } catch {
            let message = String("\(file.path): \(error)".prefix(1000))
            Log.mobile.error("mobile access disabled: \(message, privacy: .public)")
            unreadable = message
            status = .failed(message)
        }
    }

    public convenience init(dirs: TabDirs, server: ServerInfo, events: ServiceEvents? = nil) {
        self.init(file: dirs.remoteAccess, server: server, events: events)
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - RemoteAccessProtocol

    public func state() -> RemoteAccessState {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        let connected = Set(streams.values.compactMap { $0.isClosed ? nil : $0.device })
        return RemoteAccessState(
            revision: revision,
            settings: store.settings,
            status: status,
            pairingExpiresAt: offer.map(\.expiresAt).flatMap { $0 > now ? $0 : nil },
            devices: store.devices.map {
                PairedDevice(id: $0.id, name: $0.name, pairedAt: $0.pairedAt, lastSeen: $0.lastSeen,
                             connected: connected.contains($0.id))
            }
        )
    }

    public func write(_ settings: RemoteAccessSettings) throws {
        do {
            try settings.validate()
        } catch {
            throw ServiceError(.badRequest, "Choose a port between 1024 and 65535")
        }
        configuring.lock()
        defer { configuring.unlock() }
        lock.lock()
        // Access is already off; keep the unreadable file for recovery.
        if unreadable != nil, !settings.enabled {
            lock.unlock()
            return
        }
        var stored = unreadable == nil ? store : RemoteStore()
        stored.settings = settings
        do {
            if settings.enabled, stored.identity == nil {
                stored.identity = try ServerCertificate.generate()
            }
            try save(stored)
        } catch {
            lock.unlock()
            throw error
        }
        unreadable = nil
        if !settings.enabled { offer = nil }
        store = stored
        lock.unlock()
        changed()
        applyListener()
    }

    public func startPairing(hosts given: [String]) throws -> PairingOffer {
        do {
            try Validation.pairingHosts(given)
        } catch {
            throw ServiceError(.badRequest, "Enter host names or IPv4 addresses without ports")
        }
        let hosts = PairingHosts.candidates(given: given)
        lock.lock()
        guard let identity = store.identity, store.settings.enabled, unreadable == nil else {
            lock.unlock()
            throw ServiceError(.badRequest, "Mobile access is off")
        }
        guard status == .listening else {
            lock.unlock()
            throw ServiceError(.badRequest, "Mobile access is not listening")
        }
        guard store.devices.count < Limits.maxDevices else {
            lock.unlock()
            throw ServiceError(.badRequest, "Revoke a paired device before pairing another")
        }
        let code: Data
        do {
            code = try secureRandom(16)
        } catch {
            lock.unlock()
            throw error
        }
        let invite = PairingInvite(hosts: hosts, port: store.settings.port, fingerprint: identity.fingerprint,
                                   code: code)
        guard (try? invite.validate()) != nil else {
            lock.unlock()
            throw ServiceError(.badRequest, "No network address found for pairing")
        }
        let expiresAt = clock() + Self.pairingLifetime
        offer = (code, expiresAt)
        lock.unlock()
        changed()
        return PairingOffer(invite: invite, expiresAt: expiresAt)
    }

    public func cancelPairing() {
        lock.lock()
        let had = offer != nil
        offer = nil
        lock.unlock()
        if had { changed() }
    }

    public func pair(_ request: PairRequest) throws -> Paired {
        let refused = ServiceError(.unauthorized, "The pairing code is wrong or expired")
        guard request.code.count == 16, (try? Validation.deviceName(request.name)) != nil else { throw refused }
        let now = clock()
        lock.lock()
        guard store.settings.enabled, unreadable == nil, let pending = offer else {
            lock.unlock()
            throw refused
        }
        if pending.expiresAt <= now {
            offer = nil
            lock.unlock()
            throw refused
        }
        guard constantTimeEqual(pending.code, request.code), store.devices.count < Limits.maxDevices else {
            lock.unlock()
            throw refused
        }
        let token: Data
        let salt: Data
        do {
            token = try secureRandom(32)
            salt = try secureRandom(16)
        } catch {
            lock.unlock()
            throw error
        }
        let id = DeviceId()
        var stored = store
        stored.devices.append(StoredDevice(
            id: id, name: request.name.trimmingCharacters(in: .whitespaces), salt: salt,
            tokenHash: StoredDevice.hash(token, salt: salt), pairedAt: now, lastSeen: now
        ))
        do {
            try save(stored)
        } catch {
            lock.unlock()
            Log.mobile.error("pairing not saved: \(String(describing: error), privacy: .public)")
            throw error
        }
        store = stored
        offer = nil
        lock.unlock()
        changed()
        Log.mobile.info("paired device \(id.description, privacy: .public)")
        let paired = Paired(credential: DeviceCredential(device: id, token: token), server: server.server,
                            name: PairingHosts.displayName())
        if (try? paired.validate()) == nil {
            return Paired(credential: paired.credential, server: server.server, name: "Tab")
        }
        return paired
    }

    /// The same answer for every failure, and the same work whether or not
    /// the device exists.
    public func authenticate(_ credential: DeviceCredential) throws -> DeviceId {
        let now = clock()
        lock.lock()
        let usable = store.settings.enabled && unreadable == nil
        let index = store.devices.firstIndex { $0.id == credential.device }
        let device = index.map { store.devices[$0] }
            ?? StoredDevice(id: credential.device, name: "", salt: Data(count: 16), tokenHash: Data(count: 32),
                            pairedAt: 0)
        let matched = device.matches(credential.token)
        guard usable, matched, let index else {
            lock.unlock()
            throw ServiceError(.unauthorized, "This device is not paired with the server")
        }
        var stored = store
        stored.devices[index].lastSeen = now
        do {
            try save(stored)
            store = stored
        } catch {
            Log.mobile.warning("last seen time not saved: \(String(describing: error), privacy: .public)")
        }
        lock.unlock()
        changed()
        return credential.device
    }

    public func revoke(_ device: DeviceId) throws {
        lock.lock()
        var stored = store
        stored.devices.removeAll { $0.id == device }
        guard stored.devices.count != store.devices.count else {
            lock.unlock()
            return
        }
        do {
            try save(stored)
        } catch {
            lock.unlock()
            throw error
        }
        store = stored
        let closing = streams.values.filter { $0.device == device }
        lock.unlock()
        closing.forEach { $0.close() }
        Log.mobile.info("revoked device \(device.description, privacy: .public)")
        changed()
    }

    public func start(acceptor: ConnectionAcceptor) {
        configuring.lock()
        defer { configuring.unlock() }
        lock.lock()
        self.acceptor = acceptor
        lock.unlock()
        applyListener()
    }

    public func stop() {
        configuring.lock()
        defer { configuring.unlock() }
        lock.lock()
        acceptor = nil
        lock.unlock()
        applyListener()
    }

    // MARK: - Listener

    /// The port the listener is bound to, once listening.
    var listeningPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return listener?.port?.rawValue
    }

    /// Replaces any running listener to match the settings; turning access
    /// off also ends every network connection. Call with `configuring` held.
    private func applyListener() {
        lock.lock()
        let old = listener
        listener = nil
        let wanted: (UInt16, StoredIdentity)? = store.settings.enabled && unreadable == nil && acceptor != nil
            ? store.identity.map { (store.settings.port, $0) } : nil
        let closing = wanted == nil ? Array(streams.values) : []
        lock.unlock()
        old?.cancel()
        closing.forEach { $0.close() }

        let status: ListenerStatus
        if let (port, identity) = wanted {
            status = startListener(port: port, identity: identity)
        } else {
            lock.lock()
            let enabled = store.settings.enabled && unreadable == nil
            let failure = unreadable
            lock.unlock()
            if let failure {
                status = .failed(failure)
            } else {
                status = enabled ? .failed("The network listener isn't running") : .disabled
            }
        }
        lock.lock()
        self.status = status
        lock.unlock()
        changed()
    }

    private func startListener(port: UInt16, identity: StoredIdentity) -> ListenerStatus {
        let parameters: NWParameters
        do {
            let secIdentity = try ServerCertificate.secIdentity(identity)
            guard let secured = sec_identity_create(secIdentity) else {
                return .failed("Couldn't load the server's TLS identity")
            }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secured)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } catch {
            return .failed(String(describing: error))
        }
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return .failed("Invalid port \(port)") }
        let created: NWListener
        do {
            if let bindAddress {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: endpointPort)
                created = try NWListener(using: parameters)
            } else {
                created = try NWListener(using: parameters, on: endpointPort)
            }
        } catch {
            Log.mobile.error("mobile access cannot listen on port \(port): \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
        let ready = DispatchSemaphore(value: 0)
        let outcome = MobileBox<ListenerStatus?>(nil)
        let reported = MobileOnce()
        created.stateUpdateHandler = { [weak self, weak created] state in
            var result: ListenerStatus?
            switch state {
            case .ready: result = .listening
            case .failed(let error), .waiting(let error): result = .failed(String(describing: error))
            default: break
            }
            guard let result else { return }
            if reported.set() {
                outcome.value = result
                ready.signal()
                return
            }
            // A listener that fails later reports it in the state.
            guard case .failed = result, let self, let created else { return }
            self.lock.lock()
            let current = self.listener === created
            if current { self.status = result }
            self.lock.unlock()
            if current { self.changed() }
        }
        created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        created.start(queue: DispatchQueue(label: "tab.mobile.listener"))
        guard ready.wait(timeout: .now() + 5) == .success, let result = outcome.value else {
            created.cancel()
            return .failed("The listener didn't start on port \(port)")
        }
        guard result == .listening else {
            created.cancel()
            Log.mobile.error("mobile access cannot listen on port \(port)")
            return result
        }
        lock.lock()
        listener = created
        lock.unlock()
        Log.mobile.info("mobile access listening on port \(port)")
        return .listening
    }

    // MARK: - Admission

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard unauthenticated < Self.maxUnauthenticated, acceptor != nil else {
            lock.unlock()
            connection.cancel()
            return
        }
        unauthenticated += 1
        let stream = MobileStream(connection: connection, queue: DispatchQueue(label: "tab.mobile.connection"))
        let key = ObjectIdentifier(stream)
        streams[key] = stream
        lock.unlock()
        stream.onClose { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.streams[key] = nil
            self.lock.unlock()
            if stream.device != nil { self.changed() }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.admit(stream)
        }
    }

    private func admit(_ stream: MobileStream) {
        let released = MobileOnce()
        let release = { [weak self] in
            guard released.set(), let self else { return }
            self.lock.lock()
            self.unauthenticated -= 1
            self.lock.unlock()
        }
        defer { release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.admissionTimeout) { [weak stream] in
            guard let stream, stream.device == nil else { return }
            stream.close()
        }
        guard stream.start(timeout: Self.admissionTimeout) else { return }
        var reader = AdmissionReader(stream: stream, limit: Self.unauthenticatedFrameLimit)
        do {
            guard case .request(let helloId, .hello(let hello))? = try reader.next() else {
                try? reader.send(.event(.fatal(ErrorReply(code: .badRequest, message: "expected hello"))))
                stream.close()
                return
            }
            guard let version = hello.versions.filter(ProtocolVersion.supported.contains).max() else {
                try reader.send(.reply(helloId, .versionUnsupported(supported: ProtocolVersion.supported)))
                stream.close()
                return
            }
            try reader.send(.reply(helloId, .hello(HelloReply(version: version, server: server))))
            guard case .request(let id, let body)? = try reader.next() else {
                try? reader.send(.event(.fatal(ErrorReply(code: .badRequest, message: "authentication required"))))
                stream.close()
                return
            }
            let device: DeviceId
            let reply: ReplyBody
            switch body {
            case .authenticate(let credential):
                device = try authenticate(credential)
                reply = .authenticated
            case .pair(let request):
                let paired = try pair(request)
                device = paired.credential.device
                reply = .paired(paired)
            default:
                throw ServiceError(.unauthorized, "This device is not paired with the server")
            }
            stream.admitted(device: device, hello: hello, leftover: reader.leftover)
            // A revoke that ran before `admitted` is caught here; one after it
            // finds this stream by its device and closes it.
            guard authorized(device) else {
                throw ServiceError(.unauthorized, "This device is not paired with the server")
            }
            try reader.send(.reply(id, reply))
            release()
            lock.lock()
            let acceptor = self.acceptor
            lock.unlock()
            guard let acceptor, !stream.isClosed else {
                stream.close()
                return
            }
            Log.mobile.info("device connected: \(device.description, privacy: .public)")
            changed()
            acceptor.accept(stream: stream, origin: .mobile(device))
        } catch {
            if let id = reader.lastRequest {
                let message = (error as? ServiceError)?.message ?? "This device is not paired with the server"
                try? reader.send(.reply(id, .error(ErrorReply(code: .unauthorized, message: message))))
            }
            stream.close()
        }
    }

    private func authorized(_ device: DeviceId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return store.settings.enabled && unreadable == nil && store.devices.contains { $0.id == device }
    }

    // MARK: - Helpers

    private func save(_ stored: RemoteStore) throws {
        do {
            try RemoteStoreFile.save(stored, to: file)
        } catch {
            throw ServiceError(.persistenceFailed, "Couldn't save mobile access: \(error)")
        }
    }

    private func changed() {
        lock.lock()
        revision += 1
        let revision = self.revision
        lock.unlock()
        events?.broadcast(.changed(topic: .remoteAccess, revision: revision))
    }
}

/// Reads the control messages a phone sends before it is trusted, keeping
/// the bytes of any later frames for the core.
struct AdmissionReader {
    let stream: MobileStream
    let limit: Int
    private var buffer: [UInt8] = []
    private(set) var lastRequest: RequestId?

    init(stream: MobileStream, limit: Int) {
        self.stream = stream
        self.limit = limit
    }

    var leftover: Data { Data(buffer) }

    /// The next control message, or `nil` when the phone closed.
    mutating func next() throws -> Message? {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if buffer.count >= Frame.headerSize {
                let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
                guard length <= limit else { throw ServiceError(.badRequest, "frame too large") }
                if buffer.count >= Frame.headerSize + length {
                    let channel = UInt32(buffer[5]) << 24 | UInt32(buffer[6]) << 16 | UInt32(buffer[7]) << 8
                        | UInt32(buffer[8])
                    let frame = Frame(kind: FrameKind(rawValue: buffer[4]), channel: ChannelId(channel),
                                      payload: Data(buffer[Frame.headerSize ..< Frame.headerSize + length]))
                    buffer.removeFirst(Frame.headerSize + length)
                    guard case .message(let message) = try frame.decoded() else {
                        throw ServiceError(.badRequest, "expected a control message")
                    }
                    if case .request(let id, _) = message { lastRequest = id }
                    return message
                }
            }
            let count = try chunk.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { return nil }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
    }

    func send(_ message: Message) throws {
        try stream.write(try FrameEncoder.encode(message))
    }
}
