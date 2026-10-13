import UIKit
import CarPlay
import BackgroundTasks
import UserNotifications
import LunaMusicCore
import LunaPodcastCore

@main
final class MusicAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MediaPlaybackCoordinator.shared.install()
        PodcastBackgroundServices.shared.start()
        MusicVaultWiring.install()
        MusicSystemIntegration.shared.start()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == PodcastDownloads.sessionIdentifier {
            PodcastDownloads.shared.backgroundCompletion = completionHandler
            Task { await PodcastDownloads.shared.start() }
        } else if identifier == PodcastDownloads.hlsSessionIdentifier {
            PodcastDownloads.shared.hlsBackgroundCompletion = completionHandler
            Task { await PodcastDownloads.shared.start() }
        } else { completionHandler() }
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(name: "MusicCarPlay", sessionRole: session.role)
            configuration.sceneClass = CPTemplateApplicationScene.self
            configuration.delegateClass = MusicCarPlaySceneDelegate.self
            return configuration
        }
        let configuration = UISceneConfiguration(name: "Music", sessionRole: session.role)
        configuration.delegateClass = MusicSceneDelegate.self
        return configuration
    }
}


@MainActor final class PodcastBackgroundServices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PodcastBackgroundServices()
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.music") + ".podcast-refresh" }
    private var timer: Timer?
    func start() {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            Task { @MainActor in
                self.schedule()
                let work = Task { @MainActor in
                    await PodcastLibraryController.shared.refresh()
                    if !Task.isCancelled { try? await PodcastCloudSync.shared.synchronize() }
                    task.setTaskCompleted(success: !Task.isCancelled)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
        Task { await PodcastDownloads.shared.reconcile() }
        schedule()
    }
    func foreground() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in
            Task { @MainActor in await PodcastLibraryController.shared.refresh(); try? await PodcastCloudSync.shared.synchronize() }
        }
        Task { await PodcastLibraryController.shared.refresh(); try? await PodcastCloudSync.shared.synchronize() }
    }
    func background() { timer?.invalidate(); timer = nil; PodcastPlaybackController.shared.persistPosition(); schedule() }
    private func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier); request.earliestBeginDate = Date().addingTimeInterval(900)
        do { try BGTaskScheduler.shared.submit(request) } catch { /* Foreground polling remains available if background refresh is disabled. */ }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["podcastEpisodeID"] as? String else { return }
        await MainActor.run {
            MusicIntentRoute.pendingPodcastEpisodeID = id
            NotificationCenter.default.post(name: .lunaPodcastOpenEpisode, object: nil, userInfo: ["id": id])
        }
    }
}
