import TabMobileUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: RootViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = TabApplication.shared.makeRoot()
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        self.root = root
        if let url = options.urlContexts.first?.url { root.open(url) }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.first?.url else { return }
        root?.open(url)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        TabApplication.shared.sceneEnteredForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        TabApplication.shared.sceneEnteredBackground()
    }
}
