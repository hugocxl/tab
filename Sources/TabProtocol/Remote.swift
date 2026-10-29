import Foundation

/// Network access for paired phones.
public struct RemoteAccessSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var port: UInt16

    public init(enabled: Bool = false, port: UInt16 = Limits.defaultRemotePort) {
        self.enabled = enabled
        self.port = port
    }
}

public enum ListenerStatus: Hashable, Codable, Sendable {
    case disabled
    case listening
    case failed(String)
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "disabled": self = .disabled
        case "listening": self = .listening
        case "failed": self = .failed(try c("message"))
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .disabled: try TaggedEncoding(encoder, "disabled")
        case .listening: try TaggedEncoding(encoder, "listening")
        case .failed(let message):
            var c = try TaggedEncoding(encoder, "failed")
            try c(message, "message")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

public struct PairedDevice: Hashable, Codable, Sendable {
    public var id: DeviceId
    public var name: String
    /// Unix seconds.
    public var pairedAt: UInt64
    /// Unix seconds of the latest successful authentication.
    public var lastSeen: UInt64?
    public var connected: Bool

    public init(id: DeviceId, name: String, pairedAt: UInt64, lastSeen: UInt64? = nil, connected: Bool = false) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.connected = connected
    }
}

public struct RemoteAccessState: Hashable, Codable, Sendable {
    public var revision: UInt64
    public var settings: RemoteAccessSettings
    public var status: ListenerStatus
    /// Unix seconds at which the pending pairing offer expires.
    public var pairingExpiresAt: UInt64?
    public var devices: [PairedDevice]

    public init(revision: UInt64, settings: RemoteAccessSettings, status: ListenerStatus,
                pairingExpiresAt: UInt64? = nil, devices: [PairedDevice] = []) {
        self.revision = revision
        self.settings = settings
        self.status = status
        self.pairingExpiresAt = pairingExpiresAt
        self.devices = devices
    }
}

/// Everything a phone needs to reach and pin a server, carried by the
/// pairing link and its QR code.
public struct PairingInvite: Hashable, Codable, Sendable {
    /// DNS names or IPv4 addresses, without ports.
    public var hosts: [String]
    public var port: UInt16
    /// SHA-256 of the server's TLS certificate, 32 bytes.
    public var fingerprint: Data
    /// The one-time pairing code, 16 bytes.
    public var code: Data

    public static let linkPrefix = "tab://pair?"
    static let linkVersion = "1"
    static let maxLink = 4096

    public init(hosts: [String], port: UInt16, fingerprint: Data, code: Data) {
        self.hosts = hosts
        self.port = port
        self.fingerprint = fingerprint
        self.code = code
    }

    public var link: String {
        var link = "\(Self.linkPrefix)v=\(Self.linkVersion)"
        for host in hosts { link += "&h=\(host)" }
        link += "&p=\(port)&f=\(fingerprint.hexString)&s=\(code.hexString)"
        return link
    }

    public init(link: String) throws(ErrorCode) {
        guard link.utf8.count <= Self.maxLink, link.hasPrefix(Self.linkPrefix) else { throw .badRequest }
        var version: String?
        var hosts: [String] = []
        var port: UInt16?
        var fingerprint: Data?
        var code: Data?
        for field in link.dropFirst(Self.linkPrefix.count).split(separator: "&", omittingEmptySubsequences: false) {
            guard let equals = field.firstIndex(of: "=") else { throw .badRequest }
            let key = field[..<equals]
            let value = String(field[field.index(after: equals)...])
            switch key {
            case "v":
                guard version == nil else { throw .badRequest }
                version = value
            case "h":
                hosts.append(value)
            case "p":
                guard port == nil, !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let parsed = UInt16(value) else { throw .badRequest }
                port = parsed
            case "f":
                guard fingerprint == nil, let bytes = Data(hex: value), bytes.count == 32 else { throw .badRequest }
                fingerprint = bytes
            case "s":
                guard code == nil, let bytes = Data(hex: value), bytes.count == 16 else { throw .badRequest }
                code = bytes
            default:
                throw .badRequest
            }
        }
        guard version == Self.linkVersion, let port, let fingerprint, let code else { throw .badRequest }
        self.init(hosts: hosts, port: port, fingerprint: fingerprint, code: code)
        try validate()
    }
}

public struct PairingOffer: Hashable, Codable, Sendable {
    public var invite: PairingInvite
    /// Unix seconds.
    public var expiresAt: UInt64

    public init(invite: PairingInvite, expiresAt: UInt64) {
        self.invite = invite
        self.expiresAt = expiresAt
    }

    public var hosts: [String] { invite.hosts }
    public var port: UInt16 { invite.port }
    public var code: Data { invite.code }
    public var fingerprint: Data { invite.fingerprint }
}

/// A phone answering a pairing offer.
public struct PairRequest: Hashable, Codable, Sendable {
    public var code: Data
    /// The device's name, shown in Settings.
    public var name: String

    public init(code: Data, name: String) {
        self.code = code
        self.name = name
    }
}

/// What a paired phone presents on every connection.
public struct DeviceCredential: Hashable, Codable, Sendable {
    public var device: DeviceId
    /// 32 bytes; the server keeps only its hash.
    public var token: Data

    public init(device: DeviceId, token: Data) {
        self.device = device
        self.token = token
    }
}

public struct Paired: Hashable, Codable, Sendable {
    public var credential: DeviceCredential
    public var server: ServerId
    /// The server's name, such as the Mac's name.
    public var name: String

    public init(credential: DeviceCredential, server: ServerId, name: String) {
        self.credential = credential
        self.server = server
        self.name = name
    }
}

extension Data {
    /// Lowercase hexadecimal.
    public var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(count * 2)
        for byte in self {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// Parses hexadecimal in either case; `nil` for anything else.
    public init?(hex: String) {
        let utf8 = Array(hex.utf8)
        guard utf8.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8.count / 2)
        func nibble(_ digit: UInt8) -> UInt8? {
            switch digit {
            case 48 ... 57: digit - 48
            case 65 ... 70: digit - 55
            case 97 ... 102: digit - 87
            default: nil
            }
        }
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }
}
