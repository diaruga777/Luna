import UIKit
import LunaDesignSystem

final class WriterSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

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
}
