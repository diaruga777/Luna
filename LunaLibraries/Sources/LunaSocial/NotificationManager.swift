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
    public static let typePendingRequest = "pendingRequest"
    /// An accepted friend's share was imported — tapping it just opens the app;
    /// these are cleared when the user reaches the reading list.
    public static let typeShareReceived = "shareReceived"
    private static let receivedIdentifierPrefix = "shareReceived-"

    /// Requests alert/sound authorization (no-op if already decided).
    ///
    /// Idempotent — the system shows its prompt at most once per install, so every
    /// opt-in site can call this without state of its own. It also self-skips inside
    /// an `.appex`: an app extension has no standing to ask (the prompt belongs to
    /// the host app), so the share/action extensions that embed the same price editor
    /// simply do nothing here.
    public static func requestAuthorization() {
        guard !isAppExtension else { return }
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

    /// Whether the permission prompt has EVER been shown (granted or denied), from
    /// the shared App-Group latch — synchronous, and readable from an `.appex`.
    /// Features that must decide *before* the user has opted in (a new price
    /// tracker's alert threshold) read this; `refreshAuthorizationRequestedState()`
    /// keeps it true to the system.
    public static var hasEverRequestedAuthorization: Bool {
        NotificationAuthorizationState.hasEverBeenRequested
    }

    /// Reads the REAL system authorization status and latches
    /// `hasEverRequestedAuthorization` when it is no longer `.notDetermined`.
    /// Returns the same answer, so an async caller can use it directly instead of
    /// the cache. Safe in an `.appex` (reading settings is allowed there; only
    /// asking is not).
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
    /// reaches the reading list.
    public static func postShareReceived(fromName name: String, title: String?) {
        let content = UNMutableNotificationContent()
        content.title = L10n.string("\(name) shared an article")
        content.body = title ?? L10n.string("Open Luna to read it.")
        content.sound = .default
        content.userInfo = [typeKey: typeShareReceived]
        post(content, identifier: receivedIdentifierPrefix + UUID().uuidString)
    }

    /// Removes delivered "share received" notifications (called when the user
    /// reaches the reading list).
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
        content.title = L10n.string("Price drop: \(productName)")
        content.body = L10n.string("Now \(newPrice) — \(discountPercent)% off what you were watching.")
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
