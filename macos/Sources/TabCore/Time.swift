import Foundation

public enum RelativeTime {
    /// Seconds since the Unix epoch, or 0 when the clock is set before it.
    public static func unixNow() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970))
    }

    /// How long ago something happened, given its age in seconds: `just now`,
    /// `5m ago`, `3h ago`, or `2d ago`.
    public static func ago(seconds: UInt64) -> String {
        switch seconds {
        case 0..<60: return "just now"
        case 60..<3_600: return "\(seconds / 60)m ago"
        case 3_600..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// How long ago `date` was, as `ago(seconds:)` says it. Future dates are `just now`.
    public static func ago(since date: Date, now: Date = Date()) -> String {
        ago(seconds: UInt64(max(0, now.timeIntervalSince(date))))
    }
}
