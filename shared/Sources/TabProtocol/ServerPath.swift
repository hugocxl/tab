import Foundation

/// A path on the server's computer, which may not be this one. It is never
/// resolved locally; the server checks it again before use.
public struct ServerPath: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// An absolute path, validated by `validateAbsolute()`.
    public init(absolute value: String) throws(ErrorCode) {
        self.rawValue = value
        try validateAbsolute()
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var isAbsolute: Bool { rawValue.hasPrefix("/") }
    public var byteCount: Int { rawValue.utf8.count }
    var containsNul: Bool { rawValue.utf8.contains(0) }

    /// The last non-empty component, or the whole path when it has none.
    public var lastComponent: String {
        rawValue.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? rawValue
    }

    public func appending(_ component: String) -> ServerPath {
        if rawValue.hasSuffix("/") { return ServerPath(rawValue + component) }
        return ServerPath(rawValue + "/" + component)
    }

    /// Not empty. The rule for paths whose shape the server checks itself.
    public func validate() throws(ErrorCode) {
        if rawValue.isEmpty { throw .badPath }
    }

    /// Starts with `/`, has no NUL, and fits `Limits.maxPathBytes`.
    public func validateAbsolute() throws(ErrorCode) {
        if !isAbsolute || byteCount > Limits.maxPathBytes || containsNul { throw .badPath }
    }

    /// Relative to a project folder (empty is the folder itself), without NUL.
    public func validateRelative() throws(ErrorCode) {
        if isAbsolute || byteCount > Limits.maxPathBytes || containsNul { throw .badPath }
    }

    /// One path component: not empty, `.` or `..`, and without `/` or NUL.
    public func validateComponent() throws(ErrorCode) {
        if rawValue.isEmpty || rawValue == "." || rawValue == ".." || rawValue.contains("/") || containsNul {
            throw .badPath
        }
    }
}
