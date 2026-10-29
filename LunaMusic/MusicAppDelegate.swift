import LunaPremium
import UIKit
import CarPlay
import BackgroundTasks
import UserNotifications
import LunaMusicCore
import LunaPodcastCore

@main
final class MusicAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PremiumAccess.shared.start()
        MediaPlaybackCoordinator.shared.install()
        PodcastBackgroundServices.shared.start()
        MusicVaultWiring.install()
        MusicSystemIntegration.shared.start()
        if NSClassFromString("XCTestCase") == nil {
            AutomationEntityIndex.install {
                try await AutomationEntityIndex.replace(PodcastEpisodeEntity.self, entities: PodcastEpisodeQuery().all())
                try await AutomationEntityIndex.replace(PodcastShowEntity.self, entities: PodcastShowQuery().all())
                try await AutomationEntityIndex.replace(PodcastStationEntity.self, entities: PodcastStationQuery().all())
            }
        }
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
        PodcastEpisodeNotifications.shared.register()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            Task { @MainActor in
                self.schedule()
                let work = Task { @MainActor in
                    await PodcastLibraryController.shared.refresh(minimumInterval: PodcastPolicies.refreshInterval)
                    if !Task.isCancelled { await PodcastDownloads.shared.prepareExistingDownloads() }
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
        timer = Timer.scheduledTimer(withTimeInterval: PodcastPolicies.refreshInterval, repeats: true) { _ in
            Task { @MainActor in await PodcastLibraryController.shared.refresh(minimumInterval: PodcastPolicies.refreshInterval); try? await PodcastCloudSync.shared.synchronize() }
        }
        Task {
            let library = PodcastLibraryController.shared
            if library.state.shows.values.contains(where: { $0.followed && $0.settings.notifications }) {
                await PodcastEpisodeNotifications.shared.requestPermissionIfNeeded()
            }
            await library.refresh(minimumInterval: PodcastPolicies.refreshInterval)
            try? await PodcastCloudSync.shared.synchronize()
        }
    }
    func background() {
        timer?.invalidate(); timer = nil; PodcastPlaybackController.shared.persistPosition(); schedule()
        Task { await PodcastDownloads.shared.prepareExistingDownloads() }
    }
    private func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier); request.earliestBeginDate = Date().addingTimeInterval(PodcastPolicies.refreshInterval)
        do { try BGTaskScheduler.shared.submit(request) } catch { /* Foreground polling remains available if background refresh is disabled. */ }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["podcastEpisodeID"] as? String else { return }
        await MainActor.run {
            switch PodcastEpisodeNotifications.action(for: response.actionIdentifier) {
            case .open:
                MusicIntentRoute.pendingPodcastEpisodeID = id
                NotificationCenter.default.post(name: .lunaPodcastOpenEpisode, object: nil, userInfo: ["id": id])
            case .addToQueue, .playNext:
                let library = PodcastLibraryController.shared
                do {
                    try PodcastEpisodeNotifications.shared.enqueue(id, next: response.actionIdentifier == PodcastEpisodeNotifications.playNextID, in: library)
                } catch { library.report(error) }
            case .ignore: break
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix("luna.change.") ? [.list] : [.banner, .list, .sound]
    }
}
