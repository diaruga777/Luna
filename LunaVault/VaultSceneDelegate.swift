import UIKit

final class VaultSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let root = NSClassFromString("XCTestCase") == nil ? VaultConnectedWiring.makeRootViewController() : UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigation
        self.window = window
        window.makeKeyAndVisible()
        if let url = connectionOptions.urlContexts.first?.url { openPairing(url) }
    }
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { openPairing(url) }
    }
    func sceneDidBecomeActive(_ scene: UIScene) { VaultConnectedWiring.applicationWillEnterForeground() }
    func sceneDidEnterBackground(_ scene: UIScene) { VaultConnectedWiring.applicationDidEnterBackground() }
    private func openPairing(_ url: URL) {
        guard ["luna-vault", "lunavault"].contains(url.scheme ?? ""), url.host == "pair",
              let controller = VaultConnectedWiring.pairingController(code: url.absoluteString),
              let navigation = window?.rootViewController as? UINavigationController else { return }
        navigation.pushViewController(controller, animated: true)
    }
}
