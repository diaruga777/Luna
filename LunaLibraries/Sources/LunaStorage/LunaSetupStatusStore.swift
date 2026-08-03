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

    /// How recent both halves of the Safari hand-off must be for the extension to
    /// congratulate the user in the page instead of offering its usual pill.
    public static let safariCelebrationWindow: TimeInterval = 24 * 60 * 60

    /// The four keys behind the in-page "You're all set up" confirmation. Two are
    /// written by the app (the setup tap), two by the extension's native handler
    /// (its own first run, and that it has shown the confirmation) — the extension
    /// links no framework, so `LunaSafari/SharedSafariURL.swift` carries a copy of
    /// every one of these formats and of the window above. They are an App-Group
    /// contract: `SafariSetupCelebrationTests` fails on drift between the two.
    ///
    /// All four are keyed per app rather than shared, unlike the completion
    /// markers above: an extension may only ever hand off to its OWN containing
    /// app, so central Luna's tap must not make the Reader's extension offer to
    /// return the user to an app they never left.
    public static func safariSetupTapKey(for app: LunaApp) -> String {
        "setup.safari.setupTapAt.\(app.storageIdentifier)"
    }

    /// The tapping app's own display name, stamped with the tap so the extension
    /// can name it ("Return to Luna Reader") without deriving it from a bundle id.
    public static func safariSetupTapAppNameKey(for app: LunaApp) -> String {
        "setup.safari.setupTapAppName.\(app.storageIdentifier)"
    }

    public static func safariFirstRunKey(for app: LunaApp) -> String {
        "setup.safari.firstRunAt.\(app.storageIdentifier)"
    }

    public static func safariCelebrationShownKey(for app: LunaApp) -> String {
        "setup.safari.celebrationShown.\(app.storageIdentifier)"
    }

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

    // MARK: - The in-page setup confirmation

    /// Records that the user just left for real Safari from this app's Safari
    /// lesson. Deliberately does NOT `postChange()`: nothing about completion has
    /// changed yet, and the observers are UI that is mid-transition to Safari.
    public func recordSafariSetupTap(for app: LunaApp, at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.safariSetupTapKey(for: app))
        defaults.set(app.displayName, forKey: Self.safariSetupTapAppNameKey(for: app))
    }

    public func safariSetupTapDate(for app: LunaApp) -> Date? {
        Self.date(defaults.object(forKey: Self.safariSetupTapKey(for: app)))
    }

    /// Stamped by the extension's native handler the first time it ever runs for
    /// this app. Read-only here: the app never writes it, so it can't manufacture
    /// evidence that the extension works.
    public func safariExtensionFirstRunDate(for app: LunaApp) -> Date? {
        Self.date(defaults.object(forKey: Self.safariFirstRunKey(for: app)))
    }

    public func safariCelebrationWasShown(for app: LunaApp) -> Bool {
        defaults.bool(forKey: Self.safariCelebrationShownKey(for: app))
    }

    /// Whether the extension should take the page over with the confirmation
    /// rather than offer its usual pill: the user tapped this app's setup button
    /// recently, this app's extension first ran recently, and the confirmation has
    /// not been shown before. A stamp in the future doesn't qualify — a backwards
    /// clock suppresses the confirmation rather than replaying it forever.
    ///
    /// `SharedSafariURL.shouldCelebrateSetup` is the extension's copy of this.
    public func shouldCelebrateSafariSetup(for app: LunaApp, now: Date = Date()) -> Bool {
        guard !safariCelebrationWasShown(for: app),
              let tap = safariSetupTapDate(for: app),
              let firstRun = safariExtensionFirstRunDate(for: app)
        else { return false }
        return Self.isWithinCelebrationWindow(tap, now: now)
            && Self.isWithinCelebrationWindow(firstRun, now: now)
    }

    private static func isWithinCelebrationWindow(_ date: Date, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed < safariCelebrationWindow
    }

    /// `UserDefaults` holds these as epoch seconds; absent reads as nil rather
    /// than 1970 so an unstamped key can't look like an ancient event.
    private static func date(_ stored: Any?) -> Date? {
        guard let seconds = stored as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
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
                // Including the extension's own two keys: a reset that left
                // `firstRunAt` stamped could never show the in-page confirmation
                // again, because an extension only ever first-runs once.
                Self.safariSetupTapKey(for: app),
                Self.safariSetupTapAppNameKey(for: app),
                Self.safariFirstRunKey(for: app),
                Self.safariCelebrationShownKey(for: app),
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
