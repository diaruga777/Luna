//
//  AppDelegate.swift
//  Clip
//

import ClipReadingList
import ClipPriceUI
import ClipReaderUI
import ClipSemantic
import ClipSocial
import ClipMediaDownload
import ClipDesignSystem
import ClipStorage
import ClipTransitions
import BackgroundTasks
import UIKit
import UserNotifications
import os

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let logger = Logger(subsystem: "com.hpiddy.clip", category: "push")
    /// Background inbox poll — a fallback for unreliable silent pushes (it
    /// doesn't depend on the push pipeline at all).
    private static let inboxRefreshTaskID = "com.hpiddy.clip.inboxRefresh"
    /// Heavier periodic task (~twice daily) that fetches new email and forwards
    /// it to Kindle, so newsletters are delivered even if the app is never
    /// opened. Separate from the inbox refresh: it needs network and runs less
    /// often.
    private static let mailFetchTaskID = "com.hpiddy.clip.mailFetch"
    private static let mailFetchInterval: TimeInterval = 12 * 60 * 60
    /// Periodic task (~every 12h) that re-fetches every non-archived price
    /// tracker's store prices and fires a local notification on a first drop past
    /// threshold. Processing-class (needs network) like the mail fetch.
    private static let priceRefreshTaskID = "com.hpiddy.clip.priceRefresh"
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
        recordEnvironmentSnapshot()

        // Install the in-app "Read instead" behavior for the price-tracking editor
        // (now shared with the extensions in ShareKit, which can't reference the
        // ingestor): a forced-article re-save, no re-detection back into a tracker.
        PriceTrackingViewController.defaultSaveAsArticle = { urlString in
            Task { await ReadingListIngestor.shared.saveAsArticle(urlString: urlString) }
        }

        // Diagnostics export header pulls messaging identity + CloudKit container
        // from the social layer (which lives above ClipStorage), injected here.
        DiagnosticLog.exportIdentityProvider = {
            KeychainIdentityStore.shared.loadIdentity()?.uuid.uuidString ?? "none"
        }
        DiagnosticLog.exportCloudKitContainer = { CloudKitMessageTransport.containerID }

        // The confirmation toast lives in ClipDesignSystem (below ClipTransitions), so
        // its Dot Matrix pixelate-in appearance is injected here. The pill assembles
        // dot-by-dot when the pixel-wipe is enabled, and falls back to its spring slide-up
        // when it's off / unavailable (the helper handles that gate internally).
        Toast.appearanceAnimator = { pill in
            DotMatrixAppear.pixelateIn(pill)
        }

        // A friend-shared article received over CloudKit is ingested via the main-app
        // ingestor (which lives above the social layer), injected here.
        SocialMessageCenter.ingestHandler = { item in
            Task { await ReadingListIngestor.shared.ingest(item) }
        }
        SocialMessageCenter.shareRecorder = { itemID, personUUID, username in
            SemanticIndexStore.shared.recordShare(
                itemID: itemID, personUUID: personUUID, username: username)
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

        // Social inbox: CloudKit query-subscription pushes need registration
        // every launch; the subscription save is idempotent. Pushes are only a
        // hint — the foreground processInbox calls are the source of truth.
        application.registerForRemoteNotifications()
        // Needed so the "friend shared" local notifications can appear, and so
        // they show as banners while the app is open (delegate below).
        UNUserNotificationCenter.current().delegate = self
        // New users get the prompt during onboarding's notifications step (with
        // context); only auto-request here for already-onboarded users.
        if KeychainIdentityStore.shared.loadIdentity() != nil {
            NotificationManager.requestAuthorization()
        }

        // Background polling fallback: silent CloudKit pushes are unreliable
        // (and currently broken by an iOS 26.4 regression), so also drain the
        // inbox on the system's periodic background-refresh schedule.
        let inboxRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.inboxRefreshTaskID, using: nil
        ) { [weak self] task in
            self?.handleInboxRefresh(task as? BGAppRefreshTask)
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
            "price refresh: BG task registration=\(priceRegistered) (inbox=\(inboxRegistered), mail=\(mailRegistered))",
            category: "price")
        readingListObserver = NotificationCenter.default.addObserver(
            forName: .readingListChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.schedulePriceRefresh(reason: "reading list changed")
        }

        Task {
            await SocialMessageCenter.shared.ensureSubscription()
            await SocialMessageCenter.shared.drainPendingFriendShares()
            await SocialMessageCenter.shared.processInbox()
        }
        Task { await IncomingMailImporter.shared.importNewMail() }
        // Experimental semantic sharing index — main app only (loads an NL
        // model; never run in the memory-limited intent runner). No-op when off.
        SemanticIndexer.shared.scheduleRun()
        scheduleInboxRefresh()
        scheduleMailFetch()
        schedulePriceRefresh(reason: "launch")
        refreshOverduePriceTrackersOnLaunch()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleInboxRefresh()
        scheduleMailFetch()
        schedulePriceRefresh(reason: "entered background")
    }

    private func scheduleInboxRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.inboxRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Couldn't schedule inbox refresh: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleInboxRefresh(_ task: BGAppRefreshTask?) {
        guard let task else { return }
        DiagnosticLog.shared.record("bg-refresh task fired", category: "push")
        scheduleInboxRefresh() // chain the next one
        let work = Task {
            await SocialMessageCenter.shared.processInbox(trigger: "bgRefresh")
            // Opportunistically pull mail too — the more often we run, the more
            // likely a newsletter reaches Kindle promptly.
            await IncomingMailImporter.shared.importNewMail()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            DiagnosticLog.shared.record("bg-refresh task expired", category: "push")
            work.cancel()
        }
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
        let work = Task {
            await IncomingMailImporter.shared.importNewMail()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            DiagnosticLog.shared.record("mail-fetch task expired", category: "mail")
            work.cancel()
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
        let work = Task { [weak self] in
            let outcomes = await PriceRefreshCoordinator.shared.refreshAndNotify()
            let completed = !Task.isCancelled
            task.setTaskCompleted(success: completed)
            DiagnosticLog.shared.record(
                "price refresh: background task completed success=\(completed), processed=\(outcomes.count)",
                category: "price")
            self?.schedulePriceRefresh(reason: "background completion")
        }
        task.expirationHandler = {
            // The refresher persists each tracker as it finishes and processes
            // stalest-first, so a cancelled run still made progress.
            DiagnosticLog.shared.record("price refresh: background task expired", category: "price")
            work.cancel()
            self.schedulePriceRefresh(reason: "background expiration")
        }
    }

    /// Records iCloud availability and our messaging identity at launch — the
    /// context most useful for diagnosing why a friend's share didn't arrive.
    private func recordEnvironmentSnapshot() {
        let identity = KeychainIdentityStore.shared.loadIdentity()?.uuid.uuidString ?? "none"
        DiagnosticLog.shared.record("messaging identity: \(identity)", category: "social")
        Task {
            let availability = await SocialMessageCenter.shared.availability()
            DiagnosticLog.shared.record("iCloud availability: \(availability)", category: "social")
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        logger.notice("Registered for remote notifications (\(deviceToken.count) byte token).")
        DiagnosticLog.shared.record(
            "registered for remote notifications (\(deviceToken.count)-byte token)", category: "push")
    }

    /// Silent push from the CloudKit subscription: a message record matching
    /// our UUID was created. Drain the inbox, even in the background.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let keys = userInfo.keys.map { "\($0)" }.joined(separator: ",")
        logger.notice("Remote notification received (keys: \(keys, privacy: .public)).")
        DiagnosticLog.shared.record("remote notification received (keys: \(keys))", category: "push")
        Task {
            await SocialMessageCenter.shared.processPush(userInfo: userInfo)
            completionHandler(.newData)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on simulators without push support; foreground polling covers it.
        logger.error("Remote notification registration failed: \(String(describing: error), privacy: .public)")
        DiagnosticLog.shared.record(
            "remote notification registration FAILED: \(String(describing: error))", category: "push")
    }

    /// Show friend-share notifications as banners even while the app is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Handle a notification tap. A FIRST-share notification deep-links to that
    /// friend's settings page (to enable future-share notifications); every other
    /// notification (follow-up shares, price drops) just opens the app with no
    /// in-app routing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let type = userInfo[NotificationManager.typeKey] as? String
        if type == NotificationManager.typeFriendAdded {
            await MainActor.run { SceneDelegate.routeToFriends() }
            return
        }
        guard type == NotificationManager.typeFirstShare,
              let uuidString = userInfo[NotificationManager.friendUUIDKey] as? String,
              let friendUUID = UUID(uuidString: uuidString) else { return }
        await MainActor.run { SceneDelegate.routeToFriendSettings(friendUUID: friendUUID) }
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
