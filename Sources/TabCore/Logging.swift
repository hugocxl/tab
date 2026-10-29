import os

/// Loggers per subsystem area. Libraries log through these instead of `print`.
public enum Log {
    public static let subsystem = "com.hugocorta.tab"

    public static let core = Logger(subsystem: subsystem, category: "core")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let state = Logger(subsystem: subsystem, category: "state")
    public static let server = Logger(subsystem: subsystem, category: "server")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let client = Logger(subsystem: subsystem, category: "client")
    public static let wire = Logger(subsystem: subsystem, category: "protocol")
    public static let terminal = Logger(subsystem: subsystem, category: "terminal")
    public static let git = Logger(subsystem: subsystem, category: "git")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let browser = Logger(subsystem: subsystem, category: "browser")
    public static let cli = Logger(subsystem: subsystem, category: "cli")
    public static let mobile = Logger(subsystem: subsystem, category: "mobile")
    public static let updates = Logger(subsystem: subsystem, category: "updates")

    /// A logger for another area of the app.
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
