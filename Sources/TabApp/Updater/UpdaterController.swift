import AppKit
import TabCore
import TabProtocol

/// What the updater needs from the app shell.
@MainActor
public protocol UpdaterHost: AnyObject {
    /// The connected local server's build (version and protocol versions);
    /// `nil` while disconnected.
    var localServerBuild: BuildInfo? { get }
    /// Terminals on the local server, including idle and detached ones.
    var runningSessionCount: Int { get }
    /// Stops the local server, ending every terminal on it.
    func endAllSessions() async throws
    /// Stops the local server only when no terminal runs; returns whether it stops.
    func stopLocalServerIfIdle() async -> Bool
    /// Restarts the local server on this app's build, ending every terminal on it.
    func restartLocalServer() async throws
    /// Saves state and settles unsaved editors before quitting for an
    /// update; `false` cancels the install.
    func prepareToQuitForUpdate() -> Bool
    /// Quits the app. The new version is already in place and starts once
    /// this process exits.
    func quitForUpdate()
    /// The updater's status or chip changed.
    func updaterDidChange()
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
        if let version = server?.version, sessions > 0, version != dismissedServer,
           UpdateDecision.isOutdated(serverVersion: version, appVersion: Release.version) {
            outdatedServer = version
        }
        let checking = manualCheck && (status == .checking || installation == nil)
        let offered = available.map(\.version).flatMap { $0 == dismissedAvailable ? nil : $0 }
        return UpdateChip.make(status: status, notice: notice, checking: checking, showsDownload: downloadingVersion != dismissedDownload,
                               available: downloadingVersion == nil ? offered : nil, ready: ready, outdatedServer: outdatedServer, sessions: sessions)
    }

    private weak var host: UpdaterHost?
    private let record: URL
    private let updatedMarker: URL
    private let serverStartupLock: URL
    private var downloader: UpdateDownloader
    private var installation: Installation?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var replacingServer = false
    /// A check the person asked for is running or waits for the updater to start.
    private var manualCheck = false
    private var notice: UpdateNotice? {
        didSet {
            guard notice != oldValue else { return }
            scheduleNoticeExpiry()
            host?.updaterDidChange()
        }
    }
    private var noticeTimer: Timer?
    private var serverRestartTimer: Timer?
    private var dismissedAvailable: String?
    private var dismissedReady: String?
    private var dismissedDownload: String?
    private var dismissedServer: String?
    /// The sample chip on show in debug builds, which never update.
    private var previewIndex: Int?

    /// - Parameters:
    ///   - dirs: the profile, which keeps the pending update record.
    ///   - configuration: the session configuration for downloads, carrying
    ///     the app's proxy when it is used for the whole app.
    public init(host: UpdaterHost, dirs: TabDirs, configuration: URLSessionConfiguration = .ephemeral) {
        self.host = host
        record = dirs.root.appendingPathComponent("pending-update.json")
        updatedMarker = dirs.root.appendingPathComponent("updated-to")
        serverStartupLock = dirs.root.appendingPathComponent("server.startup-lock")
        downloader = UpdateDownloader(configuration: configuration)
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
            guard let self else { return }
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
                self.check()
                self.timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                }
                self.timer?.tolerance = 600
                self.reconcile()
            }
        }
    }

    /// Stops background checks.
    public func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        noticeTimer?.invalidate()
        serverRestartTimer?.invalidate()
    }

    /// Check for Updates…: checks now and reports on the chip, bringing
    /// back whatever it had hidden.
    public func checkForUpdates() {
        dismissedAvailable = nil
        dismissedReady = nil
        dismissedDownload = nil
        dismissedServer = nil
        switch status {
        case .installing, .restartingServer:
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
        switch action {
        case .download:
            download()
        case .update:
            update()
        case .endTerminalsAndUpdate:
            install(.endTerminals)
        case .restartServer:
            if host?.runningSessionCount ?? 0 > 0 { notice = .confirmServerRestart } else { restartServer() }
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
            guard let build = host.localServerBuild,
                  !UpdateDecision.isOutdated(serverVersion: build.version, appVersion: Release.version) else { return }
            serverRestartTimer?.invalidate()
            refreshStatus()
            notice = .serverRestarted(version: build.version)
            return
        }
        guard !isBusy, host.localServerBuild != nil, !replacingServer,
              UpdateDecision.shouldReplaceServer(serverVersion: host.localServerBuild?.version, appVersion: Release.version,
                                                 sessions: host.runningSessionCount)
        else { return }
        replacingServer = true
        Task { [weak self] in
            _ = await host.stopLocalServerIfIdle()
            self?.replacingServer = false
        }
    }

    // MARK: Checking

    private var isBusy: Bool {
        switch status {
        case .checking, .downloading, .preparing, .installing, .restartingServer: return true
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
        task = Task { [weak self] in
            let result: Result<UpdateManifest?, Error>
            do {
                result = .success(try await downloader.latest())
            } catch {
                result = .failure(error)
            }
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
            refreshStatus()
            if manual { notice = .checkFailed(UpdateChip.reason(error)) }
        case .success(let latest):
            available = Self.newerRelease(latest, than: prepared?.version)
            refreshStatus()
            if manual, available == nil, prepared == nil { notice = .upToDate(version: Release.version) }
        }
        host?.updaterDidChange()
    }

    /// Update: downloads and verifies the available release in the background.
    private func download() {
        guard let manifest = available, let installation, !isBusy else { return }
        let downloader = downloader
        let version = manifest.version
        notice = nil
        status = .downloading(version: version, progress: manifest.size == nil ? nil : 0)
        task = Task { [weak self] in
            let result: Result<PreparedUpdate, Error>
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let archive = try await downloader.download(manifest, into: folder) { fraction in
                    Task { @MainActor in self?.downloadProgressed(version, fraction) }
                }
                self?.status = .preparing(version: version)
                result = .success(try await Task.detached(priority: .utility) {
                    try installation.prepare(archive: archive, manifest: manifest)
                }.value)
            } catch {
                result = .failure(error)
            }
            self?.finishDownload(result, version: version)
        }
    }

    private func downloadProgressed(_ version: String, _ fraction: Double) {
        guard case .downloading(version, _) = status else { return }
        status = .downloading(version: version, progress: fraction)
    }

    private func finishDownload(_ result: Result<PreparedUpdate, Error>, version: String) {
        task = nil
        switch result {
        case .failure(let error):
            Log.updates.error("update download failed: \(String(describing: error), privacy: .public)")
            refreshStatus()
            notice = .downloadFailed(version: version, reason: UpdateChip.reason(error))
        case .success(let update):
            if let previous = prepared, previous.staging != update.staging {
                Task.detached(priority: .utility) { previous.discard() }
            }
            prepared = update
            if available?.version == update.version { available = nil }
            dismissedReady = nil
            PendingUpdateRecord.save(update, to: record)
            refreshStatus()
        }
        host?.updaterDidChange()
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
        guard let prepared, let host, let server = host.localServerBuild else { return }
        let compatible = UpdateDecision.isCompatible(prepared.manifest, with: server)
        switch UpdateDecision.step(compatible: compatible, sessions: host.runningSessionCount) {
        case .install: install(.keepServer)
        case .installStoppingIdleServer: install(.stopIdleServer)
        case .confirmEndingTerminals: notice = .confirmUpdate
        }
    }

    /// Replaces the app and relaunches.
    private func install(_ mode: InstallMode) {
        guard let prepared, let host, !isBusy, host.localServerBuild != nil else { return }
        guard host.prepareToQuitForUpdate() else {
            notice = .unsavedEditors
            return
        }
        notice = nil
        status = .installing(version: prepared.version)
        let record = record
        let updatedMarker = updatedMarker
        let serverStartupLock = serverStartupLock
        task = Task { [weak self] in
            do {
                let lease = try await Task.detached(priority: .userInitiated) {
                    try FileLock.tryLock(serverStartupLock)
                }.value
                defer { lease.unlock() }
                try await Task.detached(priority: .userInitiated) { try prepared.validate() }.value
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
                        return
                    }
                case .endTerminals:
                    try await host.endAllSessions()
                }
                try await Task.detached(priority: .userInitiated) {
                    try prepared.install()
                    try? FileManager.default.removeItem(at: record)
                    UpdatedMarker.save(prepared.version, to: updatedMarker)
                }.value
                host.quitForUpdate()
            } catch {
                guard let self else { return }
                self.task = nil
                Log.updates.error("could not install the update: \(String(describing: error), privacy: .public)")
                self.refreshStatus()
                self.notice = .installFailed(UpdateChip.reason(error))
            }
        }
    }

    // MARK: Server

    /// Restarts the outdated local server on this app's build. The chip
    /// shows the restart until the new build answers.
    private func restartServer() {
        guard let host, !isBusy else { return }
        notice = nil
        status = .restartingServer
        serverRestartTimer?.invalidate()
        serverRestartTimer = Timer.scheduledTimer(withTimeInterval: Self.serverRestartTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.serverRestartFailed("The server didn’t come back in time.") }
        }
        Task { [weak self] in
            do {
                try await host.restartLocalServer()
            } catch {
                self?.serverRestartFailed(UpdateChip.reason(error))
            }
        }
    }

    private func serverRestartFailed(_ reason: String) {
        guard status == .restartingServer else { return }
        serverRestartTimer?.invalidate()
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
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return update
    }
}
