import BackgroundTasks
import UIKit
import LunaVaultUI

@main
final class VaultAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Unit tests inject isolated stores/transports. Never reconnect the
        // user's real paired Mac just because the app is their test host.
        if NSClassFromString("XCTestCase") == nil {
            registerBackgroundTasks()
            VaultConnectedWiring.install()
        }
        // Vault is independent from the shared link-save `saves.sqlite` store;
        // its repository and optional paired-Mac backend are built by the
        // scene's VaultWiring composition seam.
        return true
    }

    /// Registers every Vault BGTask identifier exactly once, before launch
    /// finishes, matching `BGTaskScheduler`'s register-once-before-launch-ends
    /// contract. `VaultWiring` rebuilds the sync runtime and the background
    /// scheduler on setup completion and on Settings changes; these launch
    /// handlers route to whichever instance is current when a task fires
    /// instead of registering again, so neither rebuild can crash on a
    /// duplicate registration.
    private func registerBackgroundTasks() {
        // Mirrors the fallback `VaultBackgroundTaskScheduler.identifierPrefix`
        // uses in `KindWiring+Vault.installBackgroundRuntime`, so a nil bundle
        // identifier can never register one set of identifiers and submit
        // requests under another.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault"
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: bundleID + ".sync", using: nil
        ) { task in
            Task { @MainActor in VaultConnectedWiring.handleSyncBackgroundTask(task) }
        }
        let maintenanceKinds: [VaultBackgroundTaskKind] = [.importRepair, .index, .thumbnailMaintenance]
        for kind in maintenanceKinds {
            let identifier = bundleID + "." + kind.rawValue
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier, using: nil
            ) { task in
                Task { @MainActor in VaultConnectedWiring.handleMaintenanceBackgroundTask(task, kind: kind) }
            }
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        VaultConnectedWiring.applicationDidEnterBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        VaultConnectedWiring.applicationWillEnterForeground()
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
