import os

// `Log`, with `subsystem`, `client` and `logger(_:)`, comes from TabCommon,
// which the iOS app shares. These are the Mac app's own areas.
extension Log {
    public static let core = logger("core")
    public static let settings = logger("settings")
    public static let state = logger("state")
    public static let server = logger("server")
    public static let session = logger("session")
    public static let wire = logger("protocol")
    public static let terminal = logger("terminal")
    public static let git = logger("git")
    public static let app = logger("app")
    public static let browser = logger("browser")
    public static let simulators = logger("simulators")
    public static let cli = logger("cli")
    public static let mobile = logger("mobile")
    public static let updates = logger("updates")
}
