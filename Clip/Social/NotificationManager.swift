//
//  NotificationManager.swift
//  Clip
//

import Foundation
import UserNotifications

/// Local-notification helper for social events. Silent CloudKit pushes wake the
/// app to drain the inbox; this surfaces the decrypted result to the user (a
/// CloudKit push can't carry the encrypted content itself). Authorization is
/// requested once at launch so notifications can actually appear.
enum NotificationManager {

    /// Requests alert/sound authorization (no-op if already decided).
    static func requestAuthorization() {
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
    /// sends us a link.
    static func postArticleShared(fromUsername username: String, title: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(username) shared an article"
        content.body = title ?? "Open Clip to read it."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
