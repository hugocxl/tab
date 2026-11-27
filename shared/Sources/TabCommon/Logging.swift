import os

/// Loggers per subsystem area. Libraries log through these instead of `print`.
/// The Mac app's TabCore adds its own areas in an extension.
public enum Log {
    #if os(iOS)
    public static let subsystem = "com.hugocorta.tabios"
    #else
    public static let subsystem = "com.hugocorta.tab"
    #endif

    public static let client = Logger(subsystem: subsystem, category: "client")

    /// A logger for another area of the app.
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
