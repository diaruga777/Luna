//
//  AppDelegate.swift
//  Clip
//

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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        DiagnosticLog.shared.record("app launch", category: "lifecycle")
        // Move reader settings into the App Group so the share-extension reader
        // honors them (WPM, font, highlight color, …).
        ReaderSettings.migrateFromStandardIfNeeded()
        recordEnvironmentSnapshot()

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
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.inboxRefreshTaskID, using: nil
        ) { [weak self] task in
            self?.handleInboxRefresh(task as? BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.mailFetchTaskID, using: nil
        ) { [weak self] task in
            self?.handleMailFetch(task as? BGProcessingTask)
        }

        Task {
            await SocialMessageCenter.shared.ensureSubscription()
            await SocialMessageCenter.shared.drainPendingFriendShares()
            await SocialMessageCenter.shared.processInbox()
        }
        Task { await IncomingMailImporter.shared.importNewMail() }
        scheduleInboxRefresh()
        scheduleMailFetch()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleInboxRefresh()
        scheduleMailFetch()
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
