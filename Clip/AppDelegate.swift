//
//  AppDelegate.swift
//  Clip
//

import UIKit
import UserNotifications
import os

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let logger = Logger(subsystem: "com.hpiddy.clip", category: "push")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
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
        NotificationManager.requestAuthorization()
        Task {
            await SocialMessageCenter.shared.ensureSubscription()
            await SocialMessageCenter.shared.processInbox()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        logger.info("Registered for remote notifications (\(deviceToken.count) byte token).")
    }

    /// Silent push from the CloudKit subscription: a message record matching
    /// our UUID was created. Drain the inbox, even in the background.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            await SocialMessageCenter.shared.processInbox()
            completionHandler(.newData)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on simulators without push support; foreground polling covers it.
        logger.error("Remote notification registration failed: \(String(describing: error), privacy: .public)")
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
