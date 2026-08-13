//
//  NotificationAuthorizationState.swift
//  LunaStorage
//

import LunaAppConfig
import LunaModels
import Foundation

/// Whether the notification permission prompt has EVER been put in front of the
/// user — i.e. whether the system authorization status has left `.notDetermined`.
///
/// The system's own answer (`UNUserNotificationCenter.notificationSettings()`)
/// is asynchronous and lives in a higher tier (`LunaSocial.NotificationManager`,
/// which keeps this cache honest). This latch exists because several callers
/// must decide SYNCHRONOUSLY — a tracker being created inside a share/action
/// extension, a view configuring its first layout — and because an `.appex`
/// cannot ask for authorization at all; it can only read what the host app
/// already recorded. So this is one shared App-Group flag, written by
/// whoever asks and by the periodic refresh.
///
/// It only ever latches ON: once asked, always asked (a user revoking permission in
/// Settings has still answered the question). `reset()` exists for tests and for the
/// `-resetOnboarding` style flags.
public enum NotificationAuthorizationState {

    private static let key = "luna.notifications.everRequested"

    /// Test seam — the same pattern the other App-Group stores use, so a test can
    /// pin the flag without touching the real shared suite.
    public static var testDefaultsOverride: UserDefaults?

    private static var defaults: UserDefaults {
        resolvedAppGroupDefaults(
            appGroupID: AppConfig.appGroupID, testOverride: testDefaultsOverride) ?? .standard
    }

    /// True once the system prompt has been shown (granted OR denied).
    public static var hasEverBeenRequested: Bool {
        defaults.bool(forKey: key)
    }

    /// Records that the prompt has been shown. Idempotent.
    public static func markRequested() {
        defaults.set(true, forKey: key)
    }

    /// Latches the flag from an observed system status. `determined` false is NOT
    /// written back: the flag never un-latches.
    public static func recordSystemStatus(determined: Bool) {
        guard determined else { return }
        markRequested()
    }

    /// Clears the latch (tests, onboarding reset).
    public static func reset() {
        defaults.removeObject(forKey: key)
    }
}

/// The one place that decides what alert threshold a NEWLY tracked product starts
/// with. Until the user has been asked about notifications a new tracker starts
/// with NO threshold — Luna does not draw an alert line it cannot deliver on, and
/// setting one is what raises the permission prompt (see
/// `claudedocs/price-tracking.md`). Afterwards — granted or denied — new trackers
/// get the default 10% drop, exactly as they always did.
///
/// Lives in LunaStorage because every surface that can create a tracker (the
/// main-app ingestor, the extension product presenter, the extension reader's
/// silent product save) links this tier, while only some of them may link
/// LunaPriceUI.
public enum PriceAlertThresholdPolicy {

    /// The threshold a new tracker starts with, from the cached permission latch.
    public static var initialThresholdFraction: Double? {
        initialThresholdFraction(
            notificationsEverRequested: NotificationAuthorizationState.hasEverBeenRequested)
    }

    /// Pure form, for tests and for callers holding a freshly observed status.
    public static func initialThresholdFraction(
        notificationsEverRequested: Bool
    ) -> Double? {
        notificationsEverRequested ? PriceTracker.defaultAlertThresholdFraction : nil
    }
}
