//
//  NotificationManager.swift
//  LunaSocial
//

import LunaStorage
import Foundation
import UserNotifications
import LunaModels

/// Local-notification helper for share events. The email importer surfaces
/// results here when a recognized share lands. Authorization is requested once
/// so notifications can appear.
public enum NotificationManager {

    // MARK: - userInfo keys / values

    /// `userInfo` key distinguishing a notification's kind (for tap routing and
    /// bulk dismissal).
    public static let typeKey = "lunaNotificationType"
    /// A new pending request from someone who isn't a friend yet — tapping it
    /// opens the Pending Requests screen.
    /// An accepted friend's share was imported — tapping it just opens the app;
    /// these are cleared when the user reaches the saves list.
    private static let typeShareReceived = "shareReceived"
    private static let receivedIdentifierPrefix = "shareReceived-"

    /// Requests alert/sound authorization (no-op if already decided).
    ///
    /// Called only from the moments a user opts into something Luna will notify
    /// about — the Save of the Week key, connecting a sending account, committing a
    /// price alert threshold. Launch does not ask (see `AppDelegate`).
    ///
    /// Skipped in an extension process: the price editor is reachable from the share
    /// and action sheets, and this prompt is a ONE-TIME decision — spending it on a
    /// sheet that is about to dismiss (with no app around it to explain why it
    /// appeared) risks a silent no. The next in-app commit asks properly.
    public static func requestAuthorization() {
        guard !isAppExtension else {
            DiagnosticLog.shared.record(
                "notification authorization skipped in extension", category: "push")
            return
        }
        // The prompt is up the moment we ask, so the latch is set here rather than in
        // the callback: "has the user been asked" is true whatever they answer, and
        // even if they never answer at all.
        NotificationAuthorizationState.markRequested()
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { granted, error in
            if let error {
                DiagnosticLog.shared.record(
                    "notification authorization error: \(String(describing: error))", category: "push")
            } else {
                DiagnosticLog.shared.record(
                    "notification authorization granted: \(granted)", category: "push")
            }
        }
    }

    /// Reads the REAL system authorization status and latches
    /// `NotificationAuthorizationState.hasEverBeenRequested` when it is no longer
    /// `.notDetermined`. Returns the same answer, so an async caller can use it
    /// directly instead of the cache. Safe in an `.appex` (reading settings is
    /// allowed there; only asking is not).
    @discardableResult
    public static func refreshAuthorizationRequestedState() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
        let determined = status != .notDetermined
        NotificationAuthorizationState.recordSystemStatus(determined: determined)
        return determined
    }

    /// Fire-and-forget form for synchronous callers (a view controller appearing).
    public static func refreshAuthorizationRequestedStateInBackground() {
        Task { await refreshAuthorizationRequestedState() }
    }

    static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// Posts "X shared an article" for an accepted friend's import. A follow-up
    /// notification: tapping it opens the app and it auto-dismisses when the user
    /// reaches the saves list.
    public static func postShareReceived(fromName name: String, title: String?) {
        let content = UNMutableNotificationContent()
        content.title = L10n.string("Sharing_notification_shareReceived_headline", name)
        content.body = title ?? L10n.string("Sharing_notification_shareReceived_message")
        content.sound = .default
        content.userInfo = [typeKey: typeShareReceived]
        post(content, identifier: receivedIdentifierPrefix + UUID().uuidString)
    }

    /// Removes delivered "share received" notifications (called when the user
    /// reaches the saves list).
    public static func clearShareNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.userInfo[typeKey] as? String == typeShareReceived }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Posts a price-drop alert when a tracked product first drops past its
    /// threshold during a background refresh.
    public static func postPriceDrop(productName: String, newPrice: String, discountPercent: Int) {
        let content = UNMutableNotificationContent()
        content.title = L10n.string("Sharing_notification_priceDrop_headline", productName)
        content.body = L10n.string("Sharing_notification_priceDrop_message", newPrice, discountPercent)
        content.sound = .default
        post(content)
    }

    private static func post(
        _ content: UNMutableNotificationContent, identifier: String = UUID().uuidString) {
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
