import Foundation
import TabCore
import TabProtocol

/// What the "Update available" sheet offers for a downloaded release.
public enum UpdateOffer: Equatable, Sendable {
    /// The new app speaks the running server's protocol: install now and keep
    /// terminals running, optionally restarting the server too.
    case installNow
    /// The new app needs a new server: wait for every terminal to end, or
    /// end them now.
    case needsNewServer
    /// The new app needs a new server and is already waiting for terminals
    /// to end.
    case waitingForSessions(Int)
}

/// What the person chose in the sheet.
public enum UpdateChoice: Equatable, Sendable {
    /// Install now; `restartServer` also replaces the server now, ending
    /// every terminal.
    case install(restartServer: Bool)
    /// Install once every terminal has ended.
    case waitForSessions
    /// Install now, ending every terminal; already confirmed.
    case endSessions
    /// Stop waiting for terminals to end.
    case cancelWaiting
    case later
}

/// What the updater does next.
public enum UpdateStep: Equatable, Sendable {
    /// Replace the bundle and relaunch. With `stopServer` the server is
    /// stopped first (ending terminals) so the new app starts the new one;
    /// without it the running server keeps going from the old bundle until
    /// it is idle.
    case install(stopServer: Bool)
    /// Keep the download and install when the session count reaches zero.
    case wait
    /// Forget the scheduled install, keeping the download.
    case cancelWait
    case nothing
}

/// The install decision table, kept free of side effects so it can be tested.
public enum UpdateDecision {
    /// Whether the new release speaks a protocol of the running server. A
    /// feed without protocol versions, or no connected server, counts as not
    /// compatible: the safe choice keeps terminals from ending unasked.
    public static func isCompatible(_ manifest: UpdateManifest, with server: BuildInfo?) -> Bool {
        guard let server else { return false }
        return manifest.protocolVersions.contains(where: server.protocolVersions.contains)
    }

    public static func offer(compatible: Bool, scheduled: Bool, sessions: Int) -> UpdateOffer {
        if scheduled { return .waitingForSessions(sessions) }
        return compatible ? .installNow : .needsNewServer
    }

    /// The step for a choice. Installing over an incompatible server always
    /// stops it, and waiting with nothing left to wait for installs at once.
    public static func step(for choice: UpdateChoice, compatible: Bool, sessions: Int) -> UpdateStep {
        switch choice {
        case .install(let restartServer):
            return .install(stopServer: restartServer || !compatible)
        case .endSessions:
            return .install(stopServer: true)
        case .waitForSessions:
            return sessions == 0 ? .install(stopServer: true) : .wait
        case .cancelWaiting:
            return .cancelWait
        case .later:
            return .nothing
        }
    }

    /// While an install waits for terminals to end: install once none are left.
    public static func scheduledStep(sessions: Int) -> UpdateStep {
        sessions == 0 ? .install(stopServer: true) : .wait
    }

    /// Whether a running local server is older than this app and can be
    /// replaced: it is stopped once no terminals need it, and the app starts
    /// its own build's server.
    public static func shouldReplaceServer(serverVersion: String?, appVersion: String, sessions: Int) -> Bool {
        guard let serverVersion, sessions == 0 else { return false }
        return ReleaseVersion.isNewer(appVersion, than: serverVersion)
    }
}
