//
//  LunaSetupStatusStore.swift
//  LunaStorage
//

import LunaAppConfig
import LunaModels
import Foundation

/// Shared "has ever worked" markers for the left setup tray.
///
/// Shortcut import presses and App Intent runs are attributed to their exact
/// containing app. Safari retains its original central/faceted keys because
/// the three faceted Safari extensions have always shared completion evidence.
public final class LunaSetupStatusStore {
    public static let shared = LunaSetupStatusStore()
    public static let didChange = Notification.Name("LunaSetupStatusStore.didChange")

    public static let sharedSafariKey = "setup.safari.hasRun.shared"
    public static let centralSafariKey = "setup.safari.hasRun.luna"
    /// Builds predating per-app intent evidence wrote every faceted run here.
    /// Keep reading it as aggregate completion so existing users do not regain
    /// setup UI, but never use it to identify a specific configured sibling.
    public static let sharedShortcutKey = "setup.shortcut.hasRun.shared"
    public static let centralShortcutKey = "setup.shortcut.hasRun.luna"
    public static let sharedShareActionKey = "setup.shareAction.hasRun.shared"
    public static let centralShareActionKey = "setup.shareAction.hasRun.luna"

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

    /// Whether this app's Safari completion applies on its own first screen.
    /// Central Luna can handle every link, so its extension evidence also
    /// completes Safari setup for every subsequently installed faceted app.
    public func safariRunApplies(to app: LunaApp) -> Bool {
        safariHasRun(isCentral: app == .luna)
            || (app != .luna && safariHasRun(isCentral: true))
    }

    public static func shortcutInstallPressedKey(for app: LunaApp) -> String {
        "setup.shortcut.installPressed.\(app.storageIdentifier)"
    }

    public static func shortcutIntentRunKey(for app: LunaApp) -> String {
        "setup.shortcut.hasRun.\(app.storageIdentifier)"
    }

    public func shortcutInstallWasPressed(for app: LunaApp) -> Bool {
        defaults.bool(forKey: Self.shortcutInstallPressedKey(for: app))
    }

    public func recordShortcutInstallPressed(for app: LunaApp) {
        defaults.set(true, forKey: Self.shortcutInstallPressedKey(for: app))
        Self.postChange()
    }

    /// Exact per-app intent evidence. The old faceted aggregate remains a
    /// compatibility fallback for UI completion, but cannot prove WHICH old
    /// app ran and therefore cannot select the returning-user conversation.
    public func shortcutHasRun(for app: LunaApp) -> Bool {
        hasPerAppShortcutRun(for: app)
            || (app != .luna && defaults.bool(forKey: Self.sharedShortcutKey))
    }

    /// Central Luna's intents cover every link kind, so their evidence also
    /// completes the initial shortcut button for future faceted installs.
    public func shortcutRunApplies(to app: LunaApp) -> Bool {
        shortcutHasRun(for: app)
            || (app != .luna && shortcutHasRun(for: .luna))
    }

    public var anyShortcutHasRun: Bool {
        defaults.bool(forKey: Self.sharedShortcutKey)
            || LunaApp.allCases.contains { hasPerAppShortcutRun(for: $0) }
    }

    /// A sibling qualifies for the shortened Messages setup only when both
    /// facts can be attributed to that same app: its installer was pressed and
    /// one of its App Intents subsequently ran.
    public func previouslyConfiguredShortcutApp(excluding current: LunaApp) -> LunaApp? {
        LunaApp.allCases.first {
            $0 != current
                && shortcutInstallWasPressed(for: $0)
                && hasPerAppShortcutRun(for: $0)
        }
    }

    /// A new faceted app needs no onboarding when central Luna has already
    /// proven both system integrations work.
    public func centralAppCoversAllOnboarding(for app: LunaApp) -> Bool {
        app != .luna
            && shortcutHasRun(for: .luna)
            && safariHasRun(isCentral: true)
    }

    public func shareActionHasRun(isCentral: Bool) -> Bool {
        defaults.bool(forKey: isCentral ? Self.centralShareActionKey : Self.sharedShareActionKey)
    }

    public func recordShortcutRun(for app: LunaApp) {
        defaults.set(true, forKey: Self.shortcutIntentRunKey(for: app))
        Self.postChange()
    }

    public func recordShareActionRun(isCentral: Bool) {
        defaults.set(true, forKey: isCentral ? Self.centralShareActionKey : Self.sharedShareActionKey)
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
            Self.sharedShareActionKey,
            Self.centralShareActionKey,
        ] + LunaApp.allCases.flatMap({ app in
            [
                Self.shortcutInstallPressedKey(for: app),
                Self.shortcutIntentRunKey(for: app),
            ]
        }) {
            defaults.removeObject(forKey: key)
        }
        Self.postChange()
    }

    private func hasPerAppShortcutRun(for app: LunaApp) -> Bool {
        defaults.bool(forKey: Self.shortcutIntentRunKey(for: app))
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
