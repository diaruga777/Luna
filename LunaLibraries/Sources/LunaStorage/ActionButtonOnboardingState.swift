//
//  ActionButtonOnboardingState.swift
//  Luna
//

import LunaAppConfig
import Foundation

/// Where a Luna app's user is in setting up the iOS 27+ Action Button shortcut for
/// one-tap saving. The flow round-trips the user between Luna, the Shortcuts app
/// (to import the bundled `Send To Luna.shortcut`), and Settings (to assign the
/// shortcut to the Action Button) — this state survives every backgrounding in
/// between, persisted per-surface (`"reader"`/`"downloader"`/`"pricetracker"`,
/// matching `InstalledAppMarkers`' key-suffix convention) in the shared App Group.
///
/// Raw values intentionally leave gaps (2→4, skipping 3; 5→7, skipping 6) as
/// headroom for inserting a state later without renumbering already-persisted
/// values on real devices.
public enum ActionButtonOnboardingState: Int, Sendable {
    /// Onboarding hasn't reached the action-button step yet, or it was reset
    /// (e.g. the user replayed onboarding).
    case notStarted = 0
    /// The user tapped "Install Shortcut" — the share sheet is presenting (or just
    /// presented) the bundled shortcut for import into the Shortcuts app.
    case installTapped = 1
    /// Luna was backgrounded while `installTapped` — the user is presumably in the
    /// Shortcuts app accepting the import.
    case awaitingShortcutRun = 2
    /// Back in Luna, on the action-button setup screen. Reached either by actually
    /// running the freshly-imported shortcut once (which invokes
    /// the Provide Context intent from the Shortcuts app), or by the one-shot foreground
    /// skip for a user who imported it but never ran it.
    case actionButtonSetup = 4
    /// The user tapped the deep link into Settings → Action Button.
    case awaitingActionButton = 5
    /// Action Button setup is complete.
    case done = 7
}

/// What `ActionButtonOnboardingStore.handleProvideContextInvoked` tells the
/// Provide Context intent to do instead of its normal decision-table behavior.
public enum ProvideContextInterception: Sendable, Equatable {
    /// No interception — proceed with the ordinary decision flow.
    case none
    /// Foreground Luna, then report unsupported (0). Used when the shortcut
    /// round-trip needs the user bounced back into Luna — e.g. the freshly
    /// imported shortcut's first run, or real Action Button setup completing
    /// while some other app was frontmost.
    case foregroundThenUnsupported
    /// Report unsupported (0) without foregrounding. Used when Luna itself is
    /// already frontmost — the in-app onboarding UI reacts to the state-change
    /// notification instead of needing the shortcut to bounce back.
    case unsupported
}

/// App-Group-backed, per-surface store for `ActionButtonOnboardingState`, plus
/// centralized transition helpers so the state machine's rules live in one
/// unit-testable place rather than scattered across scene-lifecycle code and the
/// intent. Injectable `UserDefaults` for tests; defaults to the shared App Group
/// suite in production.
public final class ActionButtonOnboardingStore {

    public static let shared = ActionButtonOnboardingStore()

    /// Posted on `NotificationCenter.default` (with `object` set to the surface
    /// string that changed) whenever `setState` actually changes a surface's
    /// stored value.
    public static let stateDidChangeNotification =
        Notification.Name("lunaActionButtonOnboardingStateDidChange")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
    }

    private func key(forSurface surface: String) -> String {
        "onboarding.actionButtonState.\(surface)"
    }

    // MARK: - Raw state

    public func state(forSurface surface: String) -> ActionButtonOnboardingState {
        guard let raw = defaults.object(forKey: key(forSurface: surface)) as? Int,
              let state = ActionButtonOnboardingState(rawValue: raw)
        else { return .notStarted }
        return state
    }

    /// Sets the surface's stored state, posting `stateDidChangeNotification` only
    /// when the value actually changes.
    public func setState(_ newState: ActionButtonOnboardingState, forSurface surface: String) {
        guard state(forSurface: surface) != newState else { return }
        defaults.set(newState.rawValue, forKey: key(forSurface: surface))
        NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: surface)
    }

    // MARK: - Transitions

    /// The user tapped "Install Shortcut" — callable from ANY state (re-arms the
    /// flow on an onboarding replay).
    public func beginInstallStep(forSurface surface: String) {
        setState(.installTapped, forSurface: surface)
    }

    /// Luna was backgrounded. Only advances from `installTapped`; every other
    /// state is left unchanged.
    public func handleAppBackgrounded(forSurface surface: String) {
        guard state(forSurface: surface) == .installTapped else { return }
        setState(.awaitingShortcutRun, forSurface: surface)
    }

    /// Luna came back to the foreground. The one-shot "user installed the shortcut
    /// but never ran it" skip: only advances from `awaitingShortcutRun`, and only
    /// once (the resulting `actionButtonSetup` state doesn't re-trigger it on a
    /// later foreground).
    public func handleAppForegrounded(forSurface surface: String) {
        guard state(forSurface: surface) == .awaitingShortcutRun else { return }
        setState(.actionButtonSetup, forSurface: surface)
    }

    /// The user tapped the deep link into Settings → Action Button.
    public func markSettingsDeeplinkTapped(forSurface surface: String) {
        guard state(forSurface: surface) == .actionButtonSetup else { return }
        setState(.awaitingActionButton, forSurface: surface)
    }

    /// Called at the very top of `ProvideContextIntent.perform()`, before
    /// any real decision work, so the shortcut round-trips can hijack the
    /// invocation instead of performing (or skipping) a real save.
    ///
    /// - In `awaitingShortcutRun`, invoked from the Shortcuts app (the freshly
    ///   imported shortcut's first run): advances to `actionButtonSetup` and asks
    ///   for Luna to be foregrounded.
    /// - In `actionButtonSetup` or `awaitingActionButton`, invoked from ANY app
    ///   (the user ran the shortcut for real, from wherever the Action Button was
    ///   pressed): advances to `done`. Returns `.unsupported` if Luna is already
    ///   the frontmost app (no need to bounce back), else `.foregroundThenUnsupported`.
    /// - Every other state: no transition, normal decision proceeds.
    public func handleProvideContextInvoked(
        appName: String, isCurrentAppLuna: Bool, forSurface surface: String
    ) -> ProvideContextInterception {
        switch state(forSurface: surface) {
        case .awaitingShortcutRun:
            guard appName.caseInsensitiveCompare("Shortcuts") == .orderedSame else { return .none }
            setState(.actionButtonSetup, forSurface: surface)
            return .foregroundThenUnsupported
        case .actionButtonSetup, .awaitingActionButton:
            setState(.done, forSurface: surface)
            return isCurrentAppLuna ? .unsupported : .foregroundThenUnsupported
        case .notStarted, .installTapped, .done:
            return .none
        }
    }
}
