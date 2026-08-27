import UIKit

@main
final class VaultAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Stage 1 deliberately performs no provider access and never touches
        // the shared `saves.sqlite`; Vault's store is `vault.sqlite`.
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
