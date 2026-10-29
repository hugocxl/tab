import CryptoKit
import Darwin
import Network
import TabProtocol
import XCTest
@testable import TabServer

final class RemoteAccessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL { folder.appendingPathComponent("remote.json") }
    private let server = ServerInfo(build: BuildInfo(version: "test"), instance: 1, server: ServerId())

    private func makeRemote(events: ServiceEvents? = nil) -> RemoteAccess {
        RemoteAccess(file: file, server: server, events: events, bindAddress: "127.0.0.1")
    }

    /// Enabled and listening on a free loopback port.
    private func listening(_ acceptor: RecordingAcceptor) throws -> (RemoteAccess, UInt16) {
        let remote = makeRemote()
        remote.start(acceptor: acceptor)
        let port = try freePort()
        try remote.write(RemoteAccessSettings(enabled: true, port: port))
        XCTAssertEqual(remote.state().status, .listening)
        XCTAssertEqual(remote.listeningPort, port)
        return (remote, port)
    }

    // MARK: - Over TLS

    func testPairingAndAuthenticationOverTLS() throws {
        let acceptor = RecordingAcceptor()
        let (remote, port) = try listening(acceptor)
        let offer = try remote.startPairing(hosts: ["127.0.0.1"])
        XCTAssertEqual(offer.hosts.first, "127.0.0.1")
        XCTAssertEqual(offer.code.count, 16)

        let phone = try Phone(port: port, fingerprint: offer.fingerprint)
        try phone.hello()
        guard case .paired(let paired) = try phone.request(.pair(PairRequest(code: offer.code, name: " Phone "))) else {
            return XCTFail("expected paired")
        }
        XCTAssertEqual(paired.server, server.server)
        XCTAssertEqual(paired.credential.token.count, 32)

        // The core receives the stream positioned after admission.
        let accepted = try XCTUnwrap(acceptor.next())
        XCTAssertEqual(accepted.origin, .mobile(paired.credential.device))
        XCTAssertEqual((accepted.stream as? MobileStream)?.hello?.client, .mobile)
        try phone.send(.request(RequestId(7), .ping))
        guard case .request(let id, .ping)? = try Phone.receive(from: accepted.stream) else {
            return XCTFail("expected the ping to reach the core")
        }
        XCTAssertEqual(id, RequestId(7))

        let state = remote.state()
        XCTAssertNil(state.pairingExpiresAt)
        XCTAssertEqual(state.devices.map(\.name), ["Phone"])
        XCTAssertEqual(state.devices.first?.connected, true)

        // The code was used up.
        let again = try Phone(port: port, fingerprint: offer.fingerprint)
        try again.hello()
        guard case .error(let refused) = try again.request(.pair(PairRequest(code: offer.code, name: "Other"))) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(refused.code, .unauthorized)
        XCTAssertTrue(again.isClosedByServer())

        // A later connection authenticates with the token.
        let returning = try Phone(port: port, fingerprint: offer.fingerprint)
        try returning.hello()
        XCTAssertEqual(try returning.request(.authenticate(paired.credential)), .authenticated)
        XCTAssertEqual(try XCTUnwrap(acceptor.next()).origin, .mobile(paired.credential.device))
        XCTAssertNotNil(remote.state().devices.first?.lastSeen)

        // A wrong token is refused and closed, and never reaches the core.
        let intruder = try Phone(port: port, fingerprint: offer.fingerprint)
        try intruder.hello()
        var forged = paired.credential
        forged.token = Data(repeating: 1, count: 32)
        guard case .error(let error) = try intruder.request(.authenticate(forged)) else {
            return XCTFail("expected unauthorized")
        }
        XCTAssertEqual(error.code, .unauthorized)
        XCTAssertTrue(intruder.isClosedByServer())
        XCTAssertNil(acceptor.next(timeout: 0.3))
    }

    func testRequestsBeforeAuthenticationAreRefused() throws {
        let acceptor = RecordingAcceptor()
        let (remote, port) = try listening(acceptor)
        let offer = try remote.startPairing(hosts: ["127.0.0.1"])
        let phone = try Phone(port: port, fingerprint: offer.fingerprint)
        try phone.hello()
        guard case .error(let error) = try phone.request(.readRemoteAccess) else {
            return XCTFail("expected unauthorized")
        }
        XCTAssertEqual(error.code, .unauthorized)
        XCTAssertTrue(phone.isClosedByServer())
        XCTAssertNil(acceptor.next(timeout: 0.3))
    }

    func testRevokeDisconnectsTheDevice() throws {
        let acceptor = RecordingAcceptor()
        let (remote, port) = try listening(acceptor)
        let offer = try remote.startPairing(hosts: ["127.0.0.1"])
        let phone = try Phone(port: port, fingerprint: offer.fingerprint)
        try phone.hello()
        guard case .paired(let paired) = try phone.request(.pair(PairRequest(code: offer.code, name: "Phone"))) else {
            return XCTFail("expected paired")
        }
        _ = try XCTUnwrap(acceptor.next())

        try remote.revoke(paired.credential.device)
        XCTAssertTrue(phone.isClosedByServer())
        XCTAssertTrue(remote.state().devices.isEmpty)
        XCTAssertThrowsError(try remote.authenticate(paired.credential))

        let returning = try Phone(port: port, fingerprint: offer.fingerprint)
        try returning.hello()
        guard case .error = try returning.request(.authenticate(paired.credential)) else {
            return XCTFail("a revoked device must not authenticate")
        }
    }

    func testDisablingStopsListeningAndDisconnectsEveryone() throws {
        let acceptor = RecordingAcceptor()
        let (remote, port) = try listening(acceptor)
        let offer = try remote.startPairing(hosts: ["127.0.0.1"])
        let phone = try Phone(port: port, fingerprint: offer.fingerprint)
        try phone.hello()
        guard case .paired = try phone.request(.pair(PairRequest(code: offer.code, name: "Phone"))) else {
            return XCTFail("expected paired")
        }
        _ = try XCTUnwrap(acceptor.next())
        let waiting = try Phone(port: port, fingerprint: offer.fingerprint)

        try remote.write(RemoteAccessSettings(enabled: false, port: port))
        XCTAssertTrue(phone.isClosedByServer())
        XCTAssertTrue(waiting.isClosedByServer())
        XCTAssertEqual(remote.state().status, .disabled)
        XCTAssertEqual(remote.state().devices.count, 1, "disabling keeps paired devices")
        XCTAssertThrowsError(try Phone(port: port, fingerprint: offer.fingerprint, timeout: 1))
        XCTAssertThrowsError(try remote.startPairing(hosts: []))
    }

    func testThePhonePinsTheCertificate() throws {
        let (remote, port) = try listening(RecordingAcceptor())
        let offer = try remote.startPairing(hosts: ["127.0.0.1"])
        XCTAssertThrowsError(try Phone(port: port, fingerprint: Data(repeating: 0, count: 32), timeout: 2))
        XCTAssertNoThrow(try Phone(port: port, fingerprint: offer.fingerprint))
    }

    // MARK: - Pairing codes

    func testPairingCodesExpireAndCanBeCancelled() throws {
        let (remote, _) = try listening(RecordingAcceptor())
        let now = MobileBox<UInt64>(1_000_000)
        remote.clock = { now.value }

        let offer = try remote.startPairing(hosts: ["127.0.0.1"])
        XCTAssertEqual(offer.expiresAt, 1_000_000 + 300)
        XCTAssertEqual(remote.state().pairingExpiresAt, offer.expiresAt)
        for _ in 0 ..< 5 {
            XCTAssertThrowsError(try remote.pair(PairRequest(code: Data(repeating: 0, count: 16), name: "Phone")))
        }
        now.value += 301
        XCTAssertNil(remote.state().pairingExpiresAt)
        XCTAssertThrowsError(try remote.pair(PairRequest(code: offer.code, name: "Phone")))

        let second = try remote.startPairing(hosts: ["127.0.0.1"])
        XCTAssertNotEqual(second.code, offer.code)
        let third = try remote.startPairing(hosts: ["127.0.0.1"])
        XCTAssertThrowsError(try remote.pair(PairRequest(code: second.code, name: "Phone")),
                             "only the latest code is valid")
        remote.cancelPairing()
        XCTAssertThrowsError(try remote.pair(PairRequest(code: third.code, name: "Phone")))

        let fourth = try remote.startPairing(hosts: ["127.0.0.1"])
        let paired = try remote.pair(PairRequest(code: fourth.code, name: "Phone"))
        XCTAssertEqual(try remote.authenticate(paired.credential), paired.credential.device)
    }

    func testPairingNeedsAccessOnAndListening() throws {
        let remote = makeRemote()
        XCTAssertThrowsError(try remote.startPairing(hosts: []))
        // Enabled but no acceptor yet: not listening.
        try remote.write(RemoteAccessSettings(enabled: true, port: try freePort()))
        XCTAssertNotEqual(remote.state().status, .listening)
        XCTAssertThrowsError(try remote.startPairing(hosts: []))
        XCTAssertThrowsError(try remote.write(RemoteAccessSettings(enabled: true, port: 80)))
        XCTAssertThrowsError(try remote.startPairing(hosts: ["bad host:22"]))
    }

    // MARK: - remote.json

    func testSavedAccessRoundTripsWithPrivatePermissions() throws {
        let events = RecordingEvents()
        let (remote, port) = try listening(RecordingAcceptor())
        let offer = try remote.startPairing(hosts: ["127.0.0.1"])
        let paired = try remote.pair(PairRequest(code: offer.code, name: "Phone"))
        remote.stop()

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(paired.credential.token.hexString), "the token itself is never stored")

        let reopened = makeRemote(events: events)
        let state = reopened.state()
        XCTAssertEqual(state.settings, RemoteAccessSettings(enabled: true, port: port))
        XCTAssertEqual(state.devices.map(\.id), [paired.credential.device])
        XCTAssertEqual(try reopened.authenticate(paired.credential), paired.credential.device)
        XCTAssertFalse(events.received.isEmpty)
        reopened.start(acceptor: RecordingAcceptor())
        let again = try reopened.startPairing(hosts: ["127.0.0.1"])
        XCTAssertEqual(again.fingerprint, offer.fingerprint, "the certificate survives restarts")
        reopened.stop()
    }

    func testUnknownKeysAreIgnoredAndMissingOnesDefault() throws {
        try Data(#"{"enabled": false, "future": [1, 2]}"#.utf8).write(to: file)
        let remote = makeRemote()
        XCTAssertEqual(remote.state().settings, RemoteAccessSettings(enabled: false, port: 7419))
        XCTAssertEqual(remote.state().status, .disabled)
    }

    func testAnUnreadableFileIsKeptWhileAccessStaysOff() throws {
        try Data("damaged".utf8).write(to: file)
        let remote = makeRemote()
        guard case .failed = remote.state().status else { return XCTFail("expected failed") }
        try remote.write(RemoteAccessSettings(enabled: false, port: 7419))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "damaged")
        try remote.write(RemoteAccessSettings(enabled: true, port: 7419))
        XCTAssertNotNil(try RemoteStoreFile.load(file).identity)
    }

    // MARK: - Hosts and certificate

    func testPairingHostsListGivenAddressesFirstOnce() {
        let hosts = PairingHosts.candidates(given: ["Example.com", "10.0.0.2"],
                                            interfaces: ["100.101.1.2", "10.0.0.2", "192.168.1.4"],
                                            localName: "example.com")
        XCTAssertEqual(hosts, ["Example.com", "10.0.0.2", "192.168.1.4", "100.101.1.2"])
        let many = PairingHosts.candidates(given: (1 ... 12).map { "10.0.0.\($0)" }, interfaces: [], localName: nil)
        XCTAssertEqual(many.count, 8)
        XCTAssertEqual(PairingHosts.localName("mac"), "mac.local")
        XCTAssertNil(PairingHosts.localName("my mac"))
        XCTAssertEqual(PairingHosts.displayName("studio.local"), "studio")
    }

    func testGeneratedCertificateParsesWithItsKey() throws {
        let identity = try ServerCertificate.generate()
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.certificate as CFData))
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let expected = try P256.Signing.PrivateKey(x963Representation: identity.privateKey).publicKey
        XCTAssertEqual(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, expected.x963Representation)
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "Tab")
        _ = try ServerCertificate.secIdentity(identity)
    }
}

// MARK: - Support

private final class RecordingAcceptor: ConnectionAcceptor, @unchecked Sendable {
    struct Accepted {
        var stream: ByteStream
        var origin: ConnectionOrigin
    }

    private let lock = NSLock()
    private var accepted: [Accepted] = []
    private let available = DispatchSemaphore(value: 0)

    func accept(stream: ByteStream, origin: ConnectionOrigin) {
        lock.lock()
        accepted.append(Accepted(stream: stream, origin: origin))
        lock.unlock()
        available.signal()
    }

    func next(timeout: TimeInterval = 5) -> Accepted? {
        guard available.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return accepted.removeFirst()
    }
}

private final class RecordingEvents: ServiceEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EventBody] = []

    var received: [EventBody] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func broadcast(_ event: EventBody) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func send(_ event: EventBody, to client: ClientId) {}
}

/// A phone: a TLS client that pins the server's certificate fingerprint.
private final class Phone {
    let stream: MobileStream
    private var nextId: UInt32 = 1

    init(port: UInt16, fingerprint: Data, timeout: TimeInterval = 5) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let leaf = chain?.first.map { SecCertificateCopyData($0) as Data }
            complete(leaf.map { Data(SHA256.hash(data: $0)) } == fingerprint)
        }, DispatchQueue(label: "phone.verify"))
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: tls))
        stream = MobileStream(connection: connection, queue: DispatchQueue(label: "phone"))
        guard stream.start(timeout: timeout) else { throw TransportError.closed }
    }

    func hello() throws {
        guard case .hello(let reply) = try request(.hello(Hello(client: .mobile, clientId: ClientId()))) else {
            throw TransportError.closed
        }
        XCTAssertEqual(reply.version, .current)
    }

    func send(_ message: Message) throws {
        try stream.write(try FrameEncoder.encode(message))
    }

    func request(_ body: RequestBody) throws -> ReplyBody {
        let id = RequestId(nextId)
        nextId += 1
        try send(.request(id, body))
        guard case .reply(let replyId, let reply)? = try Phone.receive(from: stream), replyId == id else {
            throw TransportError.closed
        }
        return reply
    }

    /// The server ended the connection within a few seconds.
    func isClosedByServer() -> Bool {
        let deadline = Date().addingTimeInterval(5)
        var byte = [UInt8](repeating: 0, count: 1)
        while Date() < deadline {
            do {
                if try byte.withUnsafeMutableBytes({ try stream.read(into: $0) }) == 0 { return true }
            } catch {
                return true
            }
        }
        return false
    }

    static func receive(from stream: ByteStream) throws -> Message? {
        var reader = FrameReader()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let frame = try reader.next() {
                guard case .message(let message) = try frame.decoded() else { return nil }
                return message
            }
            let count = try chunk.withUnsafeMutableBytes { try stream.read(into: $0) }
            if count == 0 { return nil }
            reader.append(Data(chunk[0 ..< count]))
        }
    }
}

/// A loopback port nothing listens on right now.
private func freePort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TransportError.closed }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic -> Int32 in
            guard bind(descriptor, generic, length) == 0 else { return -1 }
            return getsockname(descriptor, generic, &length)
        }
    }
    guard bound == 0 else { throw TransportError.closed }
    return UInt16(bigEndian: address.sin_port)
}
