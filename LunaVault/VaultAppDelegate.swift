import UIKit

@main
final class VaultAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        VaultWiring.install()
        // Vault is independent from the shared link-save `saves.sqlite` store;
        // its repository and optional paired-Mac backend are built by the
        // scene's VaultWiring composition seam.
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        VaultWiring.applicationDidEnterBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        VaultWiring.applicationWillEnterForeground()
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role)
        configuration.delegateClass = VaultSceneDelegate.self
        return configuration
    }
}
