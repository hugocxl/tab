import Foundation
import TabCore
import TabProtocol

/// A release from Codesh's schema-1 `update.json` format, selecting the
/// `macos-aarch64` platform asset. The earlier flat Tab format remains
/// readable for existing pending records and feeds.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    /// The signed app as a `.zip` (or `.dmg`) in the release's own assets.
    public var url: URL
    /// The SHA-256 of the download, lowercase hex. Empty when the macOS
    /// platform feed relies on size and Developer ID signature verification.
    public var sha256: String
    /// The download's size in bytes, when the feed states it.
    public var size: Int64?
    /// The oldest macOS the release runs on, such as `14.0`.
    public var minimumSystemVersion: String?
    /// The verified bundle's protocol versions, filled after preparing it.
    /// Feed hints alone never authorize preserving a running server.
    public var protocolVersions: [ProtocolVersion]

    public init(
        version: String,
        url: URL,
        sha256: String,
        size: Int64? = nil,
        minimumSystemVersion: String? = nil,
        protocolVersions: [ProtocolVersion] = []
    ) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.minimumSystemVersion = minimumSystemVersion
        self.protocolVersions = protocolVersions
    }

    enum CodingKeys: String, CodingKey {
        case version, url, sha256, size, minimumSystemVersion, protocolVersions, protocolVersion, schema, platforms
    }

    private struct Asset: Decodable {
        var url: URL
        var size: Int64
        var sha256: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        if container.contains(.schema) || container.contains(.platforms) {
            guard try container.decode(Int.self, forKey: .schema) == 1 else {
                throw UpdateError.invalidFeed("Unsupported update feed")
            }
            let platforms = try container.decode([String: Asset].self, forKey: .platforms)
            guard let asset = platforms["macos-aarch64"] else {
                throw UpdateError.invalidFeed("No update for this platform")
            }
            url = asset.url
            sha256 = asset.sha256?.lowercased() ?? ""
            size = asset.size
            guard url.absoluteString == "\(UpdateFeed.releases)/v\(version)/Tab-\(version)-arm64.dmg" else {
                throw UpdateError.invalidFeed("Unexpected update download location")
            }
        } else {
            url = try container.decode(URL.self, forKey: .url)
            sha256 = try container.decode(String.self, forKey: .sha256).lowercased()
            size = try container.decodeIfPresent(Int64.self, forKey: .size)
        }
        minimumSystemVersion = try container.decodeIfPresent(String.self, forKey: .minimumSystemVersion)
        if let versions = try container.decodeIfPresent([ProtocolVersion].self, forKey: .protocolVersions) {
            protocolVersions = versions
        } else if let version = try container.decodeIfPresent(ProtocolVersion.self, forKey: .protocolVersion) {
            protocolVersions = [version]
        } else {
            protocolVersions = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(url, forKey: .url)
        try container.encode(sha256, forKey: .sha256)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(minimumSystemVersion, forKey: .minimumSystemVersion)
        try container.encode(protocolVersions, forKey: .protocolVersions)
    }
}

/// Where updates come from and what a feed may contain.
public enum UpdateFeed {
    /// The latest release's feed.
    public static var url: URL { url(channel: Release.channel) }

    static func url(channel: ReleaseChannel) -> URL {
        let path = channel == .beta ? "download/beta" : "latest/download"
        return URL(string: "https://github.com/hugocxl/tab/releases/\(path)/update.json")!
    }
    /// Every download must come from the release's own assets.
    public static let releases = "https://github.com/hugocxl/tab/releases/download"
    /// The largest feed read.
    public static let maximumFeedSize = 65_536
    /// The largest download accepted.
    public static let maximumDownloadSize: Int64 = 2 * 1024 * 1024 * 1024

    /// The release that replaces `current`, or `nil` when the feed's release
    /// isn't newer on this build's channel. Throws when the feed is broken
    /// or points anywhere but the release's own assets.
    public static func parse(
        _ data: Data,
        current: String,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws -> UpdateManifest? {
        guard data.count <= maximumFeedSize else { throw UpdateError.invalidFeed("The update feed is too large") }
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.invalidFeed("The update feed can't be read")
        }
        guard let next = ReleaseVersion(manifest.version) else {
            throw UpdateError.invalidFeed("The update feed names an invalid version")
        }
        guard let installed = ReleaseVersion(current) else {
            throw UpdateError.notARelease
        }
        guard next.isNewer(than: installed) else { return nil }
        try validate(manifest)
        if let minimum = manifest.minimumSystemVersion {
            guard let required = parseSystemVersion(minimum) else {
                throw UpdateError.invalidFeed("The update feed names an invalid macOS version")
            }
            guard isAtLeast(systemVersion, required) else {
                throw UpdateError.systemTooOld(version: manifest.version, minimum: minimum)
            }
        }
        return manifest
    }

    static func validate(_ manifest: UpdateManifest) throws {
        let prefix = "\(releases)/v\(manifest.version)/"
        let path = manifest.url.absoluteString
        let name = String(path.dropFirst(prefix.count))
        guard manifest.url.scheme == "https", path.hasPrefix(prefix), !name.isEmpty,
              !name.contains("/"), !name.contains(".."),
              ["zip", "dmg"].contains(manifest.url.pathExtension.lowercased())
        else {
            throw UpdateError.invalidFeed("Unexpected update download location")
        }
        guard (manifest.sha256.isEmpty && manifest.size != nil)
            || (manifest.sha256.count == 64 && manifest.sha256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
            })) else {
            throw UpdateError.invalidFeed("Invalid update checksum")
        }
        if let size = manifest.size, size <= 0 || size > maximumDownloadSize {
            throw UpdateError.invalidFeed("Invalid update download size")
        }
    }

    static func parseSystemVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part in part.allSatisfy(\.isNumber) ? Int(part) : nil }
        guard numbers.count == parts.count else { return nil }
        return OperatingSystemVersion(
            majorVersion: numbers[0],
            minorVersion: numbers.count > 1 ? numbers[1] : 0,
            patchVersion: numbers.count > 2 ? numbers[2] : 0
        )
    }

    static func isAtLeast(_ system: OperatingSystemVersion, _ required: OperatingSystemVersion) -> Bool {
        [system.majorVersion, system.minorVersion, system.patchVersion]
            .lexicographicallyPrecedes([required.majorVersion, required.minorVersion, required.patchVersion]) == false
    }
}

/// Why checking for, downloading or installing an update failed.
public enum UpdateError: Error, Equatable, Sendable, CustomStringConvertible {
    case notARelease
    case unavailable(String)
    case invalidFeed(String)
    case systemTooOld(version: String, minimum: String)
    case download(String)
    case checksumMismatch
    case sizeMismatch
    case invalidBundle(String)
    case install(String)

    public var description: String {
        switch self {
        case .notARelease:
            return "Automatic updates are available in installed releases of \(Release.appName)."
        case .unavailable(let reason), .invalidFeed(let reason), .invalidBundle(let reason), .install(let reason):
            return reason
        case let .systemTooOld(version, minimum):
            return "\(Release.appName) \(version) needs macOS \(minimum) or later."
        case .download(let reason):
            return "Could not download the update: \(reason)"
        case .checksumMismatch:
            return "The update download doesn't match its checksum."
        case .sizeMismatch:
            return "The update download is incomplete or has an unexpected size."
        }
    }
}

extension UpdateError: LocalizedError {
    public var errorDescription: String? { description }
}
