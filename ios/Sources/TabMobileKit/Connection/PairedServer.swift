import Foundation
import Security
import TabProtocol
import TabShared

/// A Mac this device paired with: where to find it and how to recognize it.
/// The device's secret token lives in the Keychain, never in this record.
public struct PairedServer: Codable, Hashable, Sendable, Identifiable {
    public var id: ServerId
    /// The Mac's name, as its server reported it when pairing.
    public var name: String
    /// Addresses from the pairing link, tried together on every connection.
    public var hosts: [String]
    public var port: UInt16
    /// SHA-256 of the server's TLS certificate.
    public var fingerprint: Data
    /// This device, as the server knows it.
    public var device: DeviceId
    public var pairedAt: Date
    /// The host that answered last, which usually answers again.
    public var lastHost: String?

    public init(id: ServerId, name: String, hosts: [String], port: UInt16, fingerprint: Data, device: DeviceId,
                pairedAt: Date = Date(), lastHost: String? = nil) {
        self.id = id
        self.name = name
        self.hosts = hosts
        self.port = port
        self.fingerprint = fingerprint
        self.device = device
        self.pairedAt = pairedAt
        self.lastHost = lastHost
    }

    /// Hosts in the order to prefer them: the last one that answered first.
    public var orderedHosts: [String] {
        guard let lastHost, hosts.contains(lastHost) else { return hosts }
        return [lastHost] + hosts.filter { $0 != lastHost }
    }
}

/// The paired servers, kept in `servers.json` beside their Keychain tokens.
public final class PairedServerStore: @unchecked Sendable {
    private let file: URL
    /// Where `servers.json` and the app's other state live.
    public let directory: URL
    private let tokens: TokenVault
    private let lock = NSLock()

    public init(directory: URL = PairedServerStore.defaultDirectory,
                tokens: TokenVault = Keychain(service: "com.hugocorta.tabios.device-token")) {
        self.directory = directory
        file = directory.appendingPathComponent("servers.json")
        self.tokens = tokens
    }

    /// Application Support/Tab, created on first use.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tab", isDirectory: true)
    }

    public func load() -> [PairedServer] {
        lock.withLock {
            guard let data = try? Data(contentsOf: file) else { return [] }
            return (try? JSONDecoder().decode(StoredServers.self, from: data))?.servers ?? []
        }
    }

    /// Adds or replaces `server`, with the token that proves this device.
    public func save(_ server: PairedServer, token: Data) throws {
        try tokens.write(token, account: server.device.description)
        try update { servers in
            servers.removeAll { $0.id == server.id }
            servers.append(server)
        }
    }

    /// Records that `host` answered for `server`.
    public func remember(host: String, for server: ServerId) {
        try? update { servers in
            guard let index = servers.firstIndex(where: { $0.id == server }), servers[index].lastHost != host else {
                return
            }
            servers[index].lastHost = host
        }
    }

    public func remove(_ server: ServerId) {
        try? update { servers in
            for removed in servers where removed.id == server {
                tokens.delete(account: removed.device.description)
            }
            servers.removeAll { $0.id == server }
        }
    }

    public func token(for server: PairedServer) -> Data? {
        tokens.read(account: server.device.description)
    }

    private func update(_ change: (inout [PairedServer]) -> Void) throws {
        try lock.withLock {
            var servers = (try? Data(contentsOf: file))
                .flatMap { try? JSONDecoder().decode(StoredServers.self, from: $0) }?.servers ?? []
            change(&servers)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(StoredServers(servers: servers)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private struct StoredServers: Codable {
        var servers: [PairedServer]
    }
}

/// Where device tokens are kept.
public protocol TokenVault: Sendable {
    func write(_ token: Data, account: String) throws
    func read(account: String) -> Data?
    func delete(account: String)
}

/// Generic-password items readable after the first unlock, on this device only.
public struct Keychain: TokenVault {
    let service: String

    public init(service: String) { self.service = service }

    public func write(_ data: Data, account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ConnectError.failed("Couldn't save the pairing in the Keychain (\(status)).")
        }
    }

    public func read(account: String) -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true,
                                      kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func delete(account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}
