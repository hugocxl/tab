import CryptoKit
import Foundation
import TabProtocol

/// A paired phone as `remote.json` keeps it: the token itself is never stored,
/// only a salted SHA-256 of it.
struct StoredDevice: Hashable, Sendable {
    var id: DeviceId
    var name: String
    var salt: Data
    var tokenHash: Data
    var pairedAt: UInt64
    var lastSeen: UInt64?

    func matches(_ token: Data) -> Bool {
        constantTimeEqual(StoredDevice.hash(token, salt: salt), tokenHash)
    }

    static func hash(_ token: Data, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: token)
        return Data(hasher.finalize())
    }
}

/// The server's TLS certificate (DER) and its P-256 private key (X9.63).
struct StoredIdentity: Hashable, Sendable {
    var certificate: Data
    var privateKey: Data

    /// SHA-256 of the certificate, which phones pin.
    var fingerprint: Data { Data(SHA256.hash(data: certificate)) }
}

/// Everything in `remote.json`.
struct RemoteStore: Hashable, Sendable {
    var settings = RemoteAccessSettings()
    var identity: StoredIdentity?
    var devices: [StoredDevice] = []
}

enum RemoteStoreError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let path): "\(path) has invalid contents"
        }
    }
}

/// Reads and writes `remote.json` atomically with owner-only permissions.
/// Unknown keys are ignored and missing optional keys take defaults, so the
/// file only grows across builds.
enum RemoteStoreFile {
    private struct Document: Codable {
        var enabled: Bool
        var port: UInt16
        var certificate: String?
        var privateKey: String?
        var devices: [DocumentDevice]

        init(enabled: Bool, port: UInt16, certificate: String?, privateKey: String?, devices: [DocumentDevice]) {
            self.enabled = enabled
            self.port = port
            self.certificate = certificate
            self.privateKey = privateKey
            self.devices = devices
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? Limits.defaultRemotePort
            certificate = try c.decodeIfPresent(String.self, forKey: .certificate)
            privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey)
            devices = try c.decodeIfPresent([DocumentDevice].self, forKey: .devices) ?? []
        }
    }

    private struct DocumentDevice: Codable {
        var id: DeviceId
        var name: String
        var tokenSalt: String
        var tokenSHA256: String
        var pairedAt: UInt64
        var lastSeen: UInt64?
    }

    static func load(_ url: URL) throws -> RemoteStore {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return RemoteStore()
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard let store = store(from: document) else { throw RemoteStoreError.invalid(url.path) }
        return store
    }

    private static func store(from document: Document) -> RemoteStore? {
        let settings = RemoteAccessSettings(enabled: document.enabled, port: document.port)
        guard (try? settings.validate()) != nil else { return nil }
        var identity: StoredIdentity?
        switch (document.certificate, document.privateKey) {
        case (let certificate?, let key?):
            guard let certificate = Data(hex: certificate), let key = Data(hex: key) else { return nil }
            identity = StoredIdentity(certificate: certificate, privateKey: key)
        case (nil, nil):
            identity = nil
        default:
            return nil
        }
        if document.devices.count > Limits.maxDevices || (settings.enabled && identity == nil) { return nil }
        var devices: [StoredDevice] = []
        for device in document.devices {
            guard (try? Validation.deviceName(device.name)) != nil,
                  let salt = Data(hex: device.tokenSalt),
                  let hash = Data(hex: device.tokenSHA256), hash.count == 32 else { return nil }
            devices.append(StoredDevice(id: device.id, name: device.name, salt: salt, tokenHash: hash,
                                        pairedAt: device.pairedAt, lastSeen: device.lastSeen))
        }
        return RemoteStore(settings: settings, identity: identity, devices: devices)
    }

    static func save(_ store: RemoteStore, to url: URL) throws {
        let document = Document(
            enabled: store.settings.enabled,
            port: store.settings.port,
            certificate: store.identity?.certificate.hexString,
            privateKey: store.identity?.privateKey.hexString,
            devices: store.devices.map {
                DocumentDevice(id: $0.id, name: $0.name, tokenSalt: $0.salt.hexString,
                               tokenSHA256: $0.tokenHash.hexString, pairedAt: $0.pairedAt, lastSeen: $0.lastSeen)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(try encoder.encode(document), to: url)
    }

    /// Writes beside `url` and renames over it, so a crash leaves the old or
    /// the new file, never a mix.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                remaining -= written
                pointer += written
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, rename(temporary.path, url.path) != 0 { failure = errno }
        guard failure == 0 else {
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        let folder = open(directory.path, O_RDONLY | O_CLOEXEC)
        if folder >= 0 {
            fsync(folder)
            close(folder)
        }
    }
}

/// Compares secrets in time independent of where they differ.
func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for (a, b) in zip(left, right) { difference |= a ^ b }
    return difference == 0
}

/// Cryptographically random bytes.
func secureRandom(_ count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw ServiceError(.badRequest, "No randomness available")
    }
    return Data(bytes)
}
