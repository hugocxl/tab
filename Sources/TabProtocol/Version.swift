import Foundation

/// The protocol's version. It changes only for a breaking change; additive
/// fields and cases keep it.
public struct ProtocolVersion: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ value: UInt16) { self.rawValue = value }
    public var description: String { String(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let v1 = ProtocolVersion(1)
    /// The version this build speaks.
    public static let current = v1
    /// Every version this build speaks.
    public static let supported: [ProtocolVersion] = [current]

    /// The newest version both sides speak, if any.
    public static func negotiate(_ peer: [ProtocolVersion]) -> ProtocolVersion? {
        supported.filter(peer.contains).max()
    }
}

/// Something a server can do that a client checks before offering it. Add
/// one only when a client must change its UI for servers without it; names
/// are permanent.
public struct Feature: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Server-side key encoding, paste framing, focus reports and screen clearing.
    public static let terminalInput = Feature(rawValue: "terminalInput")
    /// New sessions start with the environment their request names.
    public static let sessionEnvironment = Feature(rawValue: "sessionEnvironment")
    /// File list and content search on the server.
    public static let fileSearch = Feature(rawValue: "fileSearch")

    /// Features this build's server supports.
    public static let all: [Feature] = [.terminalInput, .sessionEnvironment, .fileSearch]
}

/// What kind of program a client is.
public enum ClientKind: OpenEnum {
    case desktop
    case cli
    case mobile
    case unknown(String)

    public static let knownCases: [ClientKind] = [.desktop, .cli, .mobile]

    public var rawValue: String {
        switch self {
        case .desktop: "desktop"
        case .cli: "cli"
        case .mobile: "mobile"
        case .unknown(let value): value
        }
    }

    /// A label for people, such as in a session's owner.
    public var displayName: String {
        switch self {
        case .desktop: "Desktop"
        case .cli: "CLI"
        case .mobile: "Mobile"
        case .unknown: "Other"
        }
    }
}

/// Size limits shared by both sides. Validation rejects anything larger.
public enum Limits {
    /// The largest frame payload, unless a connection sets a smaller one.
    public static let maxFrame = 16 * 1024 * 1024
    public static let maxCols: UInt16 = 4096
    public static let maxRows: UInt16 = 1024
    public static let maxLinkSpans = 1024
    public static let maxLinkURI = 2048
    /// The most an OSC 52 clipboard write carries.
    public static let maxClipboardText = 1024 * 1024
    /// The most one input write carries.
    public static let maxInput = 1024 * 1024
    public static let maxPathBytes = 4096
    public static let maxGraphicsBytes = 8 * 1024 * 1024
    public static let maxGraphicsPlacements = 1024
    public static let catalogPageSize = 128
    public static let maxProjects = 4096
    public static let maxHistoryPage = 500
    public static let maxAttachHistory = 200
    public static let maxSearchQuery = 256
    public static let maxSearchScannedRows: UInt64 = 2000
    public static let maxSessionReferences = 16_384
    public static let activityHistoryLimit = 200
    public static let maxFileBytes = 5 * 1024 * 1024
    public static let maxFileEntries = 16_384
    public static let maxFilePathBytes = 2 * 1024 * 1024
    public static let maxFileChanges = 256
    public static let maxFileSearchResults = 100_000
    /// Content search matches kept per file.
    public static let maxMatchesPerFile = 200
    public static let maxExecOutput = 4 * 1024 * 1024
    public static let maxExecTimeoutMs: UInt32 = 300_000
    public static let maxUploadChunk = 1024 * 1024
    public static let maxUploadBytes: UInt64 = 100 * 1024 * 1024
    public static let maxUploadName = 1024
    public static let maxEnvironmentVariables = 128
    public static let maxEnvironmentBytes = 64 * 1024
    public static let maxDevices = 64
    public static let maxDeviceName = 64
    public static let maxPairingHosts = 8
    public static let defaultRemotePort: UInt16 = 7419
    public static let maxHistoryBudgetBytes: UInt64 = 64 * 1024 * 1024 * 1024
}

/// Update metadata, stable across protocol versions.
public struct BuildInfo: Hashable, Codable, Sendable {
    /// Frozen metadata for updaters predating protocol negotiation.
    public static let compatibility: UInt64 = 21
    /// The app version, e.g. `1.4.0`.
    public var version: String
    /// Protocol versions this build speaks.
    public var protocolVersions: [ProtocolVersion]

    public init(version: String, protocolVersions: [ProtocolVersion] = ProtocolVersion.supported) {
        self.version = version
        self.protocolVersions = protocolVersions
    }

    private enum CodingKeys: String, CodingKey {
        case version, compatibility, `protocol`, protocolVersions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        protocolVersions = try container.decodeIfPresent([ProtocolVersion].self, forKey: .protocol)
            ?? container.decodeIfPresent([ProtocolVersion].self, forKey: .protocolVersions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(Self.compatibility, forKey: .compatibility)
        try container.encode(protocolVersions, forKey: .protocol)
    }

    /// Whether this build and `other` share a protocol version, so they can talk.
    public func sharesProtocol(with other: BuildInfo) -> Bool {
        protocolVersions.contains(where: other.protocolVersions.contains)
    }
}

/// Identifies the running server process, rather than the binary installed on disk.
public struct ServerInfo: Hashable, Codable, Sendable {
    public var build: BuildInfo
    /// Differs for every start of the server.
    public var instance: UInt64
    public var server: ServerId

    public init(build: BuildInfo, instance: UInt64, server: ServerId) {
        self.build = build
        self.instance = instance
        self.server = server
    }
}
