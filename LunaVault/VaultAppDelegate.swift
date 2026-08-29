import UIKit

@main
final class VaultAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Vault is independent from the shared link-save `saves.sqlite` store;
        // its repository and optional paired-Mac backend are built by the
        // scene's VaultWiring composition seam.
        return true
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
