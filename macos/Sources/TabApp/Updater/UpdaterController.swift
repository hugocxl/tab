import AppKit
import TabCore
import TabProtocol

/// What the updater needs from the app shell.
@MainActor
public protocol UpdaterHost: AnyObject {
    /// The connected local server's build (version and protocol versions);
    /// `nil` while disconnected.
    var localServerBuild: BuildInfo? { get }
    /// Changes each time the local server process starts.
    var localServerInstance: UInt64? { get }
    /// Terminals on the local server, including idle and detached ones.
    var runningSessionCount: Int { get }
    /// Open agent sessions, including chats waiting for input.
    var runningAgentCount: Int { get }
    /// Agents on the local server working or waiting for an answer now.
    var workingAgentCount: Int { get }
    /// Whether the local server keeps its terminals in their panes through a restart.
    var localServerKeepsTerminals: Bool { get }
    /// Stops the local server, ending every terminal on it.
    func endAllSessions() async throws
    /// Stops the local server only when no terminal runs; returns whether it stops.
    func stopLocalServerIfIdle() async -> Bool
    /// Restarts the local server on this app's build, ending every terminal on it.
    func restartLocalServer() async throws
    /// Restarts the local server on this app's build, keeping its terminals in
    /// their panes. With `onlyWhenIdle` it returns the work that keeps it
    /// running instead; `nil` means it restarts.
    func restartLocalServerKeepingTerminals(onlyWhenIdle: Bool) async throws -> ServerWork?
    /// Starts this app's build of the local server in the background once the
    /// old one is gone, such as when Tab quits right after restarting it.
    func startLocalServer()
    /// Saves state and settles unsaved editors before quitting for an
    /// update; `false` cancels the install.
    func prepareToQuitForUpdate() async throws -> Bool
    /// Quits the app. The new version is already in place and starts once
    /// this process exits.
    func quitForUpdate()
    /// Whether Tab's UI is in a state that allows a quiet idle relaunch.
    var automaticInstallEnvironment: AutomaticInstallEnvironment { get }
    /// The updater's status or chip changed.
    func updaterDidChange()
}

public extension UpdaterHost {
    var automaticInstallEnvironment: AutomaticInstallEnvironment {
        AutomaticInstallEnvironment(isWindowVisible: true)
    }
    var workingAgentCount: Int { runningAgentCount }
    var localServerKeepsTerminals: Bool { false }
    func restartLocalServerKeepingTerminals(onlyWhenIdle: Bool) async throws -> ServerWork? {
        throw UpdateError.unavailable("This server can't restart while keeping its terminals.")
    }
    func startLocalServer() {}
}

/// Snapshot of the updater's state for Settings and the Command Palette.
public struct UpdaterSummary: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case check
        case download
        case install
    }

    public var detail: String
    public var buttonTitle: String
    public var buttonEnabled: Bool
    public var action: Action
    public var canRelaunchWhenIdle: Bool
    public var relaunchWhenIdle: Bool

    public init(
        detail: String,
        buttonTitle: String = "Check for Updates",
        buttonEnabled: Bool = true,
        action: Action = .check,
        canRelaunchWhenIdle: Bool = false,
        relaunchWhenIdle: Bool = false
    ) {
        self.detail = detail
        self.buttonTitle = buttonTitle
        self.buttonEnabled = buttonEnabled
        self.action = action
        self.canRelaunchWhenIdle = canRelaunchWhenIdle
        self.relaunchWhenIdle = relaunchWhenIdle
    }
}

/// Where the updater is.
public enum UpdaterStatus: Equatable, Sendable {
    case idle
    /// This build can't update itself, and why.
    case unavailable(String)
    case checking
    /// A newer release is out, waiting for the person to download it.
    case available(version: String)
    /// `progress` runs from 0 to 1 once the download's size is known.
    case downloading(version: String, progress: Double?)
    /// Checking the download's signature and contents.
    case preparing(version: String)
    /// Downloaded and verified, waiting for the person.
    case ready(version: String)
    case installing(version: String)
    /// The bundle was replaced; quitting may still be cancelled by unsaved work.
    case installed(version: String)
    /// Restarting the outdated local server on this app's build.
    case restartingServer
}

/// Checks GitHub Releases for a new Tab and keeps it current with as little
/// interruption as possible:
///
/// - Checks hourly, after waking and when Tab comes forward if a check is
///   overdue; downloads and verifies in the background, retrying failures.
/// - Installs a ready release when Tab quits, and relaunches into it while
///   the person is away or Tab is out of sight, as it was.
/// - Restarts an outdated local server on this app's build while the person
///   is away and no program or agent works; terminals reopen in their panes.
/// - Says only what needs the person: a release that can't install by
///   itself for a long while, a failure, or a question before anything
///   running stops.
@MainActor
public final class UpdaterController {
    /// Background checks run at launch and then this often.
    public static let checkInterval: TimeInterval = 60 * 60
    /// How long a server restart may take before it counts as failed.
    static let serverRestartTimeout: TimeInterval = 30
    /// How long a ready release that installs by itself stays unmentioned.
    static let readyReminderDelay: TimeInterval = 12 * 60 * 60
    /// Waits between asking a busy server again whether it can restart.
    static let idleRestartDelays: [TimeInterval] = [50, 2 * 60, 5 * 60, 10 * 60]
    /// Waits before retrying a failed background download.
    static let downloadRetryDelays: [TimeInterval] = [2 * 60, 10 * 60, 30 * 60, 60 * 60]
    /// How long quitting may wait for an update to install.
    public static let quitInstallTimeout: TimeInterval = 15

    public private(set) var status: UpdaterStatus = .idle {
        didSet { if status != oldValue { host?.updaterDidChange() } }
    }

    /// The downloaded release waiting to install.
    public private(set) var prepared: PreparedUpdate?
    /// A release newer than `prepared`, not downloaded yet.
    public private(set) var available: UpdateManifest?
    /// The last time an update check completed.
    public private(set) var lastCheckDate: Date?
    /// Why an automatic background download is paused, if it is.
    public private(set) var downloadHold: UpdateDownloadHold?
    /// Whether the person asked to install the ready update once Tab is hidden.
    public private(set) var relaunchWhenIdle = false
    /// What kept the outdated server from restarting by itself last time.
    public private(set) var serverWork: ServerWork?
    /// A newer release this Mac's macOS is too old for, said in words.
    public private(set) var systemNote: String?

    /// Whether the current ready update can be scheduled for quiet idle relaunch.
    public var canRelaunchWhenIdle: Bool {
        guard prepared != nil, host?.localServerBuild != nil else { return false }
        return installServerReady
    }

    /// Whether the window should mention a restart of the server: one the
    /// person started, not one running in the background.
    public var mentionsServerRestart: Bool { status == .restartingServer && !quietServerRestart }

    /// The window's update chip, if it has something to say.
    public var chip: UpdateChip? {
        if let previewIndex { return UpdateChip.previews[previewIndex] }
        guard let host else { return nil }
        let server = host.localServerBuild
        let sessions = host.runningSessionCount
        let ready = prepared.flatMap { prepared -> UpdateChip.Ready? in
            guard prepared.version != dismissedReady, let server else { return nil }
            return UpdateChip.Ready(version: prepared.version, compatible: UpdateDecision.isCompatible(prepared.manifest, with: server))
        }
        var outdatedServer: String?
        if let version = server?.version, version != dismissedServer,
           UpdateDecision.isOutdated(serverVersion: version, appVersion: appVersion) {
            outdatedServer = version
        }
        let checking = manualCheck && (status == .checking || installation == nil)
        let offered = available.map(\.version).flatMap { $0 == dismissedAvailable ? nil : $0 }
        let showsDownload = downloadingVersion != dismissedDownload && !backgroundDownload
        let quiet = UpdateChip.Quiet(ready: readyInstallsItself, server: serverRestartsItself,
                                     serverRestart: quietServerRestart, install: quietInstall)
        return UpdateChip.make(status: status, notice: notice, checking: checking, showsDownload: showsDownload,
                               available: downloadingVersion == nil ? offered : nil, downloadHold: downloadHold,
                               ready: ready, relaunchWhenIdle: relaunchWhenIdle || settings.automaticInstall,
                               outdatedServer: outdatedServer, sessions: sessions, agents: host.runningAgentCount,
                               waitingForServer: server == nil && prepared?.version != dismissedReady ? prepared?.version : nil,
                               keepsTerminals: host.localServerKeepsTerminals, quiet: quiet)
    }

    /// Status and primary action for Settings → General → Updates.
    public var summary: UpdaterSummary {
        let app = Release.appName
        let current = "\(app) \(Release.version)"
        let idleReady = canRelaunchWhenIdle
        let idleArmed = relaunchWhenIdle || settings.automaticInstall
        switch status {
        case .unavailable(let reason):
            return UpdaterSummary(detail: "\(current) · \(reason)", buttonTitle: "Check for Updates", buttonEnabled: false)
        case .checking:
            return UpdaterSummary(detail: "\(current) · Checking for updates…", buttonTitle: "Checking…", buttonEnabled: false)
        case let .downloading(version, progress):
            let percent = progress.map { " \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return UpdaterSummary(detail: "Downloading \(app) \(version)…\(percent)", buttonTitle: "Downloading…", buttonEnabled: false)
        case .preparing(let version):
            return UpdaterSummary(detail: "Verifying \(app) \(version)…", buttonTitle: "Verifying…", buttonEnabled: false)
        case .installing(let version):
            return UpdaterSummary(detail: "Installing \(app) \(version)…", buttonTitle: "Installing…", buttonEnabled: false)
        case .installed(let version):
            return UpdaterSummary(detail: "\(app) \(version) is installed. Restart to open it.",
                                  buttonTitle: "Restart", buttonEnabled: true, action: .install)
        case .restartingServer:
            return UpdaterSummary(detail: "Restarting the local server…", buttonTitle: "Restarting…", buttonEnabled: false)
        case .ready(let version):
            let note = idleReady && idleArmed
                ? "\(app) \(version) is ready. It installs while you’re away, or when \(app) quits or is hidden."
                : "\(app) \(version) is ready. It installs when \(app) quits."
            return UpdaterSummary(detail: note, buttonTitle: "Restart to Update", buttonEnabled: host?.localServerBuild != nil,
                                  action: .install, canRelaunchWhenIdle: idleReady, relaunchWhenIdle: idleArmed)
        case .available(let version):
            let note: String
            switch downloadHold {
            case .lowDataMode?: note = "\(app) \(version) is available. Download paused in Low Data Mode."
            case .hotspot?: note = "\(app) \(version) is available. Download paused on hotspot."
            case nil: note = "\(app) \(version) is available."
            }
            return UpdaterSummary(detail: note, buttonTitle: "Download", buttonEnabled: true, action: .download)
        case .idle:
            var detail = current
            if let lastCheckDate {
                let formatted = Self.relativeDateFormatter.localizedString(for: lastCheckDate, relativeTo: Date())
                detail += " · Last checked \(formatted)."
            }
            if let systemNote { detail += " \(systemNote)" }
            return UpdaterSummary(detail: detail)
        }
    }

    /// What Settings → Server says about an outdated server, when it is.
    public var serverUpdateDetail: String? {
        guard let version = host?.localServerBuild?.version,
              UpdateDecision.isOutdated(serverVersion: version, appVersion: appVersion) else { return nil }
        guard serverRestartsItself else { return UpdateChip.serverUpdateMessage(version: version) }
        let app = Release.appName
        if let serverWork, !serverWork.isIdle {
            return "The server still runs \(app) \(version). It restarts on \(appVersion) once \(UpdateChip.waiting(for: serverWork)) finish, while you’re away. Terminals reopen where they were."
        }
        return "The server still runs \(app) \(version). It restarts on \(appVersion) while you’re away and nothing is working. Terminals reopen where they were."
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private weak var host: UpdaterHost?
    private let record: URL
    private let updatedMarker: URL
    private let quietRelaunchMarker: URL
    private let checkStateURL: URL
    private let serverStartupLock: URL
    private var downloader: UpdateDownloader
    private var installation: Installation?
    private var settings: UpdateSettings
    private var networkState = UpdateNetworkState.unconstrained
    private var networkMonitor: UpdateNetworkMonitor?
    private var automaticInstaller: AutomaticUpdateInstaller?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var replacingServer = false
    private var operations = UpdaterOperations()

    /// App termination must not cancel a bundle replacement in progress.
    var isInstalling: Bool {
        if case .installing = status { return true }
        return false
    }
    /// A check the person asked for is running or waits for the updater to start.
    private var manualCheck = false
    /// Whether the active download started automatically in the background.
    private var backgroundDownload = false
    /// Whether the last background check failed while offline, so coming back
    /// online should retry once automatically.
    private var needsOnlineCheck = false
    /// Server controls wait while an update is being installed or downloaded.
    var canRestartServer: Bool { !isBusy }

    var serverRestartFailure: String? {
        guard case .serverRestartFailed(let reason) = notice else { return nil }
        return "Couldn’t restart the server. \(UpdateChip.sentence(reason))"
    }

    private var notice: UpdateNotice? {
        didSet {
            guard notice != oldValue else { return }
            scheduleNoticeExpiry()
            host?.updaterDidChange()
        }
    }
    private var noticeTimer: Timer?
    private var serverRestartTimer: Timer?
    private var serverRestartAttempt: UUID?
    private var restartingInstance: UInt64?
    /// The server restart running now started in the background.
    private var quietServerRestart = false
    /// The install running now started in the background.
    private var quietInstall = false
    private var lastIdleRestartAttempt: Date?
    /// Background restarts the server refused in a row because work ran.
    private var idleRestartRefusals = 0
    /// When the downloaded release became ready.
    private var readySince: Date?
    /// The version a quiet relaunch installed, announced once Tab comes forward.
    private var pendingUpdatedNotice: String?
    private var downloadFailures = 0
    private var downloadRetryTimer: Timer?
    /// Someone put a newer Tab.app in place while this one ran.
    private var replacedOnDisk = false
    private var dismissedAvailable: String?
    private var dismissedReady: String?
    private var dismissedDownload: String?
    private var dismissedServer: String?
    /// The sample chip on show in debug builds, which never update.
    private var previewIndex: Int?

    /// - Parameters:
    ///   - dirs: the profile, which keeps the pending update record.
    ///   - settings: automatic download and idle install preferences.
    ///   - configuration: the session configuration for downloads, carrying
    ///     the app's proxy when it is used for the whole app.
    ///   - quietRelaunch: this launch is a relaunch into an update the
    ///     person didn't start, so its announcement waits for them.
    public init(
        host: UpdaterHost,
        dirs: TabDirs,
        settings: UpdateSettings = UpdateSettings(),
        configuration: URLSessionConfiguration = .ephemeral,
        quietRelaunch: Bool = false
    ) {
        self.host = host
        self.settings = settings
        record = dirs.root.appendingPathComponent("pending-update.json")
        updatedMarker = dirs.root.appendingPathComponent("updated-to")
        quietRelaunchMarker = dirs.root.appendingPathComponent("quiet-relaunch")
        checkStateURL = dirs.root.appendingPathComponent("update-check-state.json")
        serverStartupLock = dirs.root.appendingPathComponent("server.startup-lock")
        downloader = UpdateDownloader(configuration: configuration)
        lastCheckDate = UpdateCheckState.load(from: checkStateURL)
        self.quietRelaunch = quietRelaunch
        appVersion = Release.version
        configureAutomation(settleDelay: AutomaticUpdateInstaller.defaultSettleDelay)
    }

    init(
        host: UpdaterHost,
        dirs: TabDirs,
        prepared: PreparedUpdate? = nil,
        installation: Installation? = nil,
        settings: UpdateSettings = UpdateSettings(),
        settleDelay: TimeInterval = AutomaticUpdateInstaller.defaultSettleDelay,
        appVersion: String = Release.version,
        operations: UpdaterOperations
    ) {
        self.appVersion = appVersion
        self.host = host
        self.settings = settings
        record = dirs.root.appendingPathComponent("pending-update.json")
        updatedMarker = dirs.root.appendingPathComponent("updated-to")
        quietRelaunchMarker = dirs.root.appendingPathComponent("quiet-relaunch")
        checkStateURL = dirs.root.appendingPathComponent("update-check-state.json")
        serverStartupLock = dirs.root.appendingPathComponent("server.startup-lock")
        downloader = UpdateDownloader()
        self.installation = installation ?? prepared?.installation
        self.prepared = prepared
        self.operations = operations
        quietRelaunch = false
        if let prepared {
            status = .ready(version: prepared.version)
            readySince = Date()
        }
        configureAutomation(settleDelay: settleDelay)
    }

    private let quietRelaunch: Bool
    /// This app's version, which tests choose.
    private let appVersion: String

    private func configureAutomation(settleDelay: TimeInterval) {
        let installer = AutomaticUpdateInstaller(
            settleDelay: settleDelay,
            evaluate: { [weak self] in
                guard let self else { return .noUpdateReady }
                return self.quietWorkObstacle()
            },
            onTrigger: { [weak self] in self?.runQuietWork() }
        )
        installer.onWake = { [weak self] in self?.cameForward() }
        automaticInstaller = installer
    }

    /// Applies updated automation preferences from Settings.
    public func setSettings(_ newSettings: UpdateSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        maybeStartAutomaticDownload()
        automaticInstaller?.reevaluate()
        host?.updaterDidChange()
    }

    /// Arms a one-shot quiet relaunch for the ready update once Tab is hidden.
    public func scheduleRelaunchWhenIdle() {
        guard canRelaunchWhenIdle, !isBusy else { return }
        relaunchWhenIdle = true
        automaticInstaller?.startObserving()
        automaticInstaller?.reevaluate()
        host?.updaterDidChange()
    }

    /// Uses a new session configuration, such as after the proxy changed.
    public func setSessionConfiguration(_ configuration: URLSessionConfiguration) {
        downloader = UpdateDownloader(configuration: configuration)
    }

    /// Finds the installation, restores a pending update, checks now and
    /// every hour. Debug builds and apps not signed with a Developer ID
    /// never check.
    public func start() {
        guard installation == nil, task == nil else { return }
        let record = record
        let updatedMarker = updatedMarker
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<(Installation, PreparedUpdate?, String?), UpdateError> in
                do {
                    let installation = try Installation.detect()
                    let pending = PendingUpdateRecord.restore(record, installation: installation)
                    installation.cleanUp(keeping: pending?.staging)
                    return .success((installation, pending, UpdatedMarker.take(updatedMarker)))
                } catch let error as UpdateError {
                    return .failure(error)
                } catch {
                    return .failure(.unavailable(error.localizedDescription))
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            switch result {
            case .failure(let error):
                self.status = .unavailable(error.description)
                Log.updates.info("updates unavailable: \(error.description, privacy: .public)")
                if self.manualCheck {
                    self.manualCheck = false
                    self.notice = .unavailable(error.description)
                }
            case .success(let (installation, pending, updated)):
                self.installation = installation
                self.prepared = pending
                if pending != nil { self.readySince = PendingUpdateRecord.preparedAt(record) ?? Date() }
                if let updated { self.announceUpdate(updated) }
                self.refreshStatus()
                self.startMonitors()
                self.check()
                self.timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                }
                self.timer?.tolerance = 600
                self.reconcile()
            }
        }
    }

    /// Says which version was installed: now, or once a quiet relaunch's
    /// Tab comes forward, so the note isn't gone before the person sees it.
    private func announceUpdate(_ version: String) {
        if quietRelaunch, host?.automaticInstallEnvironment.isAppActive != true {
            pendingUpdatedNotice = version
        } else {
            notice = .updated(version: version)
        }
    }

    private func startMonitors() {
        if networkMonitor == nil {
            let monitor = UpdateNetworkMonitor { [weak self] state in
                self?.networkStateDidChange(state)
            }
            networkMonitor = monitor
            monitor.start()
        }
        automaticInstaller?.startObserving()
        automaticInstaller?.reevaluate()
    }

    /// Stops background checks and observers.
    public func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        noticeTimer?.invalidate()
        serverRestartTimer?.invalidate()
        downloadRetryTimer?.invalidate()
        downloadRetryTimer = nil
        networkMonitor?.stop()
        networkMonitor = nil
        automaticInstaller?.stop()
    }

    /// Reacts to network changes: resumes paused background downloads once the
    /// network is unconstrained, and retries a failed offline check when online.
    func networkStateDidChange(_ state: UpdateNetworkState) {
        let wasOnline = networkState.isOnline
        guard state != networkState else { return }
        networkState = state
        if state.isOnline, !wasOnline, needsOnlineCheck, !isBusy, installation != nil {
            needsOnlineCheck = false
            check()
            return
        }
        maybeStartAutomaticDownload()
    }

    /// Re-evaluates whether an armed quiet relaunch can start now.
    func reevaluateAutomaticInstall() {
        automaticInstaller?.reevaluate()
    }

    /// Tab came forward or the Mac woke: an overdue check runs, a Tab.app
    /// replaced meanwhile is noticed, and a deferred announcement shows.
    func cameForward() {
        if let version = pendingUpdatedNotice, host?.automaticInstallEnvironment.isAppActive == true {
            pendingUpdatedNotice = nil
            notice = .updated(version: version)
        }
        guard let installation, !isBusy else { return }
        if let onDisk = Self.versionOnDisk(installation), ReleaseVersion.isNewer(onDisk, than: Release.version) {
            replacedOnDisk = true
            status = .installed(version: onDisk)
            return
        }
        if lastCheckDate.map({ Date().timeIntervalSince($0) >= Self.checkInterval }) ?? true { check() }
    }

    /// The version of the app at the installation's path, which may be newer
    /// than this process if someone replaced it.
    nonisolated static func versionOnDisk(_ installation: Installation) -> String? {
        guard let info = NSDictionary(contentsOf: installation.bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else { return nil }
        return Release.version(ofBundle: info)
    }

    /// Check for Updates…: checks now and reports on the chip, bringing
    /// back whatever it had hidden.
    public func checkForUpdates() {
        dismissedAvailable = nil
        dismissedReady = nil
        dismissedDownload = nil
        dismissedServer = nil
        switch status {
        case .installing, .installed, .restartingServer, .downloading, .preparing:
            backgroundDownload = false
            host?.updaterDidChange()
            return
        case .unavailable(let reason):
            notice = .unavailable(reason)
            host?.updaterDidChange()
            return
        default:
            break
        }
        notice = nil
        manualCheck = true
        host?.updaterDidChange()
        guard installation != nil else { return }
        check()
    }

    /// Closes the chip: a confirmation goes back to what it asked about, a
    /// download carries on out of view, and an available or ready release or
    /// an outdated server stays hidden until something newer or a check the person asks for.
    public func dismissChip() {
        if previewIndex != nil {
            previewIndex = nil
            host?.updaterDidChange()
            return
        }
        guard let dismissal = chip?.dismissal else { return }
        switch dismissal {
        case .notice: notice = nil
        case .download(let version): dismissedDownload = version
        case .available(let version): dismissedAvailable = version
        case .ready(let version): dismissedReady = version
        case .server(let version): dismissedServer = version
        }
        host?.updaterDidChange()
    }

    /// Runs the chip's button.
    public func handle(_ action: UpdateChip.Action) {
        if previewIndex != nil {
            previewNextChip()
            return
        }
        if status == .checking {
            switch action {
            case .download, .update, .restartServer, .endTerminalsAndUpdate, .endTerminalsAndRestartServer,
                 .updateStoppingWork, .restartServerStoppingWork:
                task?.cancel()
                task = nil
                manualCheck = false
                refreshStatus()
            default: break
            }
        }
        switch action {
        case .download:
            download()
        case .update:
            update()
        case .endTerminalsAndUpdate:
            install(.endTerminals)
        case .updateStoppingWork:
            install(.restartServer(onlyWhenIdle: false))
        case .restartServer:
            guard !isBusy else { return }
            dismissedServer = nil
            if host?.localServerKeepsTerminals == true {
                restartServer(keepingTerminals: true, onlyWhenIdle: true)
            } else {
                notice = .confirmServerRestart
            }
        case .endTerminalsAndRestartServer:
            restartServer(keepingTerminals: false, onlyWhenIdle: false)
        case .restartServerStoppingWork:
            restartServer(keepingTerminals: true, onlyWhenIdle: false)
        case .checkAgain:
            checkForUpdates()
        case .showChangelog:
            notice = nil
        }
    }

    /// Shows the next sample of every chip state, for debug builds: a
    /// chip's button steps on, and closing it ends the preview.
    public func previewNextChip() {
        previewIndex = ((previewIndex ?? -1) + 1) % UpdateChip.previews.count
        host?.updaterDidChange()
    }

    /// Call when the local server connects, or its sessions or activity
    /// change: a server restart finishes once the new build answers, and an
    /// older server left running by an earlier update is replaced once idle.
    public func reconcile() {
        guard let host else { return }
        if status == .restartingServer {
            guard let instance = host.localServerInstance, instance != restartingInstance,
                  let build = host.localServerBuild,
                  !UpdateDecision.isOutdated(serverVersion: build.version, appVersion: appVersion) else { return }
            serverRestartTimer?.invalidate()
            serverRestartAttempt = nil
            task = nil
            let quiet = quietServerRestart
            quietServerRestart = false
            serverWork = nil
            idleRestartRefusals = 0
            refreshStatus()
            if !quiet { notice = .serverRestarted(version: build.version) }
            automaticInstaller?.reevaluate()
            return
        }
        // An outdated server nothing needs is replaced at once.
        guard !isBusy, host.localServerBuild != nil, !replacingServer,
              host.runningAgentCount == 0,
              UpdateDecision.shouldReplaceServer(serverVersion: host.localServerBuild?.version, appVersion: appVersion,
                                                 sessions: host.runningSessionCount)
        else {
            automaticInstaller?.reevaluate()
            return
        }
        replacingServer = true
        Task { [weak self] in
            _ = await host.stopLocalServerIfIdle()
            self?.replacingServer = false
        }
    }

    // MARK: Checking

    private var isBusy: Bool {
        switch status {
        case .checking, .downloading, .preparing, .installing, .installed, .restartingServer: return true
        default: return false
        }
    }

    private var downloadingVersion: String? {
        switch status {
        case .downloading(let version, _), .preparing(let version): return version
        default: return nil
        }
    }

    /// Asks the feed for a newer release; downloading waits for the person.
    private func check() {
        guard !isBusy, installation != nil else { return }
        status = .checking
        let downloader = downloader
        let operations = operations
        task = Task { [weak self] in
            let result: Result<UpdateManifest?, Error>
            do {
                result = .success(try await operations.latest(downloader))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finishCheck(result)
        }
    }

    /// The feed's release when it replaces the downloaded one, if any. A
    /// stale feed must not move a download back.
    nonisolated static func newerRelease(_ latest: UpdateManifest?, than downloaded: String?) -> UpdateManifest? {
        guard let latest else { return nil }
        guard let downloaded else { return latest }
        return ReleaseVersion.isNewer(latest.version, than: downloaded) ? latest : nil
    }

    private func finishCheck(_ result: Result<UpdateManifest?, Error>) {
        task = nil
        let manual = manualCheck
        manualCheck = false
        switch result {
        case .failure(UpdateError.systemTooOld(let version, let minimum)):
            // Not a failure: this Mac stays on the release it can run.
            recordCheck()
            systemNote = UpdateError.systemTooOld(version: version, minimum: minimum).description
            refreshStatus()
            if manual { notice = .unavailable(systemNote ?? "") }
        case .failure(let error):
            Log.updates.error("update check failed: \(String(describing: error), privacy: .public)")
            if !networkState.isOnline || Self.isOfflineError(error) { needsOnlineCheck = true }
            refreshStatus()
            if manual { notice = .checkFailed(UpdateChip.reason(error)) }
        case .success(let latest):
            needsOnlineCheck = false
            systemNote = nil
            recordCheck()
            if case .checkFailed = notice { notice = nil }
            let next = Self.newerRelease(latest, than: prepared?.version)
            if next?.version != available?.version { downloadFailures = 0 }
            available = next
            refreshStatus()
            if manual, available == nil, prepared == nil { notice = .upToDate(version: Release.version) }
            if available != nil { maybeStartAutomaticDownload() }
        }
        host?.updaterDidChange()
        reconcile()
    }

    private func recordCheck() {
        let now = Date()
        lastCheckDate = now
        UpdateCheckState.save(now, to: checkStateURL)
    }

    private static func isOfflineError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return true
        default: return false
        }
    }

    private var wantsAutomaticDownload: Bool {
        settings.automaticDownloads || settings.automaticInstall
    }

    /// Starts downloading `available` in the background when enabled and the
    /// network is neither in Low Data Mode nor on a hotspot; records the hold
    /// otherwise.
    private func maybeStartAutomaticDownload() {
        guard available != nil, installation != nil, !isBusy else {
            if available == nil, downloadHold != nil {
                downloadHold = nil
                host?.updaterDidChange()
            }
            return
        }
        guard wantsAutomaticDownload else {
            if downloadHold != nil {
                downloadHold = nil
                host?.updaterDidChange()
            }
            return
        }
        if let hold = networkState.hold {
            if downloadHold != hold {
                downloadHold = hold
                host?.updaterDidChange()
            }
            return
        }
        guard networkState.isOnline, downloadRetryTimer == nil else { return }
        downloadHold = nil
        download(automatic: true)
    }

    /// Downloads and verifies the available release in the background.
    /// Manual downloads always show progress and bypass Low Data Mode / hotspot
    /// holds; automatic downloads stay quiet until ready.
    private func download(automatic: Bool = false) {
        guard let manifest = available, let installation, !isBusy else { return }
        if !automatic {
            downloadRetryTimer?.invalidate()
            downloadRetryTimer = nil
        }
        let downloader = downloader
        let operations = operations
        let version = manifest.version
        downloadHold = nil
        backgroundDownload = automatic
        if !automatic { notice = nil }
        status = .downloading(version: version, progress: manifest.size == nil ? nil : 0)
        task = Task { [weak self] in
            let result: Result<PreparedUpdate, Error>
            do {
                let prepared = try await operations.downloadAndPrepare(
                    downloader, manifest, installation,
                    { fraction in Task { @MainActor in self?.downloadProgressed(version, fraction) } },
                    { Task { @MainActor in self?.downloadPreparing(version) } }
                )
                try Task.checkCancellation()
                result = .success(prepared)
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else {
                if case .success(let update) = result { Task.detached(priority: .utility) { update.discard() } }
                return
            }
            self?.finishDownload(result, version: version, automatic: automatic)
        }
    }

    private func downloadProgressed(_ version: String, _ fraction: Double) {
        guard case .downloading(version, _) = status else { return }
        status = .downloading(version: version, progress: fraction)
    }

    private func downloadPreparing(_ version: String) {
        guard case .downloading(version, _) = status else { return }
        status = .preparing(version: version)
    }

    private func finishDownload(_ result: Result<PreparedUpdate, Error>, version: String, automatic: Bool) {
        task = nil
        let wasBackground = backgroundDownload
        backgroundDownload = false
        switch result {
        case .failure(let error):
            Log.updates.error("update download failed: \(String(describing: error), privacy: .public)")
            refreshStatus()
            if !automatic || !wasBackground {
                notice = .downloadFailed(version: version, reason: UpdateChip.reason(error))
            } else {
                scheduleDownloadRetry()
            }
        case .success(let update):
            if let previous = prepared, previous.staging != update.staging {
                Task.detached(priority: .utility) { previous.discard() }
            }
            prepared = update
            readySince = Date()
            downloadFailures = 0
            if available?.version == update.version { available = nil }
            dismissedReady = nil
            PendingUpdateRecord.save(update, to: record)
            refreshStatus()
            automaticInstaller?.reevaluate()
        }
        host?.updaterDidChange()
        reconcile()
    }

    /// A background download that failed tries again later, waiting longer
    /// each time, without a word unless the person asks.
    private func scheduleDownloadRetry() {
        let delay = Self.downloadRetryDelays[min(downloadFailures, Self.downloadRetryDelays.count - 1)]
        downloadFailures += 1
        downloadRetryTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.downloadRetryTimer = nil
                self?.maybeStartAutomaticDownload()
            }
        }
        timer.tolerance = delay / 10
        downloadRetryTimer = timer
    }

    private func refreshStatus() {
        quietInstall = false
        if let available {
            status = .available(version: available.version)
        } else {
            status = prepared.map { .ready(version: $0.version) } ?? .idle
        }
    }

    private func scheduleNoticeExpiry() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        guard let notice, let lifetime = notice.lifetime else { return }
        noticeTimer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.notice == notice else { return }
                self.notice = nil
            }
        }
    }

    // MARK: Quiet work

    /// Whether the ready release can install without asking anyone: the
    /// running server stays, or restarts keeping its terminals.
    private var installServerReady: Bool {
        guard let prepared, let host else { return false }
        if UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) { return true }
        return host.localServerBuild != nil && host.localServerKeepsTerminals && settings.automaticServerRestart
    }

    /// The ready release installs by itself, so it goes unmentioned for a while.
    private var readyInstallsItself: Bool {
        guard settings.automaticInstall || relaunchWhenIdle, installServerReady else { return false }
        return Date().timeIntervalSince(readySince ?? Date()) < Self.readyReminderDelay
    }

    /// The outdated server restarts by itself once nothing works, so it goes unmentioned.
    private var serverRestartsItself: Bool {
        settings.automaticServerRestart && host?.localServerKeepsTerminals == true
    }

    private func installObstacle() -> AutomaticInstallObstacle? {
        guard !isBusy, let host else { return .noUpdateReady }
        let environment = host.automaticInstallEnvironment
        if let obstacle = AutomaticUpdateInstaller.obstacle(
            enabled: settings.automaticInstall || relaunchWhenIdle,
            hasReadyUpdate: prepared != nil && host.localServerBuild != nil,
            serverCompatible: installServerReady,
            environment: environment
        ) { return obstacle }
        // Installing restarts the server too: the same care as restarting it alone.
        if let prepared, !UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) {
            return serverQuietObstacle(environment)
        }
        return nil
    }

    /// What keeps a background server restart from going unnoticed: terminals
    /// reopen with new shells, so the person must be away or have Tab put
    /// away, not just covered; agents at work and a server that just said it
    /// was busy hold it off too.
    private func serverQuietObstacle(_ environment: AutomaticInstallEnvironment) -> AutomaticInstallObstacle? {
        guard environment.isPersonAway || !environment.hasOpenWindow else { return .windowVisible }
        guard (host?.workingAgentCount ?? 0) == 0 else { return .workRunning }
        if let last = lastIdleRestartAttempt, idleRestartRefusals > 0 {
            let delay = Self.idleRestartDelays[min(idleRestartRefusals - 1, Self.idleRestartDelays.count - 1)]
            if Date().timeIntervalSince(last) < delay { return .workRunning }
        }
        return nil
    }

    /// The server said what work keeps it from restarting; ask again later.
    private func serverRefusedRestart(_ work: ServerWork) {
        lastIdleRestartAttempt = Date()
        idleRestartRefusals += 1
        serverWork = work
        Log.updates.info("server restart waits for \(UpdateChip.waiting(for: work), privacy: .public)")
        host?.updaterDidChange()
    }

    /// What keeps an outdated server from restarting in the background now.
    private func serverRestartObstacle() -> AutomaticInstallObstacle? {
        guard settings.automaticServerRestart else { return .automationOff }
        guard !isBusy, !replacingServer, let host, host.localServerKeepsTerminals,
              let version = host.localServerBuild?.version,
              UpdateDecision.isOutdated(serverVersion: version, appVersion: appVersion) else { return .noUpdateReady }
        return serverQuietObstacle(host.automaticInstallEnvironment)
    }

    private func quietWorkObstacle() -> AutomaticInstallObstacle? {
        guard let install = installObstacle() else { return nil }
        guard let server = serverRestartObstacle() else { return nil }
        // An obstacle the person can clear keeps the idle-time watch going.
        switch install {
        case .automationOff, .noUpdateReady, .incompatibleServer: return server
        default: return install
        }
    }

    private func runQuietWork() {
        if installObstacle() == nil {
            install(installMode(quiet: true), quiet: true)
        } else if serverRestartObstacle() == nil {
            restartServerQuietly()
        }
    }

    /// Asks the outdated server to restart if no work runs; it says what
    /// does otherwise, and the next quiet moment asks again.
    private func restartServerQuietly() {
        guard let host, !isBusy else { return }
        lastIdleRestartAttempt = Date()
        // Busy before asking, so no check or install starts meanwhile.
        let attempt = beginServerRestart(quiet: true)
        task = Task { [weak self] in
            do {
                guard let work = try await host.restartLocalServerKeepingTerminals(onlyWhenIdle: true) else { return }
                guard self?.serverRestartAttempt == attempt else { return }
                self?.cancelServerRestart()
                self?.serverRefusedRestart(work)
            } catch {
                guard self?.serverRestartAttempt == attempt else { return }
                Log.updates.error("background server restart failed: \(String(describing: error), privacy: .public)")
                self?.cancelServerRestart()
                // Asked again later, waiting longer each time, as when busy.
                self?.idleRestartRefusals += 1
                self?.lastIdleRestartAttempt = Date()
            }
        }
    }

    // MARK: Installing

    private enum InstallMode: Equatable {
        /// The running server keeps its terminals until it restarts by itself.
        case keepServer
        /// Stops the server only if no terminal started meanwhile.
        case stopIdleServer
        /// Ends every terminal; the person agreed.
        case endTerminals
        /// Restarts the server keeping its terminals; with `onlyWhenIdle`,
        /// only if no work runs.
        case restartServer(onlyWhenIdle: Bool)
    }

    private func installMode(quiet: Bool) -> InstallMode {
        guard let prepared, let host, !UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild)
        else { return .keepServer }
        return host.localServerKeepsTerminals ? .restartServer(onlyWhenIdle: true) : .stopIdleServer
    }

    private func update() {
        if case .installed = status {
            if replacedOnDisk, let installation {
                try? PreparedUpdate.relaunch(installation.bundle, after: getpid())
            }
            host?.quitForUpdate()
            return
        }
        guard let prepared, let host, let server = host.localServerBuild else { return }
        let compatible = UpdateDecision.isCompatible(prepared.manifest, with: server)
        switch UpdateDecision.step(compatible: compatible, keepsTerminals: host.localServerKeepsTerminals,
                                   sessions: host.runningSessionCount, agents: host.runningAgentCount) {
        case .install: install(.keepServer)
        case .installStoppingIdleServer: install(.stopIdleServer)
        case .installRestartingServer: install(.restartServer(onlyWhenIdle: true))
        case .confirmEndingTerminals: notice = .confirmUpdate
        }
    }

    private func installQuietly() {
        guard installObstacle() == nil else { return }
        install(installMode(quiet: true), quiet: true)
    }

    /// Installs the ready release as Tab quits, without relaunching it: the
    /// next launch opens the new version. Restarts an outdated server that
    /// keeps its terminals too, when nothing works on it. Returns once done.
    public func prepareForQuit() async {
        guard !isInstalling, let host else { return }
        if case .downloading = status { task?.cancel(); task = nil; refreshStatus() }
        if case .checking = status { task?.cancel(); task = nil; refreshStatus() }
        if prepared != nil, host.localServerBuild != nil, !isBusy, settings.automaticInstall || relaunchWhenIdle {
            await installNow(installMode(quiet: true), relaunch: .none)
            return
        }
        guard serverRestartsItself, !isBusy, let version = host.localServerBuild?.version,
              UpdateDecision.isOutdated(serverVersion: version, appVersion: appVersion),
              host.workingAgentCount == 0 else { return }
        do {
            if try await host.restartLocalServerKeepingTerminals(onlyWhenIdle: true) == nil {
                // Agents and paired devices keep a server while Tab is closed.
                host.startLocalServer()
            }
        } catch {
            Log.updates.error("server restart at quit failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces the app and relaunches.
    private func install(_ mode: InstallMode, quiet: Bool = false) {
        let presentation = host?.automaticInstallEnvironment.presentation ?? .hidden
        let relaunch: PreparedUpdate.Relaunch = quiet ? .quietly(presentation) : .open
        guard beginInstall(quiet: quiet) else { return }
        task = Task { [weak self] in await self?.performInstall(mode, relaunch: relaunch) }
    }

    /// Installs now and returns once done, such as while quitting.
    private func installNow(_ mode: InstallMode, relaunch: PreparedUpdate.Relaunch) async {
        guard beginInstall(quiet: relaunch != .open) else { return }
        await performInstall(mode, relaunch: relaunch)
    }

    /// Shows the install as started, unless one can't start now.
    private func beginInstall(quiet: Bool) -> Bool {
        guard let prepared, let host, !isBusy, host.localServerBuild != nil else { return false }
        automaticInstaller?.cancelSettle()
        notice = nil
        quietInstall = quiet
        status = .installing(version: prepared.version)
        return true
    }

    private func performInstall(_ mode: InstallMode, relaunch: PreparedUpdate.Relaunch) async {
        guard let prepared, let host else { return refreshStatus() }
        let quiet = relaunch != .open
        let record = record
        let updatedMarker = updatedMarker
        let quietRelaunchMarker = quietRelaunchMarker
        let serverStartupLock = serverStartupLock
        let operations = operations
        do {
            guard try await host.prepareToQuitForUpdate() else {
                task = nil
                refreshStatus()
                if !quiet { notice = .unsavedEditors }
                return
            }
            try Task.checkCancellation()
            let lease = try await Task.detached(priority: .userInitiated) {
                try FileLock.tryLock(serverStartupLock)
            }.value
            defer { lease.unlock() }
            do {
                try await Task.detached(priority: .userInitiated) { try operations.validate(prepared) }.value
            } catch {
                self.prepared = nil
                if available == nil { available = prepared.manifest }
                try? FileManager.default.removeItem(at: record)
                Task.detached(priority: .utility) { prepared.discard() }
                throw error
            }
            try Task.checkCancellation()
            var restartedServer = false
            switch mode {
            case .keepServer:
                // The server may have been replaced by an older one since the person chose.
                guard UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) else {
                    task = nil
                    refreshStatus()
                    return
                }
            case .stopIdleServer:
                // A terminal started meanwhile: the chip asks again.
                guard await host.stopLocalServerIfIdle() else {
                    task = nil
                    refreshStatus()
                    if !quiet {
                        notice = .installFailed("The server is busy with terminals or agents, or could not be reached. Try again once it is idle.")
                    }
                    return
                }
            case .endTerminals:
                if !UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) {
                    try await host.endAllSessions()
                }
            case .restartServer(let onlyWhenIdle):
                if !UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) {
                    if let work = try await host.restartLocalServerKeepingTerminals(onlyWhenIdle: onlyWhenIdle) {
                        task = nil
                        refreshStatus()
                        if quiet { serverRefusedRestart(work) } else { serverWork = work }
                        if !quiet { notice = .confirmUpdateStopping(work) }
                        return
                    }
                    restartedServer = true
                }
            }
            let quietMarker = relaunch == .none ? nil : (quiet ? quietRelaunchMarker : nil)
            let presentation: RelaunchPresentation? = if case .quietly(let shown) = relaunch { shown } else { nil }
            try await Task.detached(priority: .userInitiated) {
                if let quietMarker, let presentation { QuietRelaunchMarker.save(presentation, to: quietMarker) }
                do {
                    try operations.install(prepared, relaunch)
                } catch {
                    if let quietMarker { try? FileManager.default.removeItem(at: quietMarker) }
                    throw error
                }
                try? FileManager.default.removeItem(at: record)
                UpdatedMarker.save(prepared.version, to: updatedMarker)
            }.value
            self.prepared = nil
            available = nil
            relaunchWhenIdle = false
            task = nil
            status = .installed(version: prepared.version)
            // Without a relaunch, nothing would bring the new server up for
            // agents and paired devices while Tab is closed.
            if restartedServer, relaunch == .none { host.startLocalServer() }
            if relaunch != .none { host.quitForUpdate() }
        } catch {
            task = nil
            Log.updates.error("could not install the update: \(String(describing: error), privacy: .public)")
            refreshStatus()
            if !quiet {
                notice = .installFailed(UpdateChip.reason(error))
            }
        }
    }

    // MARK: Server

    /// Restarts the outdated local server on this app's build. Keeping its
    /// terminals, a restart that would stop work asks first; otherwise the
    /// person already agreed to end them. The chip shows the restart until
    /// the new build answers.
    private func restartServer(keepingTerminals: Bool, onlyWhenIdle: Bool) {
        guard let host, !isBusy else { return }
        notice = nil
        let attempt = beginServerRestart(quiet: false)
        task = Task { [weak self] in
            do {
                if keepingTerminals {
                    if let work = try await host.restartLocalServerKeepingTerminals(onlyWhenIdle: onlyWhenIdle) {
                        guard self?.serverRestartAttempt == attempt else { return }
                        self?.cancelServerRestart()
                        self?.serverWork = work
                        self?.notice = .confirmServerRestartStopping(work)
                    }
                } else {
                    try await host.restartLocalServer()
                }
            } catch {
                guard !Task.isCancelled, self?.serverRestartAttempt == attempt else { return }
                self?.serverRestartFailed(UpdateChip.reason(error))
            }
        }
    }

    /// Waits for the restarted server's new build to answer.
    @discardableResult
    private func beginServerRestart(quiet: Bool) -> UUID {
        let attempt = UUID()
        serverRestartAttempt = attempt
        restartingInstance = host?.localServerInstance
        quietServerRestart = quiet
        status = .restartingServer
        serverRestartTimer?.invalidate()
        serverRestartTimer = Timer.scheduledTimer(withTimeInterval: Self.serverRestartTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.serverRestartAttempt == attempt else { return }
                self?.serverRestartFailed("The server didn’t come back in time.")
            }
        }
        // A restart quicker than the connection noticed is caught here too.
        reconcile()
        return attempt
    }

    private func cancelServerRestart() {
        serverRestartTimer?.invalidate()
        serverRestartAttempt = nil
        quietServerRestart = false
        refreshStatus()
    }

    private func serverRestartFailed(_ reason: String) {
        guard status == .restartingServer else { return }
        let quiet = quietServerRestart
        serverRestartTimer?.invalidate()
        serverRestartAttempt = nil
        quietServerRestart = false
        task?.cancel()
        task = nil
        refreshStatus()
        notice = .serverRestartFailed(quiet ? "It was restarting on \(Release.appName) \(appVersion). \(reason)" : reason)
    }
}

/// `updated-to`: the version just installed, so its first launch can say so.
enum UpdatedMarker {
    static func save(_ version: String, to url: URL) {
        try? AtomicFile.write(Data(version.utf8), to: url)
    }

    /// The version just installed when it is this build, and forgets it.
    static func take(_ url: URL, current: String = Release.version) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return version == current ? version : nil
    }
}

/// `pending-update.json`: the downloaded release, so a restart keeps it.
enum PendingUpdateRecord {
    struct Stored: Codable {
        var manifest: UpdateManifest
        var staging: String
        /// Written for older builds, which waited for terminals to end when set.
        var scheduled: Bool?
        /// When the download became ready.
        var preparedAt: Date?
    }

    static func save(_ update: PreparedUpdate, to url: URL, at date: Date = Date()) {
        let stored = Stored(manifest: update.manifest, staging: update.staging.path, scheduled: false, preparedAt: date)
        do {
            try AtomicFile.write(JSONEncoder().encode(stored), to: url)
        } catch {
            Log.updates.error("could not save the pending update: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// When the pending update became ready, if the record says.
    static func preparedAt(_ url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Stored.self, from: data))?.preparedAt
    }

    /// The pending update when it is still newer than this build and its
    /// staged app is still intact; anything else is forgotten.
    static func restore(_ url: URL, installation: Installation) -> PreparedUpdate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              ReleaseVersion.isNewer(stored.manifest.version, than: Release.version)
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let update = PreparedUpdate(manifest: stored.manifest, installation: installation,
                                    staging: URL(fileURLWithPath: stored.staging, isDirectory: true))
        do {
            try update.validate()
        } catch {
            update.discard()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return update
    }
}

/// `quiet-relaunch`: written right before an automatic relaunch so the
/// next launch comes back as Tab was — in front, behind other apps, or
/// hidden — instead of stealing focus.
public enum QuietRelaunchMarker {
    public static func save(_ presentation: RelaunchPresentation = .hidden, to url: URL) {
        try? AtomicFile.write(Data(presentation.rawValue.utf8), to: url)
    }

    /// How this launch should show itself when it was a quiet relaunch, and
    /// forgets it. Markers from older builds mean hidden.
    public static func take(_ url: URL) -> RelaunchPresentation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return RelaunchPresentation(rawValue: text) ?? .hidden
    }
}

/// `update-check-state.json`: remembers when Tab last checked for updates so
/// Settings can show it across launches.
enum UpdateCheckState {
    struct Stored: Codable {
        var lastCheckDate: Date
    }

    static func save(_ date: Date, to url: URL) {
        guard let data = try? JSONEncoder().encode(Stored(lastCheckDate: date)) else { return }
        try? AtomicFile.write(data, to: url)
    }

    static func load(from url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return stored.lastCheckDate
    }
}

/// External work, separated from orchestration for failure-path tests.
struct UpdaterOperations {
    var latest: @Sendable (UpdateDownloader) async throws -> UpdateManifest? = { try await $0.latest() }
    var downloadAndPrepare: @Sendable (
        UpdateDownloader, UpdateManifest, Installation,
        @escaping @Sendable (Double) -> Void, @escaping @Sendable () -> Void
    ) async throws -> PreparedUpdate = { downloader, manifest, installation, onProgress, onPreparing in
        try UpdateDownloader.checkSpace(for: manifest, in: [FileManager.default.temporaryDirectory, installation.directory])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try await downloader.download(manifest, into: folder, progress: onProgress)
        try Task.checkCancellation()
        onPreparing()
        return try await Task.detached(priority: .utility) {
            try installation.prepare(archive: archive, manifest: manifest)
        }.value
    }
    var validate: @Sendable (PreparedUpdate) throws -> Void = { try $0.validate() }
    var install: @Sendable (PreparedUpdate, PreparedUpdate.Relaunch) throws -> Void = { try $0.install(relaunch: $1) }
}
