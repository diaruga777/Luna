//
//  ClipTriggerNotifier.swift
//  ClipCapture
//

import Foundation
import UserNotifications

/// Fires the trigger when a pocket capture is detected. For now the action is a local
/// notification; it also records the event into the App Group so the main app (and,
/// later, a user-defined Shortcut) can react to it.
enum ClipTriggerNotifier {

    static let appGroupID = "group.com.hpiddy.clip"
    static let lastTriggerKey = "clip.lastPocketTrigger"
    static let lastTriggerBrightnessKey = "clip.lastPocketTriggerBrightness"

    static func fire(brightness: Double) {
        recordEvent(brightness: brightness)
        postNotification()
    }

    private static func recordEvent(brightness: Double) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: lastTriggerKey)
        defaults.set(brightness, forKey: lastTriggerBrightnessKey)
    }

    private static func postNotification() {
        let center = UNUserNotificationCenter.current()
        // The main app requests authorization; request here too as a best-effort no-op
        // if already granted.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Clip"
            content.body = "Pocket capture detected"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "clip.pocket.\(UUID().uuidString)",
                content: content,
                trigger: nil  // deliver immediately
            )
            center.add(request)
        }
    }
}
