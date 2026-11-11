import Foundation
import TabCore
import TabProtocol

/// How a downloaded release gets installed, given the running server.
public enum UpdateStep: Equatable, Sendable {
    /// The new app speaks the server's protocol: install and relaunch, and
    /// the running server keeps its terminals until it is idle.
    case install
    /// The new app needs a new server and no terminal runs: stop the idle
    /// server, then install.
    case installStoppingIdleServer
    /// The new app needs a new server and terminals run: installing ends
    /// them, so ask first.
    case confirmEndingTerminals
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

    /// What installing does now. Nothing ends without asking.
    public static func step(compatible: Bool, sessions: Int, agents: Int = 0) -> UpdateStep {
        if compatible { return .install }
        return sessions == 0 && agents == 0 ? .installStoppingIdleServer : .confirmEndingTerminals
    }

    /// Whether the running local server is from an older build than this app.
    public static func isOutdated(serverVersion: String?, appVersion: String) -> Bool {
        guard let serverVersion else { return false }
        return ReleaseVersion.isNewer(appVersion, than: serverVersion)
    }

    /// Whether a running local server is older than this app and can be
    /// replaced: it is stopped once no terminals need it, and the app starts
    /// its own build's server.
    public static func shouldReplaceServer(serverVersion: String?, appVersion: String, sessions: Int) -> Bool {
        sessions == 0 && isOutdated(serverVersion: serverVersion, appVersion: appVersion)
    }
}
