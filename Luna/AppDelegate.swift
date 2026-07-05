//
//  AppDelegate.swift
//  Luna
//

import LunaReadingList
import LunaPriceUI
import LunaReaderUI
import LunaSemantic
import LunaSocial
import LunaSocialUI
import LunaMailAccount
import LunaMailTransport
import LunaSend
import LunaMediaDownload
import LunaDesignSystem
import LunaStorage
import LunaTransitions
import BackgroundTasks
import UIKit
import UserNotifications
import os

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let logger = Logger(subsystem: "com.hsanabria.luna", category: "push")
    /// Periodic task (~twice daily) that reads new mail: imports Luna shares
    /// (friends' auto-import; strangers → pending requests) and matched
    /// newsletters, so shares arrive even if the app is never opened.
    private static let mailFetchTaskID = "com.hsanabria.luna.mailFetch"
    private static let mailFetchInterval: TimeInterval = 12 * 60 * 60
    /// Periodic task (~every 12h) that re-fetches every non-archived price
    /// tracker's store prices and fires a local notification on a first drop past
    /// threshold. Processing-class (needs network) like the mail fetch.
    private static let priceRefreshTaskID = "com.hsanabria.luna.priceRefresh"
    private static let priceRefreshInterval: TimeInterval = 12 * 60 * 60
    private var readingListObserver: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        DiagnosticLog.shared.record("app launch", category: "lifecycle")
        // Move reader settings into the App Group so the share-extension reader
        // honors them (WPM, font, highlight color, …).
        ReaderSettings.migrateFromStandardIfNeeded()
        let account = EmailAccountStore.shared.account?.address ?? "none"
        DiagnosticLog.shared.record("email account: \(account)", category: "mail")

        // Install the in-app "Read instead" behavior for the price-tracking editor
        // (now shared with the extensions in ShareKit, which can't reference the
        // ingestor): a forced-article re-save, no re-detection back into a tracker.
        PriceTrackingViewController.defaultSaveAsArticle = { urlString in
            Task { await ReadingListIngestor.shared.saveAsArticle(urlString: urlString) }
        }

        // Diagnostics export header shows the connected email account (which lives
        // above LunaStorage), injected here.
        DiagnosticLog.exportIdentityProvider = {
            EmailAccountStore.shared.account?.address ?? "none"
        }

        // Let the share sheet launch the email-account login flow when no account
        // is connected yet.
        SendToFriendSheet.accountSetupLauncher = { presenter in
            EmailLoginFlow.present(from: presenter)
        }

        // Send-to-Kindle emails go out through the connected email account.
        // LunaSend sits below LunaMailTransport, so the transport factory is
        // injected here (extensions leave it nil → Kindle sends are no-ops there).
        ArticleEmailTransportProvider.make = { MailTransportFactory.make() }

        // Modally-presented header screens (LunaDesignSystem sits below
        // LunaTransitions, so the wipe is injected) dismiss through the pixel wipe.
        NavHeaderTableController.modalDismisser = { DotMatrixModal.dismiss($0) }

        // The keyboard's appearance dissolves in as dots too (its window can't be
        // snapshotted, so the reveal dissolves the pre-keyboard pixels OUT instead).
        DotMatrixKeyboardReveal.install {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
        }
        // Pay the keyboard's one-time bring-up cost after launch settles, not on the
        // first tap that needs a text field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            DotMatrixKeyboardReveal.prewarmKeyboard()
        }

        // Wire the read-aloud first-run prompt's "Open Settings" to push the
        // Voice settings screen. Setting this hook is what enables the prompt in
        // the main app (extensions leave it nil → the prompt is skipped).
        VoiceFirstRunPrompt.openVoiceSettings = { presenter in
            let voice = VoiceSettingsScreen()
            if let nav = presenter.navigationController {
                nav.pushViewController(voice, animated: true)
            } else {
                let nav = UINavigationController(rootViewController: voice)
                nav.installDotMatrixTransitions()
                DotMatrixModal.present(nav, from: presenter)
            }
        }

        // Sweep any downloaded-but-never-saved media preview files orphaned by a
        // previous run that was killed before its preview screen could clean up.
        // Safe at launch (no preview is open yet); off the main thread to not
        // block startup.
        DispatchQueue.global(qos: .utility).async { MediaDownloadStorage.purgeAll() }

        // Warm the Wi-Fi reachability monitor (background preloads are Wi-Fi-gated) and
        // run the one-time image-ownership backfill so images shared with pre-existing
        // saves/preloads are reference-counted before any preload release could delete one.
        DispatchQueue.global(qos: .utility).async {
            _ = NetworkReachability.shared
            ImageReferenceStore.shared.backfillIfNeeded(readingList: .shared, preloads: .shared)
        }

        // Retry any items whose content download didn't finish (e.g. saved from the
        // background intent without network time).
        ReadingListIngestor.shared.ingestAllPending()
        ArticleSendCoordinator.shared.retryPendingSends()
        LiveMediaDownloadManager.shared.resumeLiveActivities()

        // Local notifications: show as banners while open (delegate below) and,
        // for already-onboarded users, ensure authorization (new users get the
        // prompt during onboarding's notifications step, with context).
        UNUserNotificationCenter.current().delegate = self
        if UserDefaults.standard.bool(forKey: SceneDelegate.onboardingCompleteKey) {
            NotificationManager.requestAuthorization()
        }

        let mailRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.mailFetchTaskID, using: nil
        ) { [weak self] task in
            self?.handleMailFetch(task as? BGProcessingTask)
        }
        let priceRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.priceRefreshTaskID, using: nil
        ) { [weak self] task in
            self?.handlePriceRefresh(task as? BGProcessingTask)
        }
        DiagnosticLog.shared.record(
            "BG task registration: mail=\(mailRegistered), price=\(priceRegistered)",
            category: "price")
        readingListObserver = NotificationCenter.default.addObserver(
            forName: .readingListChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.schedulePriceRefresh(reason: "reading list changed")
        }

        // Read incoming mail (Luna shares + newsletters) — all surfaces.
        Task { await IncomingMailImporter.shared.importNewMail() }
        // Semantic search index — main app only (loads an NL model; never in the
        // memory-limited intent runner). No-op when nothing needs embedding.
        SemanticIndexer.shared.scheduleRun()
        scheduleMailFetch()
        schedulePriceRefresh(reason: "launch")
        refreshOverduePriceTrackersOnLaunch()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        ArticleSendCoordinator.shared.retryPendingSends()
        LiveMediaDownloadManager.shared.resumeLiveActivities()
        scheduleMailFetch()
        schedulePriceRefresh(reason: "entered background")
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        LiveMediaDownloadManager.shared.attachBackgroundCompletionHandler(completionHandler)
    }

    private func scheduleMailFetch() {
        let request = BGProcessingTaskRequest(identifier: Self.mailFetchTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.mailFetchInterval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Couldn't schedule mail fetch: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleMailFetch(_ task: BGProcessingTask?) {
        guard let task else { return }
        DiagnosticLog.shared.record("mail-fetch task fired", category: "mail")
        scheduleMailFetch() // chain the next one (~twice daily)
        // Expiration handler installed BEFORE the work starts, and an expired
        // run reports failure — mirrors handlePriceRefresh, so the scheduler's
        // model of this task stays honest.
        var work: Task<Void, Never>?
        task.expirationHandler = {
            DiagnosticLog.shared.record("mail-fetch task expired", category: "mail")
            work?.cancel()
        }
        work = Task {
            await IncomingMailImporter.shared.importNewMail()
            ArticleSendCoordinator.shared.retryPendingSends()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
    }

    private func schedulePriceRefresh(reason: String) {
        let trackers = ReadingListStore.shared.priceTrackersStalestFirst()
        let activeTrackers = trackers.count
        guard activeTrackers > 0 else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.priceRefreshTaskID)
            DiagnosticLog.shared.record(
                "price refresh: no active trackers; cancelled schedule (\(reason))", category: "price")
            return
        }
        // IDEMPOTENT scheduling. We are called on many events (launch, foreground,
        // EVERY reading-list change, after a run); the old code cancelled and
        // resubmitted the request each time. Repeatedly cancelling+resubmitting a
        // BGTask churns it so iOS never lets it mature/run — the "never fires" bug.
        // So if a request is ALREADY pending, leave it untouched; only submit when
        // nothing is pending (the first tracker, or after a run/expiration consumed
        // it). The earliest date is derived from the oldest actual refresh (not now),
        // so a never-refreshed tracker still fires ASAP. The next run reschedules.
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] pending in
            guard let self else { return }
            if pending.contains(where: { $0.identifier == Self.priceRefreshTaskID }) {
                DiagnosticLog.shared.record(
                    "price refresh: request already pending; left undisturbed (\(reason))",
                    category: "price")
                return
            }
            let request = BGProcessingTaskRequest(identifier: Self.priceRefreshTaskID)
            let oldestRefresh = trackers
                .map { ReadingListStore.stalestRefresh($0.priceTracker) }
                .min() ?? .distantPast
            let dueDate = oldestRefresh.addingTimeInterval(Self.priceRefreshInterval)
            request.earliestBeginDate = max(Date(), dueDate)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            do {
                try BGTaskScheduler.shared.submit(request)
                DiagnosticLog.shared.record(
                    "price refresh: scheduled \(activeTrackers) active tracker(s), earliest=\(request.earliestBeginDate?.description ?? "unknown") (\(reason))",
                    category: "price")
            } catch {
                self.logger.error("Couldn't schedule price refresh: \(String(describing: error), privacy: .public)")
                DiagnosticLog.shared.record(
                    "price refresh: schedule FAILED (\(reason)): \(error)", category: "price")
            }
        }
    }

    /// iOS decides when a BGProcessingTask actually runs, and it may defer it
    /// for power or scheduling reasons. When the user opens the app with a stale
    /// tracker, make that missed background work up immediately rather than
    /// leaving the displayed price stale until the OS grants another launch.
    private func refreshOverduePriceTrackersOnLaunch() {
        let trackers = ReadingListStore.shared.priceTrackersStalestFirst()
        guard let oldest = trackers
            .map({ ReadingListStore.stalestRefresh($0.priceTracker) })
            .min(),
              oldest.addingTimeInterval(Self.priceRefreshInterval) <= Date()
        else { return }

        DiagnosticLog.shared.record(
            "price refresh: launch fallback started for \(trackers.count) overdue active tracker(s)",
            category: "price")
        Task { [weak self] in
            let outcomes = await PriceRefreshCoordinator.shared.refreshAndNotify()
            DiagnosticLog.shared.record(
                "price refresh: launch fallback completed, processed=\(outcomes.count)",
                category: "price")
            self?.schedulePriceRefresh(reason: "launch fallback completion")
        }
    }

    private func handlePriceRefresh(_ task: BGProcessingTask?) {
        guard let task else {
            DiagnosticLog.shared.record("price refresh: handler received wrong task type", category: "price")
            return
        }
        DiagnosticLog.shared.record("price refresh: background task started", category: "price")
        // Expiration handler installed BEFORE the work starts, and an expired run
        // reports failure — mirrors handleMailFetch, so an expiration landing
        // immediately never finds the task without a handler.
        var work: Task<Void, Never>?
        task.expirationHandler = {
            // The refresher persists each tracker as it finishes and processes
            // stalest-first, so a cancelled run still made progress.
            DiagnosticLog.shared.record("price refresh: background task expired", category: "price")
            work?.cancel()
            self.schedulePriceRefresh(reason: "background expiration")
        }
        work = Task { [weak self] in
            let outcomes = await PriceRefreshCoordinator.shared.refreshAndNotify()
            ArticleSendCoordinator.shared.retryPendingSends()
            let completed = !Task.isCancelled
            task.setTaskCompleted(success: completed)
            DiagnosticLog.shared.record(
                "price refresh: background task completed success=\(completed), processed=\(outcomes.count)",
                category: "price")
            self?.schedulePriceRefresh(reason: "background completion")
        }
    }

    /// Show share notifications as banners even while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Handle a notification tap. A pending-request notification deep-links to
    /// the Pending Requests screen; everything else just opens the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if userInfo[NotificationManager.typeKey] as? String == NotificationManager.typePendingRequest {
            await MainActor.run { SceneDelegate.routeToPendingRequests() }
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = SceneDelegate.self
        return config
    }
}
