import UIKit

@main
final class WriterAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        WriterWiring.install()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        WriterWiring.applicationDidEnterBackground()
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role)
        configuration.delegateClass = WriterSceneDelegate.self
        return configuration
    }
}
