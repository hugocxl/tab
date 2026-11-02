import Foundation
import TabCore

/// A result or question the updater shows until it is answered, dismissed
/// or replaced.
public enum UpdateNotice: Equatable, Sendable {
    /// A check the person asked for found nothing newer than `version`.
    case upToDate(version: String)
    /// A check the person asked for can't run on this build, and why.
    case unavailable(String)
    /// A check the person asked for failed, and why.
    case checkFailed(String)
    /// Downloading or verifying `version` failed, and why.
    case downloadFailed(version: String, reason: String)
    case installFailed(String)
    /// Unsaved editors stopped the install.
    case unsavedEditors
    /// Installing ends running terminals; waiting for the person to agree.
    case confirmUpdate
    /// Restarting the outdated server ends running terminals; waiting for
    /// the person to agree.
    case confirmServerRestart
    case serverRestartFailed(String)
    /// The server was restarted on this app's build.
    case serverRestarted(version: String)
    /// This launch is the first of a newly installed `version`.
    case updated(version: String)

    /// How long the notice stays before it hides itself, if it does.
    public var lifetime: TimeInterval? {
        switch self {
        case .upToDate, .serverRestarted: return 6
        case .updated: return 30
        default: return nil
        }
    }
}

/// The window's update chip: one line about where updating is, and at most
/// one button. Kept free of side effects so it can be tested.
public struct UpdateChip: Equatable, Sendable {
    /// Shared by the update chip and Server settings.
    static func serverUpdateMessage(version: String) -> String {
        "The server is still running \(Release.appName) \(version). Restart it to finish updating."
    }

    public enum Tone: Equatable, Sendable { case neutral, info, success, warning, danger }

    public enum Icon: Equatable, Sendable {
        /// Work of unknown length.
        case spinner
        /// A download, from 0 to 1.
        case progress(Double)
        /// An SF Symbol, drawn in the tone's color.
        case symbol(String)
    }

    public enum Action: Equatable, Sendable {
        /// Downloads and verifies the available release in the background.
        case download
        /// Installs the downloaded release and restarts the app, asking first when that ends terminals.
        case update
        /// Ends every terminal and installs; already agreed.
        case endTerminalsAndUpdate
        /// Restarts the outdated server, asking first when that ends terminals.
        case restartServer
        /// Ends every terminal and restarts the server; already agreed.
        case endTerminalsAndRestartServer
        case checkAgain
        case showChangelog
    }

    public struct Button: Equatable, Sendable {
        public var title: String
        public var action: Action
    }

    /// What closing the chip forgets.
    public enum Dismissal: Equatable, Sendable {
        /// The notice; a confirmation goes back to the chip it asked from.
        case notice
        /// The download of `version`, which carries on out of view.
        case download(String)
        /// The available `version`, until a newer one or a check the person asks for.
        case available(String)
        /// The ready `version`, until a newer one is downloaded or a check is asked for.
        case ready(String)
        /// The outdated server of `version`.
        case server(String)
    }

    public var tone: Tone
    public var icon: Icon
    public var message: String
    public var button: Button?
    /// `nil` while the chip can't be closed, such as while installing.
    public var dismissal: Dismissal?

    /// A downloaded release, with whether it speaks the running server's protocol.
    public struct Ready: Equatable, Sendable {
        public var version: String
        public var compatible: Bool

        public init(version: String, compatible: Bool) {
            self.version = version
            self.compatible = compatible
        }
    }

    /// The chip for the updater's state, or `nil` when there is nothing to say.
    /// - Parameters:
    ///   - checking: a check the person asked for is running.
    ///   - showsDownload: the download wasn't dismissed.
    ///   - available: a release newer than any downloaded, not downloaded
    ///     yet and not dismissed.
    ///   - ready: the downloaded release, unless dismissed or the server is disconnected.
    ///   - outdatedServer: the running server's version when it is older than
    ///     this app, still has terminals and wasn't dismissed.
    ///   - sessions: terminals on the local server.
    public static func make(
        status: UpdaterStatus,
        notice: UpdateNotice?,
        checking: Bool,
        showsDownload: Bool,
        available: String? = nil,
        ready: Ready?,
        outdatedServer: String?,
        sessions: Int
    ) -> UpdateChip? {
        let app = Release.appName
        switch status {
        case .installing(let version):
            return UpdateChip(tone: .info, icon: .spinner, message: "Installing \(app) \(version)…", dismissal: nil)
        case .restartingServer:
            return UpdateChip(tone: .neutral, icon: .spinner, message: "Restarting the server…", dismissal: nil)
        default:
            break
        }

        switch notice {
        case .confirmUpdate? where ready.map({ UpdateDecision.step(compatible: $0.compatible, sessions: sessions) }) == .confirmEndingTerminals:
            return UpdateChip(tone: .warning, icon: .symbol("exclamationmark.circle.fill"),
                              message: "Restart now? This ends \(terminals(sessions)).",
                              button: Button(title: "Restart", action: .endTerminalsAndUpdate), dismissal: .notice)
        case .confirmServerRestart? where outdatedServer != nil:
            return UpdateChip(tone: .warning, icon: .symbol("exclamationmark.circle.fill"),
                              message: "Restart the server? This ends \(terminals(sessions)).",
                              button: Button(title: "Restart", action: .endTerminalsAndRestartServer), dismissal: .notice)
        case .installFailed(let reason)?:
            return UpdateChip(tone: .danger, icon: .symbol("exclamationmark.circle.fill"),
                              message: "Couldn’t install the update. \(sentence(reason))",
                              button: ready.map { _ in Button(title: "Try Again", action: .update) }, dismissal: .notice)
        case .unsavedEditors? where ready != nil:
            return UpdateChip(tone: .warning, icon: .symbol("exclamationmark.circle.fill"),
                              message: "Save or close files with unsaved changes, then restart.",
                              button: Button(title: "Restart", action: .update), dismissal: .notice)
        case .serverRestartFailed(let reason)?:
            return UpdateChip(tone: .danger, icon: .symbol("exclamationmark.circle.fill"),
                              message: "Couldn’t restart the server. \(sentence(reason))",
                              button: outdatedServer.map { _ in Button(title: "Try Again", action: .restartServer) }, dismissal: .notice)
        default:
            break
        }

        switch status {
        case let .downloading(version, progress) where showsDownload:
            let percent = progress.map { " \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return UpdateChip(tone: .info, icon: progress.map(Icon.progress) ?? .spinner,
                              message: "Downloading \(app) \(version)…\(percent)", dismissal: .download(version))
        case .preparing(let version) where showsDownload:
            return UpdateChip(tone: .info, icon: .spinner, message: "Verifying \(app) \(version)…", dismissal: .download(version))
        default:
            break
        }

        if let outdatedServer {
            return UpdateChip(tone: .warning, icon: .symbol("exclamationmark.circle.fill"),
                              message: serverUpdateMessage(version: outdatedServer),
                              button: Button(title: "Restart", action: .restartServer), dismissal: .server(outdatedServer))
        }

        if let available {
            return UpdateChip(tone: .info, icon: .symbol("arrow.down.circle.fill"), message: "\(app) \(available) is available.",
                              button: Button(title: "Update", action: .download), dismissal: .available(available))
        }

        if let ready {
            let message: String
            switch UpdateDecision.step(compatible: ready.compatible, sessions: sessions) {
            case .install where sessions > 0:
                message = "\(app) \(ready.version) is ready. Restart to finish updating; your terminals keep running."
            case .install, .installStoppingIdleServer:
                message = "\(app) \(ready.version) is ready. Restart to finish updating."
            case .confirmEndingTerminals:
                message = "\(app) \(ready.version) is ready. It needs a new server, so restarting ends running terminals."
            }
            return UpdateChip(tone: .info, icon: .symbol("arrow.clockwise.circle.fill"), message: message,
                              button: Button(title: "Restart", action: .update), dismissal: .ready(ready.version))
        }

        switch notice {
        case .updated(let version)?:
            return UpdateChip(tone: .success, icon: .symbol("checkmark.circle.fill"), message: "Updated to \(app) \(version).",
                              button: Button(title: "What’s New", action: .showChangelog), dismissal: .notice)
        case .serverRestarted(let version)?:
            return UpdateChip(tone: .success, icon: .symbol("checkmark.circle.fill"),
                              message: "The server is running \(app) \(version).", dismissal: .notice)
        default:
            break
        }

        if checking {
            return UpdateChip(tone: .neutral, icon: .spinner, message: "Checking for updates…", dismissal: nil)
        }

        switch notice {
        case .checkFailed(let reason)?:
            return UpdateChip(tone: .danger, icon: .symbol("exclamationmark.circle.fill"),
                              message: "Couldn’t check for updates. \(sentence(reason))",
                              button: Button(title: "Try Again", action: .checkAgain), dismissal: .notice)
        case let .downloadFailed(version, reason)?:
            return UpdateChip(tone: .danger, icon: .symbol("exclamationmark.circle.fill"),
                              message: "Couldn’t download \(app) \(version). \(sentence(reason))",
                              button: Button(title: "Try Again", action: .checkAgain), dismissal: .notice)
        case .unavailable(let reason)?:
            return UpdateChip(tone: .warning, icon: .symbol("exclamationmark.circle.fill"), message: sentence(reason), dismissal: .notice)
        case .upToDate(let version)?:
            return UpdateChip(tone: .success, icon: .symbol("checkmark.circle.fill"),
                              message: "You’re up to date. \(app) \(version) is the latest version.", dismissal: .notice)
        default:
            return nil
        }
    }

    /// One chip of every state, in the order an update meets them, for previewing.
    static let previews: [UpdateChip] = {
        let version = "1.5.0"
        let compatible = Ready(version: version, compatible: true)
        let incompatible = Ready(version: version, compatible: false)
        typealias Sample = (status: UpdaterStatus, notice: UpdateNotice?, checking: Bool, available: String?,
                            ready: Ready?, server: String?, sessions: Int)
        let samples: [Sample] = [
            (.checking, nil, true, nil, nil, nil, 0),
            (.idle, .upToDate(version: Release.version), false, nil, nil, nil, 0),
            (.available(version: version), nil, false, version, nil, nil, 0),
            (.downloading(version: version, progress: 0.42), nil, false, nil, nil, nil, 0),
            (.preparing(version: version), nil, false, nil, nil, nil, 0),
            (.ready(version: version), nil, false, nil, compatible, nil, 0),
            (.ready(version: version), nil, false, nil, compatible, nil, 2),
            (.ready(version: version), nil, false, nil, incompatible, nil, 2),
            (.ready(version: version), .confirmUpdate, false, nil, incompatible, nil, 2),
            (.ready(version: version), .unsavedEditors, false, nil, incompatible, nil, 2),
            (.installing(version: version), nil, false, nil, incompatible, nil, 2),
            (.idle, .updated(version: version), false, nil, nil, nil, 0),
            (.idle, nil, false, nil, nil, "1.4.2", 2),
            (.idle, .confirmServerRestart, false, nil, nil, "1.4.2", 2),
            (.restartingServer, nil, false, nil, nil, "1.4.2", 2),
            (.idle, .serverRestarted(version: version), false, nil, nil, nil, 0),
            (.idle, .checkFailed("You’re offline."), false, nil, nil, nil, 0),
            (.idle, .downloadFailed(version: version, reason: "The update download doesn't match its checksum."), false, nil, nil, nil, 0),
            (.ready(version: version), .installFailed("Can't write next to Tab.app."), false, nil, compatible, nil, 0),
            (.idle, .serverRestartFailed("The server didn’t come back in time."), false, nil, nil, "1.4.2", 2),
            (.idle, .unavailable("Move \(Release.appName).app to Applications and reopen it before updating."), false, nil, nil, nil, 0),
        ]
        return samples.compactMap {
            make(status: $0.status, notice: $0.notice, checking: $0.checking, showsDownload: true,
                 available: $0.available, ready: $0.ready, outdatedServer: $0.server, sessions: $0.sessions)
        }
    }()

    init(tone: Tone, icon: Icon, message: String, button: Button? = nil, dismissal: Dismissal?) {
        self.tone = tone
        self.icon = icon
        self.message = message
        self.button = button
        self.dismissal = dismissal
    }

    static func terminals(_ count: Int) -> String {
        count == 1 ? "1 running terminal" : "\(count) running terminals"
    }

    /// Why a check, download or install failed, in words for the person.
    static func reason(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "You’re offline."
            case .timedOut: return "The connection timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "GitHub can’t be reached."
            default: return error.localizedDescription
            }
        }
        if let error = error as? UpdateError {
            if case .download(let reason) = error { return "The download failed: \(reason)" }
            return error.description
        }
        return error.localizedDescription
    }

    /// `text` as a sentence: capitalized and ending with a period.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        let capitalized = first.uppercased() + trimmed.dropFirst()
        return capitalized.last.map { ".!?…".contains($0) } == true ? capitalized : capitalized + "."
    }
}
