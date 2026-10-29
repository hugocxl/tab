import AppKit
import TabClient
import TabCore

/// Where a remote server's connection is.
public enum RemoteServerState: Equatable, Sendable {
    case offline
    case connecting
    case connected
    case restarting
    case stopping

    public var label: String {
        switch self {
        case .offline: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .restarting: return "Restarting…"
        case .stopping: return "Stopping…"
        }
    }

    /// Connected or on its way there.
    public var isLive: Bool { self == .connected || self == .connecting }
}

/// Installing Tab on a remote server at the user's request.
public enum RemoteInstallState: Equatable, Sendable {
    case running
    case failed(String)
}

/// The glyph a server's row draws for its state.
public enum RemoteStatusGlyph: Equatable, Sendable {
    case connected
    case connecting
    case offline
    /// It failed or waits for a password: the user should look.
    case needsAttention

    @MainActor
    public func color(_ theme: AppTheme) -> NSColor {
        switch self {
        case .connected: return theme.accent
        case .connecting: return theme.warning
        case .offline: return theme.fgDim
        case .needsAttention: return theme.danger
        }
    }

    public var accessibilityName: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .offline: return "Offline"
        case .needsAttention: return "Needs attention"
        }
    }
}

/// One remote server as the host menu, the Remote Servers pane and the
/// sidebar list it.
public struct RemoteServerStatus: Equatable, Sendable {
    public var entry: ServerEntry
    public var state: RemoteServerState
    /// Why it isn't connected, when it failed.
    public var error: String?
    /// What kind of failure `error` is, when ssh or the bridge said.
    public var failure: RemoteReason?
    /// It logs in with a password that hasn't been typed this session.
    public var needsPassword: Bool
    public var install: RemoteInstallState?
    /// A reconnect is scheduled.
    public var waitingToRetry: Bool

    public init(entry: ServerEntry, state: RemoteServerState = .offline, error: String? = nil,
                failure: RemoteReason? = nil, needsPassword: Bool = false,
                install: RemoteInstallState? = nil, waitingToRetry: Bool = false) {
        self.entry = entry
        self.state = state
        self.error = error
        self.failure = failure
        self.needsPassword = needsPassword
        self.install = install
        self.waitingToRetry = waitingToRetry
    }

    public var id: ServerId { entry.id }

    /// Tab isn't installed there.
    public var missing: Bool { failure == .notInstalled }
    /// Tab there can't talk to this app.
    public var incompatible: Bool { failure == .incompatible }

    public var glyph: RemoteStatusGlyph {
        switch state {
        case .connected: return .connected
        case .connecting, .restarting, .stopping: return .connecting
        case .offline where error != nil || needsPassword || installError != nil: return .needsAttention
        case .offline: return .offline
        }
    }

    /// The short state shown at the end of a row.
    public var label: String {
        if needsPassword && state == .offline { return "Password needed" }
        if install == .running { return "Installing…" }
        return state.label
    }

    /// The line under a row: why it failed or how its install went.
    public var detail: String? {
        if let installError { return "Install failed: \(installError)" }
        return error
    }

    private var installError: String? {
        if case .failed(let error) = install { return error }
        return nil
    }
}

/// This app's version when it is a published release, which remote servers
/// can install. Local and debug builds have none.
public enum RemoteRelease {
    public static var installableVersion: String? {
        installable(Release.version, debug: Release.isDebugBuild)
    }

    static func installable(_ version: String, debug: Bool) -> String? {
        guard !debug, ReleaseVersion(version) != nil else { return nil }
        return version
    }

    /// The command that replaces Tab on another computer with `version`.
    public static func updateCommand(version: String) -> String {
        "curl -fsSL \(RemoteInstall.releases)/v\(version)/install-tab.sh | sh -s -- --version \(version) --replace"
    }

    /// Prints the version of Tab installed there, found as the bridge finds it.
    static let versionCommand = #"sh -c 'export PATH="$PATH:$HOME/.local/bin"; exec tab --version'"#

    /// The version in `tab --version` output.
    static func parseVersion(_ printed: String) -> String {
        var text = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("tab") { text = String(text.dropFirst(3)) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Why Tab on another computer can't talk to this app, and how to fix
    /// it. `there` is the version installed there, when it could be read.
    /// When it is this app's own, the server still running there is older.
    public static func incompatibleGuidance(name: String, there: String?, here: String = Release.version,
                                            installable: String? = installableVersion) -> String {
        if there == here {
            return "Tab on \(name) is \(here), but its running server is another version. Restart it there, which ends its terminals: pkill -x tabd"
        }
        let installed = there.map { "Tab on \(name) is \($0)" } ?? "Tab on \(name) is another version"
        let fix = installable.map { "Update Tab on \(name): \(updateCommand(version: $0))" }
            ?? "Install a matching build there by hand."
        return "\(installed); this app needs a version that speaks protocol V\(ProtocolVersion.current), like \(here). \(fix)"
    }
}
