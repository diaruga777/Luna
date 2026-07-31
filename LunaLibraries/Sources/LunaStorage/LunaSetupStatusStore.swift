//
//  LunaSetupStatusStore.swift
//  LunaStorage
//

import LunaAppConfig
import Foundation

/// Shared "has ever worked" markers for the left setup tray.
///
/// Faceted apps share one completion marker. Central Luna intentionally keeps
/// its own marker because its own Safari extension and shortcut must each run.
public final class LunaSetupStatusStore {
    public static let shared = LunaSetupStatusStore()
    public static let didChange = Notification.Name("LunaSetupStatusStore.didChange")

    public static let sharedSafariKey = "setup.safari.hasRun.shared"
    public static let centralSafariKey = "setup.safari.hasRun.luna"
    public static let sharedShortcutKey = "setup.shortcut.hasRun.shared"
    public static let centralShortcutKey = "setup.shortcut.hasRun.luna"

    private static var darwinNotificationName: String {
        "\(AppConfig.appGroupID).setupStatusChanged"
    }
    private static var isObservingCrossProcessChanges = false

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
    }

    public func safariHasRun(isCentral: Bool) -> Bool {
        defaults.bool(forKey: isCentral ? Self.centralSafariKey : Self.sharedSafariKey)
    }

    public func shortcutHasRun(isCentral: Bool) -> Bool {
        defaults.bool(forKey: isCentral ? Self.centralShortcutKey : Self.sharedShortcutKey)
    }

    public func recordShortcutRun(isCentral: Bool) {
        defaults.set(true, forKey: isCentral ? Self.centralShortcutKey : Self.sharedShortcutKey)
        Self.postChange()
    }

    /// Erases every "has ever worked" marker — the Safari extension's and the
    /// App Intents' — across the shared and central facets. The diagnostics
    /// onboarding reset uses this so a re-run must gather fresh evidence.
    public func resetAllRunEvidence() {
        for key in [
            Self.sharedSafariKey,
            Self.centralSafariKey,
            Self.sharedShortcutKey,
            Self.centralShortcutKey,
        ] {
            defaults.removeObject(forKey: key)
        }
        Self.postChange()
    }

    /// Bridges extension/App Intent completion back into a running app process.
    /// Foreground refresh remains the fallback when iOS suspended the process.
    public static func startObservingCrossProcessChanges() {
        guard !isObservingCrossProcessChanges else { return }
        isObservingCrossProcessChanges = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: LunaSetupStatusStore.didChange, object: nil)
                }
            },
            darwinNotificationName as CFString,
            nil,
            .deliverImmediately)
    }

    /// The in-process post hops to the main thread because its ONLY observer is UI
    /// (the left setup tray, which animates completed cards away) while its only
    /// posters are `recordShortcutRun` callers — the three App Intents, whose
    /// `perform()` runs on the Swift-concurrency cooperative pool. Posting inline
    /// drove `UIView.animate` off the main thread and aborted in Auto Layout's
    /// thread assertion. Same hop `ReadingListStore.postChanged` and the Darwin
    /// observer below already make. The Darwin post needs no hop: it is
    /// thread-safe, and the receiving side hops before it republishes.
    private static func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotificationName as CFString),
            nil, nil, true)
    }
}
