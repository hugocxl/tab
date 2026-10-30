import Foundation
import TabCore

/// What the sidebar's update card shows for a downloaded release: what
/// updating does to running terminals, and the choices that fit. Kept free of
/// side effects so it can be tested.
public struct UpdateCard: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Install and relaunch; terminals keep running when the new version
        /// speaks the server's protocol or none are running.
        case restartAndUpdate
        /// Install once every terminal has ended.
        case waitForTerminals
        /// End every terminal and install, after confirming.
        case endTerminalsAndUpdate
        /// Stop waiting for terminals to end.
        case cancelWaiting
    }

    public struct Button: Equatable, Sendable {
        public enum Style: Equatable, Sendable { case primary, secondary, plain }

        public var title: String
        public var action: Action
        public var style: Style
    }

    public var title: String
    public var detail: String
    public var buttons: [Button]
    /// Installing: the buttons are disabled and the card can't be dismissed.
    public var busy: Bool

    /// The card for the updater's status, or `nil` when there is nothing to
    /// offer. `compatible` is whether the new version speaks the running
    /// server's protocol; `sessions` counts its terminals.
    public static func make(status: UpdaterStatus, compatible: Bool, sessions: Int) -> UpdateCard? {
        let app = Release.appName
        switch status {
        case .ready(let version):
            let title = "\(app) \(version) is available"
            if compatible {
                return UpdateCard(title: title, detail: "Terminals keep running.",
                                  buttons: [Button(title: "Restart and Update", action: .restartAndUpdate, style: .primary)],
                                  busy: false)
            }
            if sessions == 0 {
                return UpdateCard(title: title, detail: "No terminals are running, so nothing is interrupted.",
                                  buttons: [Button(title: "Restart and Update", action: .restartAndUpdate, style: .primary)],
                                  busy: false)
            }
            return UpdateCard(
                title: title,
                detail: "It needs a new server, which ends running terminals. \(running(sessions)).",
                buttons: [
                    Button(title: "Wait for Terminals", action: .waitForTerminals, style: .primary),
                    Button(title: "Update Now…", action: .endTerminalsAndUpdate, style: .secondary),
                ],
                busy: false
            )
        case .waitingForSessions(let version, let sessions):
            return UpdateCard(
                title: "\(app) \(version) is waiting",
                detail: "\(installsOnce(sessions)) Idle and detached terminals count.",
                buttons: [
                    Button(title: "Update Now…", action: .endTerminalsAndUpdate, style: .secondary),
                    Button(title: "Cancel Update", action: .cancelWaiting, style: .plain),
                ],
                busy: false
            )
        case .installing(let version):
            return UpdateCard(title: "Updating to \(app) \(version)", detail: "\(app) restarts in a moment.",
                              buttons: [Button(title: "Restarting…", action: .restartAndUpdate, style: .primary)],
                              busy: true)
        case .idle, .unavailable, .checking, .downloading, .failed:
            return nil
        }
    }

    private static func running(_ sessions: Int) -> String {
        sessions == 1 ? "1 is running" : "\(sessions) are running"
    }

    private static func installsOnce(_ sessions: Int) -> String {
        sessions == 1 ? "It installs once the last terminal ends." : "It installs once all \(sessions) terminals end."
    }
}
