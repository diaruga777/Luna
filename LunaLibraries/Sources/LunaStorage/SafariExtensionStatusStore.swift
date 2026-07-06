//
//  SafariExtensionStatusStore.swift
//  Luna
//

import LunaAppConfig
import Foundation

/// App-Group-backed, per-surface record of whether THIS app's Safari web extension
/// is enabled, plus a one-shot "takeover pending" flag the app sets while its Safari
/// onboarding step is on screen.
///
/// The key literals here are duplicated as raw strings in `LunaSafari/` (that
/// target doesn't link the package — see `SafariAppGroup.swift` / the
/// `SharedSafariURL.swift` pattern this store's keys must stay in sync with):
/// - `safariExtensionEnabled.<surface>` — written by
///   `SafariWebExtensionHandler`'s `onboardingStatus` message handler the first
///   time the extension actually runs for that surface.
/// - `onboarding.safariTakeoverPending.<surface>` — written by the app (`true`)
///   while the "enable the Safari extension" onboarding step is visible; consumed
///   ONE-SHOT by the extension's native handler, which clears it and tells
///   `background.js` to show the "You're all set!" takeover overlay.
public final class SafariExtensionStatusStore {

    public static let shared = SafariExtensionStatusStore()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
    }

    private func enabledKey(forSurface surface: String) -> String {
        "safariExtensionEnabled.\(surface)"
    }

    private func takeoverKey(forSurface surface: String) -> String {
        "onboarding.safariTakeoverPending.\(surface)"
    }

    // MARK: - Enabled state

    /// Records that the Safari extension ran for `surface`, at `date` (defaults to
    /// now).
    public func recordEnabled(forSurface surface: String, date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: enabledKey(forSurface: surface))
    }

    public func enabledDate(forSurface surface: String) -> Date? {
        guard let interval = defaults.object(forKey: enabledKey(forSurface: surface)) as? Double
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    public func isEnabled(forSurface surface: String) -> Bool {
        enabledDate(forSurface: surface) != nil
    }

    // MARK: - Takeover hand-off

    /// Set by the app while its Safari onboarding step is visible; cleared
    /// one-shot by the extension's native handler once it hands the takeover back.
    public func setTakeoverPending(_ pending: Bool, forSurface surface: String) {
        defaults.set(pending, forKey: takeoverKey(forSurface: surface))
    }

    public func isTakeoverPending(forSurface surface: String) -> Bool {
        defaults.bool(forKey: takeoverKey(forSurface: surface))
    }
}
