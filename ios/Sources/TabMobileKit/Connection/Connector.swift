import Foundation
import TabCommon
import TabConnection
import TabProtocol

/// Why pairing or connecting failed, in words for the person holding the phone.
public enum ConnectError: Error, Equatable, LocalizedError {
    /// No host in the pairing answered, or none finished TLS with the pinned certificate.
    case unreachable(String)
    /// The server no longer knows this device: it was revoked, or mobile access was turned off.
    case unauthorized
    /// The pairing code was wrong or expired.
    case pairingRefused
    /// The server and this app share no protocol version.
    case incompatible
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            "Couldn't reach the Mac. Check that it's awake and on the same network or VPN, and that Keep this Mac awake is on in Tab's Mobile settings. (\(detail))"
        case .unauthorized: "This Mac no longer accepts this device. Pair again from Tab's Mobile settings."
        case .pairingRefused: "The pairing code is wrong or expired. Show a new one on the Mac."
        case .incompatible: "This Mac runs a version of Tab this app can't talk to. Update both."
        case .failed(let message): message
        }
    }

    /// Whether trying again later may work without the person's help.
    public var recoverable: Bool {
        switch self {
        case .unreachable, .failed: true
        case .unauthorized, .pairingRefused, .incompatible: false
        }
    }
}

/// Opens authenticated connections to paired servers, and pairs new ones.
public enum Connector {
    /// How long one host gets to finish TCP and TLS.
    static let hostTimeout: TimeInterval = 6

    /// Pairs with the server `invite` names, as `deviceName`.
    public static func pair(_ invite: PairingInvite, deviceName: String, clientId: ClientId)
        async throws -> (server: PairedServer, token: Data, client: ServerClient) {
        let (client, host) = try await open(hosts: invite.hosts, port: invite.port, fingerprint: invite.fingerprint,
                                            clientId: clientId)
        do {
            let name = String(deviceName.prefix(64))
            let reply = try await client.request(.pair(PairRequest(code: invite.code, name: name)))
            guard case .paired(let paired) = reply else {
                throw ConnectError.failed("unexpected reply to pairing: \(String(describing: reply).prefix(80))")
            }
            let server = PairedServer(id: paired.server, name: paired.name, hosts: invite.hosts, port: invite.port,
                                      fingerprint: invite.fingerprint, device: paired.credential.device,
                                      lastHost: host)
            return (server, paired.credential.token, client)
        } catch let error as ClientError {
            client.close()
            throw error.serverCode == .unauthorized ? ConnectError.pairingRefused : ConnectError.failed(error.description)
        }
    }

    /// Connects to `server` and proves this device with `token`.
    public static func connect(_ server: PairedServer, token: Data, clientId: ClientId)
        async throws -> (client: ServerClient, host: String) {
        let (client, host) = try await open(hosts: server.orderedHosts, port: server.port,
                                            fingerprint: server.fingerprint, clientId: clientId)
        do {
            let reply = try await client.request(.authenticate(DeviceCredential(device: server.device, token: token)))
            guard case .authenticated = reply else {
                throw ConnectError.failed("unexpected reply to authenticate: \(String(describing: reply).prefix(80))")
            }
            return (client, host)
        } catch let error as ClientError {
            client.close()
            throw error.serverCode == .unauthorized ? ConnectError.unauthorized : ConnectError.failed(error.description)
        }
    }

    /// Tries every host at once and keeps the first that finishes the
    /// handshake, so a stale address never delays a live one.
    private static func open(hosts: [String], port: UInt16, fingerprint: Data, clientId: ClientId)
        async throws -> (ServerClient, String) {
        guard !hosts.isEmpty else { throw ConnectError.unreachable("no addresses") }
        return try await withThrowingTaskGroup(of: (ServerClient, String)?.self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask {
                    // Give earlier, preferred hosts a head start.
                    if index > 0 { try? await Task.sleep(nanoseconds: UInt64(index) * 150_000_000) }
                    try Task.checkCancellation()
                    let stream = try await TLSStream.open(host: host, port: port, fingerprint: fingerprint,
                                                          timeout: hostTimeout)
                    do {
                        let client = try await ServerClient.connect(
                            stream: stream, kind: .mobile, clientId: clientId,
                            build: BuildInfo(version: Release.version), timeout: hostTimeout)
                        return (client, host)
                    } catch {
                        stream.close()
                        throw error
                    }
                }
            }
            var lastError: Error = ConnectError.unreachable("no answer")
            var winner: (ServerClient, String)?
            while let result = await group.nextResult() {
                switch result {
                case .success(let opened?):
                    if winner == nil {
                        winner = opened
                        group.cancelAll()
                    } else {
                        opened.0.close()
                    }
                case .success(nil):
                    break
                case .failure(let error):
                    lastError = error
                }
            }
            if let winner { return winner }
            if case ClientError.versionUnsupported = lastError { throw ConnectError.incompatible }
            throw ConnectError.unreachable(String(describing: lastError))
        }
    }
}
