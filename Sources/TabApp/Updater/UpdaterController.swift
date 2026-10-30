import AppKit
import TabCore
import TabProtocol

/// What the updater needs from the app shell.
@MainActor
public protocol UpdaterHost: AnyObject {
    /// The window the update sheet and messages attach to.
    var updateWindow: NSWindow? { get }
    /// The connected local server's build (version and protocol versions);
    /// `nil` while disconnected.
    var localServerBuild: BuildInfo? { get }
    /// Terminals on the local server, including idle and detached ones.
    var runningSessionCount: Int { get }
    /// Stops the local server, ending every terminal on it.
    func endAllSessions() async throws
    /// Stops the local server only when no terminal runs; returns whether it stops.
    func stopLocalServerIfIdle() async -> Bool
    /// Saves state and settles unsaved editors before quitting for an
    /// update; `false` cancels the install.
    func prepareToQuitForUpdate() -> Bool
    /// Quits the app. The new version is already in place and starts once
    /// this process exits.
    func quitForUpdate()
    /// The updater's status changed, such as for a menu item or a badge.
    func updaterStatusDidChange(_ status: UpdaterStatus)
    /// A background check downloaded a new version, such as for a notification.
    func announceUpdate(version: String)
}

/// Where the updater is.
public enum UpdaterStatus: Equatable, Sendable {
    case idle
    /// This build can't update itself, and why.
    case unavailable(String)
    case checking
    case downloading(version: String)
    /// Downloaded and verified, waiting for the person.
    case ready(version: String)
    /// Installs once every terminal has ended.
    case waitingForSessions(version: String, sessions: Int)
    case installing(version: String)
    case failed(String)
}

/// Checks GitHub Releases for a new Tab, downloads and verifies it, and
/// installs it as the person chooses in the "Update available" sheet: now
/// when the new version speaks the running server's protocol (terminals keep
/// running, the server is replaced once idle), otherwise once every terminal
/// has ended or right away after confirming that every terminal ends.
@MainActor
public final class UpdaterController {
    /// Background checks run at launch and then this often.
    public static let checkInterval: TimeInterval = 60 * 60

    public private(set) var status: UpdaterStatus = .idle {
        didSet { if status != oldValue { host?.updaterStatusDidChange(status) } }
    }

    /// The downloaded release waiting to install.
    public private(set) var prepared: PreparedUpdate?
    /// Whether the install waits for every terminal to end.
    public private(set) var scheduled = false

    private weak var host: UpdaterHost?
    private let record: URL
    private let serverStartupLock: URL
    private var downloader: UpdateDownloader
    private var installation: Installation?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var sheet: UpdateSheet?
    private var replacingServer = false

    /// - Parameters:
    ///   - dirs: the profile, which keeps the pending update record.
    ///   - configuration: the session configuration for downloads, carrying
    ///     the app's proxy when it is used for the whole app.
    public init(host: UpdaterHost, dirs: TabDirs, configuration: URLSessionConfiguration = .ephemeral) {
        self.host = host
        record = dirs.root.appendingPathComponent("pending-update.json")
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
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<(Installation, PreparedUpdate?, Bool), UpdateError> in
                do {
                    let installation = try Installation.detect()
                    let (pending, scheduled) = PendingUpdateRecord.restore(record, installation: installation)
                    installation.cleanUp(keeping: pending?.staging)
                    return .success((installation, pending, scheduled))
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
            case .success(let (installation, pending, scheduled)):
                self.installation = installation
                self.prepared = pending
                self.scheduled = scheduled && pending != nil
                self.refreshStatus()
                self.check(manual: false)
                self.timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check(manual: false) }
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
    }

    /// Check for Updates…: checks now and shows the result.
    public func checkForUpdates() {
        if prepared != nil, !isBusy {
            showUpdateSheet()
            return
        }
        check(manual: true)
    }

    /// Shows the "Update available" sheet for the downloaded release.
    public func showUpdateSheet() {
        guard let prepared, !isBusy, sheet == nil, let host else { return }
        let sessions = host.runningSessionCount
        guard let server = host.localServerBuild else { return }
        let compatible = UpdateDecision.isCompatible(prepared.manifest, with: server)
        let offer = UpdateDecision.offer(compatible: compatible, scheduled: scheduled, sessions: sessions)
        let sheet = UpdateSheet(version: prepared.version, offer: offer)
        self.sheet = sheet
        sheet.present(on: host.updateWindow) { [weak self] choice in
            guard let self else { return }
            self.sheet = nil
            guard self.prepared?.version == prepared.version, self.host?.localServerBuild == server else { return }
            if choice == .waitForSessions {
                self.setScheduled(true)
                return
            }
            let sessions = self.host?.runningSessionCount ?? sessions
            self.perform(UpdateDecision.step(for: choice, compatible: compatible, sessions: sessions))
        }
    }

    /// Call when the local server connects, or its session count changes:
    /// a waiting install proceeds once no terminal is left, and an older
    /// server left running by an earlier update is replaced once idle.
    public func reconcile() {
        guard let host, !isBusy, host.localServerBuild != nil else { return }
        let sessions = host.runningSessionCount
        if scheduled, prepared != nil {
            status = .waitingForSessions(version: prepared?.version ?? "", sessions: sessions)
            if UpdateDecision.scheduledStep(sessions: sessions) != .wait { install(stopServer: false, whenIdle: true) }
            return
        }
        guard !replacingServer,
              UpdateDecision.shouldReplaceServer(serverVersion: host.localServerBuild?.version, appVersion: Release.version, sessions: sessions)
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
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private func check(manual: Bool) {
        guard !isBusy else { return }
        guard let installation else {
            if manual { message(statusReason ?? "The updater is starting. Try again shortly.") }
            return
        }
        status = .checking
        let downloader = downloader
        let known = prepared
        task = Task { [weak self] in
            let result: Result<PreparedUpdate?, Error>
            do {
                guard let manifest = try await downloader.latest() else {
                    result = .success(nil)
                    self?.finishCheck(result, manual: manual)
                    return
                }
                if let known, known.manifest == manifest {
                    result = .success(known)
                } else {
                    self?.status = .downloading(version: manifest.version)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-update-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let archive = try await downloader.download(manifest, into: folder)
                    let prepared = try await Task.detached(priority: .utility) {
                        try installation.prepare(archive: archive, manifest: manifest)
                    }.value
                    result = .success(prepared)
                }
            } catch {
                result = .failure(error)
            }
            self?.finishCheck(result, manual: manual)
        }
    }

    private func finishCheck(_ result: Result<PreparedUpdate?, Error>, manual: Bool) {
        task = nil
        switch result {
        case .failure(let error):
            let text = "Could not check for or download the latest update: \((error as? UpdateError)?.description ?? error.localizedDescription)"
            status = .failed(text)
            Log.updates.error("\(text, privacy: .public)")
            if manual { message(text) }
        case .success(nil):
            refreshStatus()
            if manual { message("You’re running the latest version of \(Release.appName).") }
        case .success(let update?):
            let previous = prepared
            let announced = previous?.version == update.version
            if let previous, previous.staging != update.staging {
                Task.detached(priority: .utility) { previous.discard() }
                scheduled = false
            }
            prepared = update
            PendingUpdateRecord.save(update, scheduled: scheduled, to: record)
            refreshStatus()
            if manual {
                showUpdateSheet()
            } else if !announced {
                host?.announceUpdate(version: update.version)
            }
        }
    }

    private var statusReason: String? {
        if case .unavailable(let reason) = status { return reason }
        return nil
    }

    private func refreshStatus() {
        guard let prepared else {
            status = .idle
            return
        }
        status = scheduled
            ? .waitingForSessions(version: prepared.version, sessions: host?.runningSessionCount ?? 0)
            : .ready(version: prepared.version)
    }

    // MARK: Installing

    private func perform(_ step: UpdateStep) {
        switch step {
        case .nothing:
            return
        case .wait:
            setScheduled(true)
        case .cancelWait:
            setScheduled(false)
        case .install(let stopServer):
            install(stopServer: stopServer, whenIdle: false)
        }
    }

    private func setScheduled(_ value: Bool) {
        guard let prepared else { return }
        scheduled = value
        PendingUpdateRecord.save(prepared, scheduled: value, to: record)
        refreshStatus()
        if value { reconcile() }
    }

    /// Replaces the app and relaunches. `stopServer` ends every terminal
    /// first; `whenIdle` stops the server only if nothing runs there.
    private func install(stopServer: Bool, whenIdle: Bool) {
        guard let prepared, let host, !isBusy, host.localServerBuild != nil else { return }
        guard stopServer || whenIdle || UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) else {
            setScheduled(true)
            return
        }
        guard host.prepareToQuitForUpdate() else { return }
        status = .installing(version: prepared.version)
        let record = record
        let serverStartupLock = serverStartupLock
        task = Task { [weak self] in
            do {
                let lease = try await Task.detached(priority: .userInitiated) {
                    try FileLock.tryLock(serverStartupLock)
                }.value
                defer { lease.unlock() }
                try await Task.detached(priority: .userInitiated) { try prepared.validate() }.value
                if whenIdle {
                    guard await host.stopLocalServerIfIdle() else {
                        self?.task = nil
                        self?.refreshStatus()
                        return
                    }
                } else if stopServer {
                    try await host.endAllSessions()
                } else {
                    guard UpdateDecision.isCompatible(prepared.manifest, with: host.localServerBuild) else {
                        self?.task = nil
                        self?.scheduled = true
                        PendingUpdateRecord.save(prepared, scheduled: true, to: record)
                        self?.refreshStatus()
                        return
                    }
                }
                try await Task.detached(priority: .userInitiated) {
                    try prepared.install()
                    try? FileManager.default.removeItem(at: record)
                }.value
                host.quitForUpdate()
            } catch {
                guard let self else { return }
                self.task = nil
                let text = "Could not install the update: \((error as? UpdateError)?.description ?? error.localizedDescription)"
                self.status = .failed(text)
                self.message(text)
            }
        }
    }

    private func message(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "\(Release.appName) Updates"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.window.appearance = AppTheme.shared.nsAppearance
        guard let window = host?.updateWindow else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }
}

/// `pending-update.json`: the downloaded release, so a restart keeps it and
/// a waiting install keeps waiting.
enum PendingUpdateRecord {
    struct Stored: Codable {
        var manifest: UpdateManifest
        var staging: String
        var scheduled: Bool
    }

    static func save(_ update: PreparedUpdate, scheduled: Bool, to url: URL) {
        let stored = Stored(manifest: update.manifest, staging: update.staging.path, scheduled: scheduled)
        do {
            try AtomicFile.write(JSONEncoder().encode(stored), to: url)
        } catch {
            Log.updates.error("could not save the pending update: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The pending update when it is still newer than this build and its
    /// staged app is still intact; anything else is forgotten.
    static func restore(_ url: URL, installation: Installation) -> (PreparedUpdate?, Bool) {
        guard let data = try? Data(contentsOf: url) else { return (nil, false) }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              ReleaseVersion.isNewer(stored.manifest.version, than: Release.version)
        else {
            try? FileManager.default.removeItem(at: url)
            return (nil, false)
        }
        let update = PreparedUpdate(manifest: stored.manifest, installation: installation,
                                    staging: URL(fileURLWithPath: stored.staging, isDirectory: true))
        do {
            try update.validate()
        } catch {
            try? FileManager.default.removeItem(at: url)
            return (nil, false)
        }
        return (update, stored.scheduled)
    }
}
