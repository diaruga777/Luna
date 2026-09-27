import UIKit

@main
final class MusicAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MusicSystemIntegration.shared.start()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Music", sessionRole: session.role)
        configuration.delegateClass = MusicSceneDelegate.self
        return configuration
    }
}
