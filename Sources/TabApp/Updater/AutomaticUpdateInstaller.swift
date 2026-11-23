import AppKit
import Foundation
import TabCore

/// Why an automatic idle relaunch cannot happen right now.
public enum AutomaticInstallObstacle: Equatable, Sendable {
    case automationOff
    case noUpdateReady
    case incompatibleServer
    case windowVisible
    case fullScreen
    case modalPresented
    case unsavedWork
}

/// Snapshot of the app's UI state used to decide whether a quiet idle relaunch
/// is safe without interrupting the person.
public struct AutomaticInstallEnvironment: Equatable, Sendable {
    public var isWindowVisible: Bool
    public var hasFullScreenWindow: Bool
    public var hasModalOrSheet: Bool
    public var hasUnsavedEditors: Bool

    public init(
        isWindowVisible: Bool = true,
        hasFullScreenWindow: Bool = false,
        hasModalOrSheet: Bool = false,
        hasUnsavedEditors: Bool = false
    ) {
        self.isWindowVisible = isWindowVisible
        self.hasFullScreenWindow = hasFullScreenWindow
        self.hasModalOrSheet = hasModalOrSheet
        self.hasUnsavedEditors = hasUnsavedEditors
    }

    /// Reads the live AppKit state on the main actor.
    @MainActor
    public static func current(hasUnsavedEditors: Bool) -> AutomaticInstallEnvironment {
        guard let app = NSApp else {
            return AutomaticInstallEnvironment(isWindowVisible: false, hasUnsavedEditors: hasUnsavedEditors)
        }
        let windows = app.windows.filter { window in
            window.level == .normal && window.canBecomeMain
        }
        let hasFullScreen = windows.contains { $0.styleMask.contains(.fullScreen) }
        let hasModal = app.modalWindow != nil || app.windows.contains { $0.attachedSheet != nil }
        let anyVisible = !app.isHidden && windows.contains { window in
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
        return AutomaticInstallEnvironment(
            isWindowVisible: anyVisible,
            hasFullScreenWindow: hasFullScreen,
            hasModalOrSheet: hasModal,
            hasUnsavedEditors: hasUnsavedEditors
        )
    }
}

/// Watches app visibility and triggers a quiet relaunch once a compatible
/// update is ready and Tab's windows have stayed out of sight for a short
/// settling period.
@MainActor
final class AutomaticUpdateInstaller {
    /// How long Tab must stay out of sight before relaunching, so brief
    /// app switches or hide/unhide gestures never trigger a restart.
    nonisolated static let defaultSettleDelay: TimeInterval = 5

    private let settleDelay: TimeInterval
    private let evaluate: @MainActor () -> AutomaticInstallObstacle?
    private let onTrigger: @MainActor () -> Void
    private var settleTask: Task<Void, Never>?
    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var observing = false

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
        if environment.hasFullScreenWindow { return .fullScreen }
        if environment.hasModalOrSheet { return .modalPresented }
        if environment.hasUnsavedEditors { return .unsavedWork }
        if environment.isWindowVisible { return .windowVisible }
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
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
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
    }

    func stop() {
        cancelSettle()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        observing = false
    }

    /// Re-checks obstacles; starts the settling timer if clear, or cancels it
    /// immediately if an obstacle returned.
    func reevaluate() {
        if let obstacle = evaluate() {
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
            guard self.evaluate() == nil else { return }
            Log.updates.info("automatic install relaunching")
            self.onTrigger()
        }
    }

    func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
    }
}
