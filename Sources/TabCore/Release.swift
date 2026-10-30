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
        Bundle.main.infoDictionary.flatMap(version(ofBundle:)) ?? sourceVersion
    }

    /// The Info.plist key with a bundle's full version, such as
    /// `1.2.0-beta.340`; `CFBundleShortVersionString` holds only `X.Y.Z`.
    public static let versionKey = "TabVersion"

    /// A bundle's full version from its Info.plist, read from `versionKey`
    /// and, for bundles from before it, `CFBundleShortVersionString`.
    public static func version(ofBundle info: [String: Any]) -> String? {
        for key in [versionKey, "CFBundleShortVersionString"] {
            if let version = info[key] as? String, !version.isEmpty { return version }
        }
        return nil
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

/// A released version. Stable releases follow their `X.Y.Z` order; betas,
/// `X.Y.Z-beta.N`, follow `N`, the commit count they were built from. A beta
/// is replaced by a newer beta or by the stable release of its `X.Y.Z` or
/// later; stable releases are never replaced by betas.
public enum ReleaseVersion: Equatable, Sendable {
    case beta(major: UInt64, minor: UInt64, patch: UInt64, build: UInt64)
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
        self = .beta(major: numbers[0], minor: numbers[1], patch: numbers[2], build: number)
    }

    public var channel: ReleaseChannel {
        switch self {
        case .beta: return .beta
        case .stable: return .stable
        }
    }

    /// Whether this release replaces `other`.
    public func isNewer(than other: ReleaseVersion) -> Bool {
        switch (self, other) {
        case let (.beta(_, _, _, build), .beta(_, _, _, other)):
            return build > other
        case let (.stable(a, b, c), .stable(x, y, z)):
            return [x, y, z].lexicographicallyPrecedes([a, b, c])
        case let (.stable(a, b, c), .beta(x, y, z, _)):
            return ![a, b, c].lexicographicallyPrecedes([x, y, z])
        case (.beta, .stable):
            return false
        }
    }

    /// Whether `target` is a release that replaces `current`.
    public static func isNewer(_ target: String, than current: String) -> Bool {
        guard let target = ReleaseVersion(target), let current = ReleaseVersion(current) else { return false }
        return target.isNewer(than: current)
    }

    private static func number(_ text: Substring) -> UInt64? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt64(text)
    }
}
