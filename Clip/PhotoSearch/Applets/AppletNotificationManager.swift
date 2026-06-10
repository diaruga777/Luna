//
//  AppletNotificationManager.swift
//  clipper
//

import Foundation
import UserNotifications

/// Posts local notifications when an applet captures a match. Authorization must be
/// requested from the main app (extensions can't present the permission prompt);
/// once granted, `notifyCapture` works from both the app and the ingest extension.
protocol AppletNotificationManager: Sendable {
    /// Requests notification authorization if the user hasn't been asked yet.
    /// Safe to call repeatedly. Call from the app, e.g. when notifications are first
    /// enabled on an applet.
    func requestAuthorizationIfNeeded() async

    /// Posts an immediate local notification announcing a capture for `applet`.
    /// No-op if authorization was denied.
    func notifyCapture(_ applet: Applet) async
}

final class AppletNotificationManagerImpl: AppletNotificationManager {

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func notifyCapture(_ applet: Applet) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = applet.name
        content.body = "Captured a new match"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "applet-capture-\(applet.id.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil // immediate
        )
        try? await center.add(request)
    }
}
