import Foundation

/// Where Tab keeps its files. Everything lives in one profile folder:
/// `~/Library/Application Support/Tab` for release builds, `Tab Dev` for debug
/// builds, or `TAB_DIR` when set.
public struct TabDirs: Sendable, Equatable {
    /// The profile folder.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The profile folder for this build and environment, created owner-only
    /// when missing.
    public static func profile(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> TabDirs {
        let root = try resolveRoot(
            override: environment["TAB_DIR"],
            home: environment["HOME"] ?? NSHomeDirectory(),
            name: folderName(debug: Release.isDebugBuild)
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return TabDirs(root: root)
    }

    /// Release and debug builds keep their data apart.
    public static func folderName(debug: Bool) -> String {
        debug ? "Tab Dev" : "Tab"
    }

    static func resolveRoot(override: String?, home: String?, name: String) throws -> URL {
        if let override {
            guard !override.isEmpty else { throw DirsError.emptyOverride }
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let home, !home.isEmpty else { throw DirsError.noHome }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Server settings: shell, history budget, shell integration.
    public var serverSettings: URL { file("server.json") }
    public var serverLog: URL { file("server.log") }
    public var serverSocket: URL { file("server.sock") }
    /// The server's single-instance lock, holding its pid.
    public var serverPid: URL { file("server.pid") }
    /// Projects, sessions, saved screens and history.
    public var sessions: URL { folder("sessions") }
    /// Mobile access settings and paired phones.
    public var remoteAccess: URL { file("remote.json") }
    /// App preferences, keymap, commands, remote servers.
    public var settings: URL { file("settings.json") }
    /// Terminal preferences and key bindings.
    public var terminalSettings: URL { file("terminal.json") }
    /// Custom themes in Ghostty's theme format.
    public var themes: URL { folder("themes") }
    /// Projects, layouts, workspaces and window state.
    public var state: URL { file("state.json") }
    /// Proxy settings, excluded from backups.
    public var proxy: URL { file("proxy.json") }
    /// Recovery copies made by restore.
    public var backups: URL { folder("Backups") }
    /// The app's socket for `tab browser` and `tab <folder>`.
    public var appSocket: URL { file("app.sock") }

    private func file(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: false)
    }

    private func folder(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// Where new worktrees go by default, before the project's folder name:
    /// `~/.tab/worktrees/<project>/<name>`.
    public static let defaultWorktreeFolder = "~/.tab/worktrees"

    /// `$XDG_CONFIG_HOME/tab`, else `~/.config/tab`, which holds user-wide
    /// worktree hooks.
    public static func configHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("tab", isDirectory: true)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config/tab", isDirectory: true)
    }

    /// `path` written from `~` when it is inside `home`, such as `~/code`;
    /// `nil` outside it, or when the home folder is the root.
    public static func abbreviateHome(_ path: String, home: String) -> String? {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard home != "/", !home.isEmpty else { return nil }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return nil }
        return "~" + path.dropFirst(home.count)
    }

    /// `~` and `~/…` expanded against `home`.
    public static func expandHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }
}

public enum DirsError: Error, Equatable, CustomStringConvertible {
    case emptyOverride
    case noHome

    public var description: String {
        switch self {
        case .emptyOverride: return "TAB_DIR must not be empty"
        case .noHome: return "HOME is not set"
        }
    }
}
