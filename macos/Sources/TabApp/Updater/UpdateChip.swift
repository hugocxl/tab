import Foundation
import TabCore
import TabProtocol

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
    /// Installing restarts the server, which keeps its terminals but stops
    /// this work; waiting for the person to agree.
    case confirmUpdateStopping(ServerWork)
    /// Restarting the outdated server ends running terminals; waiting for
    /// the person to agree.
    case confirmServerRestart
    /// Restarting the server keeps its terminals but stops this work;
    /// waiting for the person to agree.
    case confirmServerRestartStopping(ServerWork)
    case serverRestartFailed(String)
    /// The server was restarted on this app's build.
    case serverRestarted(version: String)
    /// This launch is the first of a newly installed `version`.
    case updated(version: String)

    /// How long the notice stays before it hides itself, if it does.
    public var lifetime: TimeInterval? {
        switch self {
        case .serverRestarted: return 4
        case .upToDate: return 6
        case .updated: return 12
        default: return nil
        }
    }
}

/// The window's update chip: one line about where updating is, and at most
/// one button. Kept free of side effects so it can be tested.
public struct UpdateChip: Equatable, Sendable {
    /// Shared by the update chip and Server settings.
    static func serverUpdateMessage(version: String) -> String {
        "Terminals still run on the server from \(Release.appName) \(version). Restart it to finish updating."
    }

    public typealias Tone = Notice.Tone
    public typealias Icon = Notice.Icon

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
        /// Restarts the server keeping its terminals, stopping the work that runs, and installs; already agreed.
        case updateStoppingWork
        /// Restarts the server keeping its terminals, stopping the work that runs; already agreed.
        case restartServerStoppingWork
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

    /// The chip as the window's notifications show it.
    public var notice: Notice {
        Notice(tone: tone, icon: icon, message: message, button: button?.title, dismissible: dismissal != nil)
    }

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
    ///   - agents: open agent sessions on the local server.
    ///   - waitingForServer: a downloaded release waiting for the local connection to recover.
    ///   - keepsTerminals: the local server keeps its terminals through a restart.
    ///   - quiet: the ready release and the outdated server are taken care of
    ///     in the background, so they go unmentioned; restarts started in the
    ///     background too.
    public static func make(
        status: UpdaterStatus,
        notice: UpdateNotice?,
        checking: Bool,
        showsDownload: Bool,
        available: String? = nil,
        downloadHold: UpdateDownloadHold? = nil,
        ready: Ready?,
        relaunchWhenIdle: Bool = false,
        outdatedServer: String?,
        sessions: Int,
        agents: Int = 0,
        waitingForServer: String? = nil,
        keepsTerminals: Bool = false,
        quiet: Quiet = Quiet()
    ) -> UpdateChip? {
        let app = Release.appName
        switch status {
        case .installing(let version) where !quiet.install:
            return UpdateChip(tone: .info, icon: .spinner, message: "Installing \(app) \(version)…", dismissal: nil)
        case .installed(let version) where !quiet.install:
            return UpdateChip(tone: .info, icon: .icon(.refreshCircle),
                              message: "\(app) \(version) is installed. Restart to open it.",
                              button: Button(title: "Restart", action: .update), dismissal: nil)
        case .restartingServer where !quiet.serverRestart:
            return UpdateChip(tone: .neutral, icon: .spinner, message: "Restarting the server…", dismissal: nil)
        default:
            break
        }

        switch notice {
        case .confirmUpdate? where ready.map({ UpdateDecision.step(compatible: $0.compatible, sessions: sessions, agents: agents) }) == .confirmEndingTerminals:
            return UpdateChip(tone: .warning, icon: .icon(.circleAlert),
                              message: "Restart now? This ends \(endingWork(sessions)).",
                              button: Button(title: "Restart", action: .endTerminalsAndUpdate), dismissal: .notice)
        case .confirmUpdateStopping(let work)? where ready != nil:
            return UpdateChip(tone: .warning, icon: .icon(.circleAlert),
                              message: "Restart now? \(consequence(of: work))",
                              button: Button(title: "Restart", action: .updateStoppingWork), dismissal: .notice)
        case .confirmServerRestart? where outdatedServer != nil:
            return UpdateChip(tone: .warning, icon: .icon(.circleAlert),
                              message: "Restart the server? This ends \(endingWork(sessions)).",
                              button: Button(title: "Restart", action: .endTerminalsAndRestartServer), dismissal: .notice)
        case .confirmServerRestartStopping(let work)?:
            return UpdateChip(tone: .warning, icon: .icon(.circleAlert),
                              message: "Restart the server? \(consequence(of: work))",
                              button: Button(title: "Restart", action: .restartServerStoppingWork), dismissal: .notice)
        case .installFailed(let reason)?:
            return UpdateChip(tone: .danger, icon: .icon(.circleAlert),
                              message: "Couldn’t install the update. \(sentence(reason))",
                              button: ready != nil ? Button(title: "Try Again", action: .update)
                                  : available.map { _ in Button(title: "Download Again", action: .download) }, dismissal: .notice)
        case .unsavedEditors? where ready != nil:
            return UpdateChip(tone: .warning, icon: .icon(.circleAlert),
                              message: "Save or close files with unsaved changes, then restart.",
                              button: Button(title: "Restart", action: .update), dismissal: .notice)
        case .serverRestartFailed(let reason)?:
            return UpdateChip(tone: .danger, icon: .icon(.circleAlert),
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
        case .downloading, .preparing:
            return nil
        default:
            break
        }

        if checking {
            return UpdateChip(tone: .neutral, icon: .spinner, message: "Checking for updates…", dismissal: nil)
        }

        switch notice {
        case .checkFailed(let reason)?:
            return UpdateChip(tone: .danger, icon: .icon(.circleAlert),
                              message: "Couldn’t check for updates. \(sentence(reason))",
                              button: Button(title: "Try Again", action: .checkAgain), dismissal: .notice)
        case let .downloadFailed(version, reason)?:
            return UpdateChip(tone: .danger, icon: .icon(.circleAlert),
                              message: "Couldn’t download \(app) \(version). \(sentence(reason))",
                              button: Button(title: "Try Again", action: available == version ? .download : .checkAgain), dismissal: .notice)
        case .unavailable(let reason)?:
            return UpdateChip(tone: .warning, icon: .icon(.circleAlert), message: sentence(reason), dismissal: .notice)
        case .upToDate(let version)?:
            return UpdateChip(tone: .success, icon: .icon(.circleCheck),
                              message: "You’re up to date. \(app) \(version) is the latest version.", dismissal: .notice)
        default:
            break
        }

        if let available {
            let message: String
            let buttonTitle: String
            switch downloadHold {
            case .lowDataMode?:
                message = "\(app) \(available) is available. Download paused in Low Data Mode."
                buttonTitle = "Download"
            case .hotspot?:
                message = "\(app) \(available) is available. Download paused on hotspot."
                buttonTitle = "Download"
            case nil:
                message = "\(app) \(available) is available."
                buttonTitle = "Update"
            }
            return UpdateChip(tone: .info, icon: .icon(.circleArrowDown), message: message,
                              button: Button(title: buttonTitle, action: .download), dismissal: .available(available))
        }

        if let ready, !quiet.ready {
            let message: String
            let buttonTitle: String
            switch UpdateDecision.step(compatible: ready.compatible, keepsTerminals: keepsTerminals, sessions: sessions, agents: agents) {
            case .install where relaunchWhenIdle:
                message = sessions > 0 || agents > 0
                    ? "\(app) \(ready.version) is ready. It installs while you’re away; terminals and agents keep running."
                    : "\(app) \(ready.version) is ready. It installs while you’re away."
                buttonTitle = "Restart Now"
            case .installRestartingServer where relaunchWhenIdle:
                message = sessions > 0
                    ? "\(app) \(ready.version) is ready. It installs while you’re away; terminals reopen where they were."
                    : "\(app) \(ready.version) is ready. It installs while you’re away."
                buttonTitle = "Restart Now"
            case .install where sessions > 0 || agents > 0:
                message = "\(app) \(ready.version) is ready. Restart to finish updating; your terminals and agents keep running."
                buttonTitle = "Restart"
            case .install, .installStoppingIdleServer:
                message = "\(app) \(ready.version) is ready. Restart to finish updating."
                buttonTitle = "Restart"
            case .installRestartingServer:
                message = sessions > 0 || agents > 0
                    ? "\(app) \(ready.version) is ready. Restart to finish updating; terminals reopen where they were."
                    : "\(app) \(ready.version) is ready. Restart to finish updating."
                buttonTitle = "Restart"
            case .confirmEndingTerminals:
                message = "\(app) \(ready.version) is ready. It needs a new server, so restarting ends running terminals and agents."
                buttonTitle = "Restart"
            }
            return UpdateChip(tone: .info, icon: .icon(.refreshCircle), message: message,
                              button: Button(title: buttonTitle, action: .update), dismissal: .ready(ready.version))
        }

        if let version = waitingForServer, !quiet.ready {
            return UpdateChip(tone: .neutral, icon: .spinner,
                              message: "\(app) \(version) is ready. Waiting for the local server before restarting.",
                              dismissal: .ready(version))
        }

        if let outdatedServer, !quiet.server {
            return UpdateChip(tone: .info, icon: .icon(.refreshCircle),
                              message: serverUpdateMessage(version: outdatedServer),
                              button: Button(title: "Restart", action: .restartServer), dismissal: .server(outdatedServer))
        }

        switch notice {
        case .updated(let version)?:
            return UpdateChip(tone: .success, icon: .icon(.circleCheck), message: "Updated to \(app) \(version).",
                              button: Button(title: "What’s New", action: .showChangelog), dismissal: .notice)
        case .serverRestarted(let version)?:
            return UpdateChip(tone: .success, icon: .icon(.circleCheck),
                              message: "The server is running \(app) \(version).", dismissal: .notice)
        default:
            break
        }

        return nil
    }

    private static let sampleWork = ServerWork(programs: [.init(session: SessionId(), project: ProjectId(), name: "npm")],
                                               agents: [SessionId()])

    /// One chip of every state, in the order an update meets them, for previewing.
    static let previews: [UpdateChip] = {
        let version = "1.5.0"
        let compatible = Ready(version: version, compatible: true)
        let incompatible = Ready(version: version, compatible: false)
        typealias Sample = (status: UpdaterStatus, notice: UpdateNotice?, checking: Bool, available: String?,
                            hold: UpdateDownloadHold?, ready: Ready?, idle: Bool, server: String?, sessions: Int)
        let samples: [Sample] = [
            (.checking, nil, true, nil, nil, nil, false, nil, 0),
            (.idle, .upToDate(version: Release.version), false, nil, nil, nil, false, nil, 0),
            (.available(version: version), nil, false, version, nil, nil, false, nil, 0),
            (.available(version: version), nil, false, version, .lowDataMode, nil, false, nil, 0),
            (.available(version: version), nil, false, version, .hotspot, nil, false, nil, 0),
            (.downloading(version: version, progress: 0.42), nil, false, nil, nil, nil, false, nil, 0),
            (.preparing(version: version), nil, false, nil, nil, nil, false, nil, 0),
            (.ready(version: version), nil, false, nil, nil, compatible, false, nil, 0),
            (.ready(version: version), nil, false, nil, nil, compatible, false, nil, 2),
            (.ready(version: version), nil, false, nil, nil, compatible, true, nil, 2),
            (.ready(version: version), nil, false, nil, nil, incompatible, false, nil, 2),
            (.ready(version: version), .confirmUpdate, false, nil, nil, incompatible, false, nil, 2),
            (.ready(version: version), .confirmUpdateStopping(sampleWork), false, nil, nil, incompatible, false, nil, 2),
            (.ready(version: version), .unsavedEditors, false, nil, nil, incompatible, false, nil, 2),
            (.installing(version: version), nil, false, nil, nil, incompatible, false, nil, 2),
            (.idle, .updated(version: version), false, nil, nil, nil, false, nil, 0),
            (.idle, nil, false, nil, nil, nil, false, "1.4.2", 2),
            (.idle, .confirmServerRestart, false, nil, nil, nil, false, "1.4.2", 2),
            (.idle, .confirmServerRestartStopping(sampleWork), false, nil, nil, nil, false, "1.4.2", 2),
            (.restartingServer, nil, false, nil, nil, nil, false, "1.4.2", 2),
            (.idle, .serverRestarted(version: version), false, nil, nil, nil, false, nil, 0),
            (.idle, .checkFailed("You’re offline."), false, nil, nil, nil, false, nil, 0),
            (.idle, .downloadFailed(version: version, reason: "The update download doesn't match its checksum."), false, nil, nil, nil, false, nil, 0),
            (.ready(version: version), .installFailed("Can't write next to Tab.app."), false, nil, nil, compatible, false, nil, 0),
            (.idle, .serverRestartFailed("The server didn’t come back in time."), false, nil, nil, nil, false, "1.4.2", 2),
            (.idle, .unavailable("Move \(Release.appName).app to Applications and reopen it before updating."), false, nil, nil, nil, false, nil, 0),
        ]
        return samples.compactMap {
            make(status: $0.status, notice: $0.notice, checking: $0.checking, showsDownload: true,
                 available: $0.available, downloadHold: $0.hold, ready: $0.ready, relaunchWhenIdle: $0.idle,
                 outdatedServer: $0.server, sessions: $0.sessions)
        }
    }()

    init(tone: Tone, icon: Icon, message: String, button: Button? = nil, dismissal: Dismissal?) {
        self.tone = tone
        self.icon = icon
        self.message = message
        self.button = button
        self.dismissal = dismissal
    }

    /// What the background takes care of, so the chip doesn't mention it.
    public struct Quiet: Equatable, Sendable {
        /// The ready release installs by itself when the person is away.
        public var ready = false
        /// The outdated server restarts by itself once no work runs.
        public var server = false
        /// The server restart running now started in the background.
        public var serverRestart = false
        /// The install running now started in the background, such as when quitting.
        public var install = false

        public init(ready: Bool = false, server: Bool = false, serverRestart: Bool = false, install: Bool = false) {
            self.ready = ready
            self.server = server
            self.serverRestart = serverRestart
            self.install = install
        }
    }

    /// What a restart that keeps terminals does to `work`, in sentences.
    static func consequence(of work: ServerWork) -> String {
        var sentences: [String] = []
        if let stopped = stopping(work) { sentences.append("This stops \(stopped).") }
        switch work.agents.count {
        case 0: break
        case 1: sentences.append("The working agent picks up where it left off.")
        default: sentences.append("\(work.agents.count) working agents pick up where they left off.")
        }
        sentences.append("Terminals reopen where they were.")
        return sentences.joined(separator: " ")
    }

    /// The programs and commands a restart stops, such as “npm and cargo”.
    static func stopping(_ work: ServerWork) -> String? {
        var names: [String] = []
        for program in work.programs where !names.contains(program.name) { names.append(program.name) }
        var parts: [String]
        switch names.count {
        case 0: parts = []
        case 1, 2: parts = names
        default: parts = [names[0], names[1], "\(names.count - 2) more programs"]
        }
        if work.jobs > 0 { parts.append(work.jobs == 1 ? "a running command" : "\(work.jobs) running commands") }
        return list(parts)
    }

    /// What an automatic restart waits for, such as “npm and 1 agent”.
    static func waiting(for work: ServerWork) -> String {
        var parts: [String] = []
        if let stopped = stopping(work) { parts.append(stopped) }
        if !work.agents.isEmpty { parts.append(work.agents.count == 1 ? "1 agent" : "\(work.agents.count) agents") }
        return list(parts) ?? "running work"
    }

    private static func list(_ parts: [String]) -> String? {
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    private static func endingWork(_ sessions: Int) -> String {
        sessions == 0 ? "any running agents" : "\(terminals(sessions)) and any running agents"
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
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "A secure connection to GitHub couldn’t be made. Check the Mac’s date and time, and the proxy."
            case .cannotCreateFile, .cannotWriteToFile:
                return "The update couldn’t be saved. Check the free disk space."
            default: return error.localizedDescription
            }
        }
        if let error = error as? UpdateError {
            if case .download(let reason) = error { return "The download failed: \(reason)" }
            return error.description
        }
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
            return "There isn’t enough free disk space."
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
