//
//  NotificationManager.swift
//  Lune
//

import LuneStorage
import Foundation
import UserNotifications

/// Local-notification helper for social events. Silent CloudKit pushes wake the
/// app to drain the inbox; this surfaces the decrypted result to the user (a
/// CloudKit push can't carry the encrypted content itself). Authorization is
/// requested once at launch so notifications can actually appear.
public enum NotificationManager {

    // MARK: - userInfo keys / values

    /// `userInfo` key distinguishing a notification's kind (for tap routing and
    /// bulk dismissal).
    public static let typeKey = "luneNotificationType"
    /// `userInfo` key carrying the sharing friend's UUID string.
    public static let friendUUIDKey = "luneFriendUUID"
    /// The first-ever share from a friend — tapping it deep-links to that
    /// friend's settings page.
    public static let typeFirstShare = "friendFirstShare"
    /// A follow-up (not first) friend share — tapping it just opens the app;
    /// these are cleared when the user reaches the reading list.
    public static let typeShareFollowup = "friendShareFollowup"
    /// Someone added you as a friend — tapping it opens the in-app friends list.
    public static let typeFriendAdded = "friendAdded"
    /// Identifier prefix for follow-up share notifications, so they can be
    /// removed in bulk without disturbing first-share (or other) notifications.
    private static let followupIdentifierPrefix = "friendShareFollowup-"

    /// Requests alert/sound authorization (no-op if already decided).
    public static func requestAuthorization() {
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

    /// Posts "X shared an article" when a friend with notifications enabled
    /// sends us a link. A follow-up (not first) share: tapping it just opens the
    /// app, and it auto-dismisses once the user reaches the reading list.
    public static func postArticleShared(fromUsername username: String, title: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(username) shared an article"
        content.body = title ?? "Open Lune to read it."
        content.sound = .default
        content.userInfo = [typeKey: typeShareFollowup]
        post(content, identifier: followupIdentifierPrefix + UUID().uuidString)
    }

    /// Posts the FIRST-ever share from a friend, which always notifies (regardless
    /// of the per-friend toggle). Tapping it deep-links to that friend's settings
    /// page so the user can turn on future-share notifications.
    public static func postFirstShare(fromUsername username: String, friendUUID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "\(username) shared w/ you for the first time!"
        content.subtitle = "To see future shares from \(username), go to settings"
        content.sound = .default
        content.userInfo = [typeKey: typeFirstShare, friendUUIDKey: friendUUID.uuidString]
        // One first-share prompt per friend (a later first-share, e.g. after the
        // friend was re-added, replaces the prior one rather than stacking).
        post(content, identifier: "friendFirstShare-\(friendUUID.uuidString)")
    }

    /// Posts "X added you as a friend" when someone adds us back (a new friend
    /// appears in our inbox). Tapping it opens the in-app friends list.
    public static func postFriendAdded(fromUsername username: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(username) added you as a friend"
        content.sound = .default
        content.userInfo = [typeKey: typeFriendAdded]
        post(content)
    }

    /// Removes any delivered follow-up share notifications (called when the user
    /// reaches the reading list). Leaves first-share prompts intact.
    public static func clearFollowupShareNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.userInfo[typeKey] as? String == typeShareFollowup }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Posts a price-drop alert when a tracked product first drops past its
    /// threshold during a background refresh.
    public static func postPriceDrop(productName: String, newPrice: String, discountPercent: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Price drop: \(productName)"
        content.body = "Now \(newPrice) — \(discountPercent)% off what you were watching."
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
