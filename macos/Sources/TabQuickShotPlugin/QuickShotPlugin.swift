import AppKit
import ScreenCaptureKit
import SwiftUI
import TabApp
import TabCore

/// Principal class loaded dynamically from `quickshot.bundle`.
@objc(TabQuickShotPluginFactory)
@MainActor
public final class QuickShotPluginFactory: TabPluginFactory {
    public required init() {
        super.init()
    }

    public override func makePlugin() -> any TabPlugin {
        QuickShotPlugin()
    }
}

/// What the configuration page shows live: whether the trigger is armed and
/// which permissions macOS has granted.
@MainActor
public final class QuickShotStatus: ObservableObject {
    @Published public internal(set) var trigger: QuickShotTriggerStatus = .starting
    @Published public internal(set) var screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    @Published public internal(set) var inputMonitoringAllowed = CGPreflightListenEventAccess()
    @Published public internal(set) var lastCapture: String?

    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess()
        let input = CGPreflightListenEventAccess()
        if screen != screenRecordingAllowed { screenRecordingAllowed = screen }
        if input != inputMonitoringAllowed { inputMonitoringAllowed = input }
    }
}

/// QuickShot: a system-wide shortcut that captures the display under the
/// pointer to a PNG and puts its path, or the image, on the clipboard.
@MainActor
public final class QuickShotPlugin: TabPlugin {
    public let id: PluginId = .quickshot
    public let status = QuickShotStatus()
    public private(set) var config = QuickShotConfig()

    private weak var model: AppModel?
    private var feedback: QuickShotFeedback?
    private let commandKeys = CommandKeysMonitor()
    private let shortcut = GlobalShortcut()
    private var armedTrigger: (QuickShotConfig.Trigger, KeyChord?)?
    private var capturing = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {}

    public func activate(context: PluginContext) {
        model = context.model
        feedback = QuickShotFeedback(theme: context.model.theme)
        apply(QuickShotConfig.current(in: context.model.settings))
        context.onSettingsChanged { [weak self] settings in
            self?.apply(QuickShotConfig.current(in: settings))
        }
        context.registerSettingsView { [weak self] store in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(QuickShotSettingsView(
                store: store, config: QuickShotConfig.current(in: store.settings), status: status, plugin: self
            ))
        }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.refresh(reset: false)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.refresh(reset: true)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.refresh(reset: true)
        }
        removeExpiredCaptures()
    }

    public func deactivate() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        disarm()
        feedback?.invalidate()
        feedback = nil
        model = nil
    }

    // MARK: Configuration

    func apply(_ next: QuickShotConfig) {
        config = next
        let trigger = (next.trigger, next.trigger == .shortcut ? next.shortcut : nil)
        guard armedTrigger.map({ $0.0 != trigger.0 || $0.1 != trigger.1 }) ?? true else { return }
        disarm()
        armedTrigger = trigger
        switch next.trigger {
        case .commandKeys:
            status.trigger = .starting
            commandKeys.start(
                onPress: { [weak self] in self?.capture() },
                onStatus: { [weak self] in self?.status.trigger = $0 }
            )
        case .shortcut:
            guard let chord = next.shortcut else {
                status.trigger = .unavailable("Record a shortcut")
                return
            }
            if let problem = shortcut.register(chord, onPress: { [weak self] in self?.capture() }) {
                status.trigger = .unavailable(problem)
            } else {
                status.trigger = .ready
            }
        }
    }

    private func disarm() {
        commandKeys.stop()
        shortcut.unregister()
        armedTrigger = nil
    }

    /// Rechecks permissions and reconnects the keyboard monitor, such as
    /// after the user allows Tab in System Settings.
    func refresh(reset: Bool) {
        status.refreshPermissions()
        commandKeys.refresh(reset: reset)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append((center, observer))
    }

    // MARK: Capture

    /// Captures the display under the pointer and copies it.
    public func capture() {
        guard !capturing else { return }
        capturing = true
        feedback?.dismiss()
        let config = config
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { capturing = false }
            do {
                let shot = try await QuickShotCapture.captureDisplayUnderPointer(to: config.destination)
                status.screenRecordingAllowed = true
                try QuickShotCapture.copy(shot, as: config.clipboard)
                status.lastCapture = shot.url.path
                if config.playsSound { feedback?.playSound() }
                if config.showsPreview { feedback?.show(shot) }
                removeExpiredCaptures()
            } catch {
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
            status.screenRecordingAllowed = false
            model?.presenter?.showToast("QuickShot needs Screen Recording. Allow Tab in System Settings → Privacy & Security.", error: true)
            return
        }
        Log.app.error("QuickShot capture failed: \(error.localizedDescription)")
        model?.presenter?.showToast("QuickShot: \(error.localizedDescription)", error: true)
    }

    private func removeExpiredCaptures() {
        do {
            try QuickShotCapture.removeExpiredCaptures()
        } catch {
            Log.app.warning("QuickShot couldn't remove old captures: \(error.localizedDescription)")
        }
    }

    /// Shows the folder captures are saved to.
    func revealFolder() {
        do {
            NSWorkspace.shared.open(try QuickShotCapture.folder(for: config.destination))
        } catch {
            report(error)
        }
    }
}
