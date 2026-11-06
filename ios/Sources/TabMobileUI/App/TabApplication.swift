import Network
import TabMobileKit
import UIKit

/// The app as the app target sees it: one model for every window, connected
/// while any window is in the foreground.
@MainActor
public final class TabApplication {
    public static let shared = TabApplication()

    let model = AppModel()
    private let path = NWPathMonitor()
    private var foregroundScenes = 0
    private var lastPath: NWPath.Status?

    private init() {
        path.pathUpdateHandler = { [weak self] update in
            Task { @MainActor in self?.networkChanged(update) }
        }
        path.start(queue: .main)
    }

    /// The root view controller for a new window.
    public func makeRoot() -> RootViewController {
        RootViewController(app: model)
    }

    public func sceneEnteredForeground() {
        foregroundScenes += 1
        if foregroundScenes == 1 { model.resume() }
    }

    public func sceneEnteredBackground() {
        foregroundScenes = max(0, foregroundScenes - 1)
        if foregroundScenes == 0 { model.suspend() }
    }

    private func networkChanged(_ update: NWPath) {
        defer { lastPath = update.status }
        guard update.status == .satisfied, lastPath != nil else { return }
        model.networkChanged()
    }
}
