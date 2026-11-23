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
    /// Stops the local server, ending every terminal on it.
    func endAllSessions() async throws
    /// Stops the local server only when no terminal runs; returns whether it stops.
    func stopLocalServerIfIdle() async -> Bool
    /// Restarts the local server on this app's build, ending every terminal on it.
    func restartLocalServer() async throws
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

/// Checks GitHub Releases for a new Tab and offers it on the window's
/// update chip. Update downloads and verifies it in the background; Restart
/// installs it: right away when the new
/// version speaks the running server's protocol or no terminal runs (the
/// old server keeps its terminals until it is idle or restarted), otherwise
/// after the person agrees to end every terminal.
@MainActor
public final class UpdaterController {
    /// Background checks run at launch and then this often.
    public static let checkInterval: TimeInterval = 60 * 60
    /// How long a server restart may take before it counts as failed.
    static let serverRestartTimeout: TimeInterval = 30

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

    /// Whether the current ready update can be scheduled for quiet idle relaunch.
    public var canRelaunchWhenIdle: Bool {
        guard let prepared, let server = host?.localServerBuild else { return false }
        return UpdateDecision.isCompatible(prepared.manifest, with: server)
    }

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
           UpdateDecision.isOutdated(serverVersion: version, appVersion: Release.version) {
            outdatedServer = version
        }
        let checking = manualCheck && (status == .checking || installation == nil)
        let offered = available.map(\.version).flatMap { $0 == dismissedAvailable ? nil : $0 }
        let showsDownload = downloadingVersion != dismissedDownload && !backgroundDownload
        return UpdateChip.make(status: status, notice: notice, checking: checking, showsDownload: showsDownload,
                               available: downloadingVersion == nil ? offered : nil, downloadHold: downloadHold,
                               ready: ready, relaunchWhenIdle: relaunchWhenIdle || settings.automaticInstall,
                               outdatedServer: outdatedServer, sessions: sessions, agents: host.runningAgentCount,
                               waitingForServer: server == nil && prepared?.version != dismissedReady ? prepared?.version : nil)
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
                ? "\(app) \(version) is ready and will install when \(app) is hidden."
                : "\(app) \(version) is ready to install."
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
            if let lastCheckDate {
                let formatted = Self.relativeDateFormatter.localizedString(for: lastCheckDate, relativeTo: Date())
                return UpdaterSummary(detail: "\(current) · Last checked \(formatted).")
            }
            return UpdaterSummary(detail: current)
        }
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
    public init(
        host: UpdaterHost,
        dirs: TabDirs,
        settings: UpdateSettings = UpdateSettings(),
        configuration: URLSessionConfiguration = .ephemeral
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
        configureAutomation(settleDelay: AutomaticUpdateInstaller.defaultSettleDelay)
    }

    init(
        host: UpdaterHost,
        dirs: TabDirs,
        prepared: PreparedUpdate? = nil,
        installation: Installation? = nil,
        settings: UpdateSettings = UpdateSettings(),
        settleDelay: TimeInterval = AutomaticUpdateInstaller.defaultSettleDelay,
        operations: UpdaterOperations
    ) {
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
        if let prepared { status = .ready(version: prepared.version) }
        configureAutomation(settleDelay: settleDelay)
    }

    private func configureAutomation(settleDelay: TimeInterval) {
        automaticInstaller = AutomaticUpdateInstaller(
            settleDelay: settleDelay,
            evaluate: { [weak self] in
                guard let self else { return .noUpdateReady }
                return self.automaticInstallObstacle()
            },
            onTrigger: { [weak self] in self?.installQuietly() }
        )
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
                if let updated { self.notice = .updated(version: updated) }
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
            case .download, .update, .restartServer, .endTerminalsAndUpdate, .endTerminalsAndRestartServer:
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
        case .restartServer:
            guard !isBusy else { return }
            dismissedServer = nil
            notice = .confirmServerRestart
        case .endTerminalsAndRestartServer:
            restartServer()
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

    /// Call when the local server connects, or its session count changes:
    /// a server restart finishes once the new build answers, and an older
    /// server left running by an earlier update is replaced once idle.
    public func reconcile() {
        guard let host else { return }
        if status == .restartingServer {
            guard let instance = host.localServerInstance, instance != restartingInstance,
                  let build = host.localServerBuild,
                  !UpdateDecision.isOutdated(serverVersion: build.version, appVersion: Release.version) else { return }
            serverRestartTimer?.invalidate()
            serverRestartAttempt = nil
            task = nil
            refreshStatus()
            notice = .serverRestarted(version: build.version)
            return
        }
        guard !isBusy, host.localServerBuild != nil, !replacingServer, host.runningAgentCount == 0,
              UpdateDecision.shouldReplaceServer(serverVersion: host.localServerBuild?.version, appVersion: Release.version,
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
        case .failure(let error):
            Log.updates.error("update check failed: \(String(describing: error), privacy: .public)")
            if !networkState.isOnline || Self.isOfflineError(error) { needsOnlineCheck = true }
            refreshStatus()
            if manual { notice = .checkFailed(UpdateChip.reason(error)) }
        case .success(let latest):
            needsOnlineCheck = false
            let now = Date()
            lastCheckDate = now
            UpdateCheckState.save(now, to: checkStateURL)
            if case .checkFailed = notice { notice = nil }
            available = Self.newerRelease(latest, than: prepared?.version)
            refreshStatus()
            if manual, available == nil, prepared == nil { notice = .upToDate(version: Release.version) }
            if available != nil { maybeStartAutomaticDownload() }
        }
        host?.updaterDidChange()
        reconcile()
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
        guard networkState.isOnline else { return }
        downloadHold = nil
        download(automatic: true)
    }

    /// Downloads and verifies the available release in the background.
    /// Manual downloads always show progress and bypass Low Data Mode / hotspot
    /// holds; automatic downloads stay quiet until ready.
    private func download(automatic: Bool = false) {
        guard let manifest = available, let installation, !isBusy else { return }
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
            }
        case .success(let update):
            if let previous = prepared, previous.staging != update.staging {
                Task.detached(priority: .utility) { previous.discard() }
            }
            prepared = update
            if available?.version == update.version { available = nil }
            dismissedReady = nil
            PendingUpdateRecord.save(update, to: record)
            refreshStatus()
            automaticInstaller?.reevaluate()
        }
        host?.updaterDidChange()
        reconcile()
    }

    private func refreshStatus() {
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

    // MARK: Installing

    private enum InstallMode {
        /// The running server keeps its terminals until it is idle.
        case keepServer
        /// Stops the server only if no terminal started meanwhile.
        case stopIdleServer
        /// Ends every terminal; the person agreed.
        case endTerminals
    }

    private func update() {
        if case .installed = status {
            host?.quitForUpdate()
            return
        }
        guard let prepared, let host, let server = host.localServerBuild else { return }
        let compatible = UpdateDecision.isCompatible(prepared.manifest, with: server)
        switch UpdateDecision.step(compatible: compatible, sessions: host.runningSessionCount, agents: host.runningAgentCount) {
        case .install: install(.keepServer)
        case .installStoppingIdleServer: install(.stopIdleServer)
        case .confirmEndingTerminals: notice = .confirmUpdate
        }
    }

    private func automaticInstallObstacle() -> AutomaticInstallObstacle? {
        guard !isBusy else { return .noUpdateReady }
        guard let host else { return .noUpdateReady }
        let enabled = settings.automaticInstall || relaunchWhenIdle
        let hasReady = prepared != nil
        let compatible = prepared.map { UpdateDecision.isCompatible($0.manifest, with: host.localServerBuild) } ?? false
        return AutomaticUpdateInstaller.obstacle(
            enabled: enabled,
            hasReadyUpdate: hasReady,
            serverCompatible: compatible,
            environment: host.automaticInstallEnvironment
        )
    }

    private func installQuietly() {
        guard automaticInstallObstacle() == nil else { return }
        install(.keepServer, quiet: true)
    }

    /// Replaces the app and relaunches.
    private func install(_ mode: InstallMode, quiet: Bool = false) {
        guard let prepared, let host, !isBusy, host.localServerBuild != nil else { return }
        automaticInstaller?.cancelSettle()
        notice = nil
        status = .installing(version: prepared.version)
        let record = record
        let updatedMarker = updatedMarker
        let quietRelaunchMarker = quietRelaunchMarker
        let serverStartupLock = serverStartupLock
        let operations = operations
        task = Task { [weak self] in
            do {
                guard try await host.prepareToQuitForUpdate() else {
                    self?.task = nil
                    self?.refreshStatus()
                    if !quiet { self?.notice = .unsavedEditors }
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
                    self?.prepared = nil
                    if self?.available == nil { self?.available = prepared.manifest }
                    try? FileManager.default.removeItem(at: record)
                    Task.detached(priority: .utility) { prepared.discard() }
                    throw error
                }
                try Task.checkCancellation()
                switch mode {
                case .keepServer:
                    // The server may have been replaced by an older one since the person chose.
                    guard UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) else {
                        self?.task = nil
                        self?.refreshStatus()
                        return
                    }
                case .stopIdleServer:
                    // A terminal started meanwhile: the chip asks again.
                    guard await host.stopLocalServerIfIdle() else {
                        self?.task = nil
                        self?.refreshStatus()
                        self?.notice = .installFailed("The server is busy with terminals or agents, or could not be reached. Try again once it is idle.")
                        return
                    }
                case .endTerminals:
                    if !UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) {
                        try await host.endAllSessions()
                    }
                }
                try await Task.detached(priority: .userInitiated) {
                    if quiet { QuietRelaunchMarker.save(to: quietRelaunchMarker) }
                    do {
                        try operations.install(prepared, quiet)
                    } catch {
                        if quiet { try? FileManager.default.removeItem(at: quietRelaunchMarker) }
                        throw error
                    }
                    try? FileManager.default.removeItem(at: record)
                    UpdatedMarker.save(prepared.version, to: updatedMarker)
                }.value
                self?.prepared = nil
                self?.available = nil
                self?.relaunchWhenIdle = false
                self?.task = nil
                self?.status = .installed(version: prepared.version)
                host.quitForUpdate()
            } catch {
                guard let self else { return }
                self.task = nil
                Log.updates.error("could not install the update: \(String(describing: error), privacy: .public)")
                self.refreshStatus()
                if !quiet {
                    self.notice = .installFailed(UpdateChip.reason(error))
                }
            }
        }
    }

    // MARK: Server

    /// Restarts the outdated local server on this app's build. The chip
    /// shows the restart until the new build answers.
    private func restartServer() {
        guard let host, !isBusy else { return }
        notice = nil
        let attempt = UUID()
        serverRestartAttempt = attempt
        restartingInstance = host.localServerInstance
        status = .restartingServer
        serverRestartTimer?.invalidate()
        serverRestartTimer = Timer.scheduledTimer(withTimeInterval: Self.serverRestartTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.serverRestartAttempt == attempt else { return }
                self?.serverRestartFailed("The server didn’t come back in time.")
            }
        }
        task = Task { [weak self] in
            do {
                try await host.restartLocalServer()
            } catch {
                guard !Task.isCancelled, self?.serverRestartAttempt == attempt else { return }
                self?.serverRestartFailed(UpdateChip.reason(error))
            }
        }
    }

    private func serverRestartFailed(_ reason: String) {
        guard status == .restartingServer else { return }
        serverRestartTimer?.invalidate()
        serverRestartAttempt = nil
        task?.cancel()
        task = nil
        refreshStatus()
        notice = .serverRestartFailed(reason)
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
    }

    static func save(_ update: PreparedUpdate, to url: URL) {
        let stored = Stored(manifest: update.manifest, staging: update.staging.path, scheduled: false)
        do {
            try AtomicFile.write(JSONEncoder().encode(stored), to: url)
        } catch {
            Log.updates.error("could not save the pending update: \(error.localizedDescription, privacy: .public)")
        }
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

/// `quiet-relaunch`: written right before an automatic idle relaunch so the
/// next launch stays hidden in the background instead of stealing focus.
public enum QuietRelaunchMarker {
    public static func save(to url: URL) {
        try? AtomicFile.write(Data("1".utf8), to: url)
    }

    /// Returns whether this launch was a quiet relaunch and removes the marker.
    public static func take(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
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
    var install: @Sendable (PreparedUpdate, Bool) throws -> Void = { try $0.install(quiet: $1) }
}
