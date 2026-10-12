import UIKit
import LunaAppConfig
import LunaDesignSystem

final class WriterSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private static var activeScenes = Set<String>()
    private static var keyboardLeaseTimer: Timer?
    private static func updateKeyboardLease() {
        keyboardLeaseTimer?.invalidate()
        let active = !activeScenes.isEmpty
        KeyboardHostContext.publishWriter(active: active)
        if active {
            keyboardLeaseTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                KeyboardHostContext.publishWriter(active: true)
            }
        } else { keyboardLeaseTimer = nil }
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        Self.activeScenes.remove(scene.session.persistentIdentifier)
        Self.updateKeyboardLease()
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        AppearanceSettings.apply(to: window)
        window.rootViewController = WriterWiring.makeRootViewController()
        self.window = window
        window.makeKeyAndVisible()
        for context in connectionOptions.urlContexts {
            WriterWiring.open(context.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            WriterWiring.open(context.url)
        }
    }

    // UIKit never calls `UIApplicationDelegate.applicationDidEnterBackground`
    // for a scene-based app — only these scene-level hooks fire, so the
    // autosave flush belongs here, not on the app delegate.
    func sceneDidEnterBackground(_ scene: UIScene) {
        WriterWiring.applicationDidEnterBackground()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        Self.activeScenes.remove(scene.session.persistentIdentifier)
        Self.updateKeyboardLease()
        WriterWiring.sceneWillResignActive()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        WriterWiring.sceneWillEnterForeground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Self.activeScenes.insert(scene.session.persistentIdentifier)
        Self.updateKeyboardLease()
        WriterWiring.sceneDidBecomeActive()
    }
}
