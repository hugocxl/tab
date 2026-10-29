import Foundation

/// Which release a build is, read from its version. Stable releases are
/// `X.Y.Z`, betas `X.Y.Z-beta.N` where `N` orders them; anything else, such as
/// an unstamped `0.1.0-dev`, is a local build.
public enum Release {
    /// The version compiled into a build that has no bundle version, such as
    /// `swift build` products and tests.
    public static let sourceVersion = "0.1.0-dev"

    /// This build's version: the bundle's when it has one.
    public static var version: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty
        {
            return version
        }
        return sourceVersion
    }

    /// Whether this is a debug build, which keeps its data in `Tab Dev`.
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The app's bundle identifier for this kind of build.
    public static var bundleIdentifier: String {
        isDebugBuild ? "com.hugocorta.tab-dev" : "com.hugocorta.tab"
    }

    /// The app's name for this kind of build.
    public static var appName: String { isDebugBuild ? "Tab Dev" : "Tab" }

    /// This build's channel. Local builds update like betas.
    public static var channel: ReleaseChannel {
        ReleaseVersion(version)?.channel ?? .beta
    }
}

/// Where a release is published.
public enum ReleaseChannel: String, Sendable, Codable {
    case beta
    case stable
}

/// A released version, in the order releases of its channel follow.
public enum ReleaseVersion: Equatable, Sendable {
    case beta(build: UInt64)
    case stable(major: UInt64, minor: UInt64, patch: UInt64)

    public init?(_ version: String) {
        let base: Substring
        var build: Substring?
        if let range = version.range(of: "-beta.") {
            base = version[..<range.lowerBound]
            build = version[range.upperBound...]
        } else {
            base = Substring(version)
        }
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap(Self.number)
        guard numbers.count == 3 else { return nil }
        guard let build else {
            self = .stable(major: numbers[0], minor: numbers[1], patch: numbers[2])
            return
        }
        guard !build.hasPrefix("0"), let number = Self.number(build) else { return nil }
        self = .beta(build: number)
    }

    public var channel: ReleaseChannel {
        switch self {
        case .beta: return .beta
        case .stable: return .stable
        }
    }

    /// Whether this release replaces `other`. Releases of different channels
    /// never replace each other.
    public func isNewer(than other: ReleaseVersion) -> Bool {
        switch (self, other) {
        case let (.beta(build), .beta(other)):
            return build > other
        case let (.stable(a, b, c), .stable(x, y, z)):
            return [x, y, z].lexicographicallyPrecedes([a, b, c])
        default:
            return false
        }
    }

    /// Whether `target` is a newer release than `current` on the same channel.
    public static func isNewer(_ target: String, than current: String) -> Bool {
        guard let target = ReleaseVersion(target), let current = ReleaseVersion(current) else { return false }
        return target.isNewer(than: current)
    }

    private static func number(_ text: Substring) -> UInt64? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt64(text)
    }
}
