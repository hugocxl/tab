import AppKit
import CoreGraphics
import Foundation
import TabCore

/// Why an automatic idle relaunch or server restart cannot happen right now.
public enum AutomaticInstallObstacle: Equatable, Sendable {
    case automationOff
    case noUpdateReady
    case incompatibleServer
    case windowVisible
    case fullScreen
    case modalPresented
    case unsavedWork
    /// Programs or agents work on the server a restart would cut short.
    case workRunning
}

/// How Tab comes back after relaunching into an update: as it was.
public enum RelaunchPresentation: String, Equatable, Sendable {
    /// Frontmost, as the app the person last used.
    case active
    /// Its windows open behind the app the person uses.
    case background
    /// Hidden, as it was.
    case hidden
}

/// Snapshot of the app's UI state used to decide whether a quiet idle relaunch
/// is safe without interrupting the person.
public struct AutomaticInstallEnvironment: Equatable, Sendable {
    /// Seconds without input after which the person counts as away.
    public static let awayAfter: TimeInterval = 10 * 60

    /// A window shows on screen, not covered, minimized or hidden.
    public var isWindowVisible: Bool
    public var hasFullScreenWindow: Bool
    public var hasModalOrSheet: Bool
    public var hasUnsavedEditors: Bool
    /// Tab is the frontmost app.
    public var isAppActive: Bool
    /// A window is open, even if covered: the relaunch opens it again.
    public var hasOpenWindow: Bool
    /// Seconds since the person last typed, clicked or moved the pointer anywhere.
    public var userIdleTime: TimeInterval
    /// The screen is locked, asleep or showing the screen saver, or another
    /// person's session is in front.
    public var isScreenLocked: Bool

    public init(
        isWindowVisible: Bool = true,
        hasFullScreenWindow: Bool = false,
        hasModalOrSheet: Bool = false,
        hasUnsavedEditors: Bool = false,
        isAppActive: Bool = false,
        hasOpenWindow: Bool? = nil,
        userIdleTime: TimeInterval = 0,
        isScreenLocked: Bool = false
    ) {
        self.isWindowVisible = isWindowVisible
        self.hasFullScreenWindow = hasFullScreenWindow
        self.hasModalOrSheet = hasModalOrSheet
        self.hasUnsavedEditors = hasUnsavedEditors
        self.isAppActive = isAppActive
        self.hasOpenWindow = hasOpenWindow ?? isWindowVisible
        self.userIdleTime = userIdleTime
        self.isScreenLocked = isScreenLocked
    }

    /// Whether the person is away from the Mac: a restart now goes unnoticed.
    public var isPersonAway: Bool { isScreenLocked || userIdleTime >= Self.awayAfter }

    /// Seconds without input after which a person with Tab in front counts
    /// as away: watching a video or reading a log leaves the input idle.
    public static let longAwayAfter: TimeInterval = 60 * 60

    /// Whether the person can't be using Tab right now.
    public var isOutOfSight: Bool {
        if !isWindowVisible || isScreenLocked { return true }
        return userIdleTime >= (isAppActive ? Self.longAwayAfter : Self.awayAfter)
    }

    /// How the relaunched app shows itself.
    public var presentation: RelaunchPresentation {
        guard hasOpenWindow else { return .hidden }
        return isAppActive ? .active : .background
    }

    /// Reads the live AppKit state on the main actor.
    @MainActor
    public static func current(hasUnsavedEditors: Bool) -> AutomaticInstallEnvironment {
        let presence = UserPresence.shared
        guard let app = NSApp else {
            return AutomaticInstallEnvironment(isWindowVisible: false, hasUnsavedEditors: hasUnsavedEditors,
                                               userIdleTime: presence.idleTime, isScreenLocked: presence.isScreenLocked)
        }
        let windows = app.windows.filter { window in
            window.level == .normal && window.canBecomeMain
        }
        let hasFullScreen = windows.contains { $0.styleMask.contains(.fullScreen) }
        let hasModal = app.modalWindow != nil || app.windows.contains { $0.attachedSheet != nil }
        let open = !app.isHidden && windows.contains { $0.isVisible && !$0.isMiniaturized }
        let anyVisible = open && windows.contains { window in
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
        return AutomaticInstallEnvironment(
            isWindowVisible: anyVisible,
            hasFullScreenWindow: hasFullScreen,
            hasModalOrSheet: hasModal,
            hasUnsavedEditors: hasUnsavedEditors,
            isAppActive: app.isActive,
            hasOpenWindow: open,
            userIdleTime: presence.idleTime,
            isScreenLocked: presence.isScreenLocked
        )
    }
}

/// Whether the person is at the Mac: the screen's lock, sleep, screen saver
/// and session, and how long since their last input.
@MainActor
final class UserPresence {
    static let shared = UserPresence()

    private var locked = false
    private var screenSaver = false
    private var screensAsleep = false
    private var sessionInactive = false
    private var observing = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    /// Runs when the presence changes.
    var onChange: [() -> Void] = []

    var isScreenLocked: Bool { locked || screenSaver || screensAsleep || sessionInactive }

    /// Seconds since the last keyboard, mouse or trackpad input in this session.
    var idleTime: TimeInterval {
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    func start() {
        guard !observing else { return }
        observing = true
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(distributed, "com.apple.screenIsLocked") { $0.locked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.locked = false }
        observe(distributed, "com.apple.screensaver.didstart") { $0.screenSaver = true }
        observe(distributed, "com.apple.screensaver.didstop") { $0.screenSaver = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.sessionInactive = false }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ change: @escaping @MainActor (UserPresence) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                for handler in self.onChange { handler() }
            }
        }
        tokens.append((center, token))
    }
}

/// Watches for a quiet moment — the person away or Tab out of sight — and
/// then, once it has lasted a short settling period, runs the updater's
/// quiet work: relaunching into a ready update, or restarting an outdated
/// server.
@MainActor
final class AutomaticUpdateInstaller {
    /// How long a quiet moment must last before relaunching, so brief app
    /// switches or hide/unhide gestures never trigger a restart.
    nonisolated static let defaultSettleDelay: TimeInterval = 5
    /// How often the person's idle time is looked at while work waits for them.
    nonisolated static let idleCheckInterval: TimeInterval = 60

    private let settleDelay: TimeInterval
    private let evaluate: @MainActor () -> AutomaticInstallObstacle?
    private let onTrigger: @MainActor () -> Void
    /// The Mac woke from sleep or Tab became active: overdue checks run.
    var onWake: (@MainActor () -> Void)?
    private var settleTask: Task<Void, Never>?
    private var idleTimer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var observing = false
    private var presenceHooked = false
    private var asleep = false

    /// Whether a settling countdown is currently running.
    var isSettling: Bool { settleTask != nil }

    init(
        settleDelay: TimeInterval = AutomaticUpdateInstaller.defaultSettleDelay,
        evaluate: @escaping @MainActor () -> AutomaticInstallObstacle?,
        onTrigger: @escaping @MainActor () -> Void
    ) {
        self.settleDelay = settleDelay
        self.evaluate = evaluate
        self.onTrigger = onTrigger
    }

    /// Pure decision function for whether a quiet relaunch may proceed.
    nonisolated static func obstacle(
        enabled: Bool,
        hasReadyUpdate: Bool,
        serverCompatible: Bool,
        environment: AutomaticInstallEnvironment
    ) -> AutomaticInstallObstacle? {
        guard enabled else { return .automationOff }
        guard hasReadyUpdate else { return .noUpdateReady }
        guard serverCompatible else { return .incompatibleServer }
        return quietObstacle(environment)
    }

    /// What keeps the person from being undisturbed by a restart now.
    nonisolated static func quietObstacle(_ environment: AutomaticInstallEnvironment) -> AutomaticInstallObstacle? {
        if environment.hasFullScreenWindow { return .fullScreen }
        if environment.hasModalOrSheet { return .modalPresented }
        if environment.hasUnsavedEditors { return .unsavedWork }
        if !environment.isOutOfSight { return .windowVisible }
        return nil
    }

    func startObserving() {
        guard !observing else { return }
        observing = true
        let appNames: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification,
        ]
        for name in appNames {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == NSApplication.didBecomeActiveNotification { self?.onWake?() }
                    self?.reevaluate()
                }
            }
            tokens.append(token)
        }
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in workspaceNames {
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            }
            workspaceTokens.append(token)
        }
        // Nothing restarts while the Mac goes to sleep; once awake, overdue checks run.
        workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = true
                self?.cancelSettle()
            }
        })
        workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = false
                self?.onWake?()
                self?.reevaluate()
            }
        })
        UserPresence.shared.start()
        if !presenceHooked {
            presenceHooked = true
            UserPresence.shared.onChange.append { [weak self] in self?.reevaluate() }
        }
    }

    func stop() {
        cancelSettle()
        idleTimer?.invalidate()
        idleTimer = nil
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        observing = false
    }

    /// Re-checks obstacles; starts the settling timer if clear, or cancels it
    /// immediately if an obstacle returned.
    func reevaluate() {
        let obstacle = asleep ? .windowVisible : evaluate()
        watchIdleTime(while: obstacle)
        if let obstacle {
            if settleTask != nil {
                Log.updates.info("automatic install waiting: \(String(describing: obstacle), privacy: .public)")
                cancelSettle()
            }
            return
        }
        guard settleTask == nil else { return }
        Log.updates.info("automatic install settling")
        let delay = settleDelay
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.settleTask = nil
            guard !self.asleep, self.evaluate() == nil else { return }
            Log.updates.info("automatic install starting")
            self.onTrigger()
        }
    }

    /// Looks at the person's idle time now and then while quiet work waits
    /// only for them; no timer runs otherwise.
    private func watchIdleTime(while obstacle: AutomaticInstallObstacle?) {
        let waitsForPerson = obstacle.map { [.windowVisible, .fullScreen, .modalPresented, .unsavedWork, .workRunning].contains($0) } ?? false
        guard waitsForPerson, observing else {
            idleTimer?.invalidate()
            idleTimer = nil
            return
        }
        guard idleTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.idleCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        timer.tolerance = Self.idleCheckInterval / 2
        idleTimer = timer
    }

    func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
    }
}
