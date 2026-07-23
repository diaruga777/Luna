//
//  SharedOnboardingStatus.swift
//  LunaSafari
//

import Foundation

/// Backs the `"onboardingStatus"` native message: the app's Safari onboarding step
/// asks (via `background.js`, at script load) whether ITS extension is now enabled,
/// and — if the app left a takeover pending — gets told to show the "You're all
/// set!" overlay and hand the user back to Luna.
///
/// Key literals mirror `LunaStorage.SafariExtensionStatusStore` (the app-side
/// reader/writer); this target doesn't link the package (see `SharedSafariURL.swift`
/// for the established pattern), so they're duplicated here.
enum SharedOnboardingStatus {
    static let appGroupID = SafariAppGroup.id

    /// The four Luna URL schemes, matching `LunaDeepLink`'s literals (mirrored
    /// here for the same reason — this target has no shared framework).
    private static let lunaScheme = "luna"
    private static let readerScheme = "lunareader"
    private static let downloaderScheme = "lunadownloader"
    private static let priceTrackerScheme = "lunapricetracker"

    /// This extension's own surface + URL scheme, derived from its own bundle id
    /// suffix (`<hostAppBundleId>.safari` — see `SafariWebExtensionHandler`'s
    /// existing `isHost(appSuffix:)` helper, which this mirrors). The central
    /// Luna app's extension has the bare `<prefix>.safari` bundle id (no
    /// content suffix) and maps to the "luna" surface.
    static var currentSurfaceAndScheme: (surface: String, scheme: String) {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        if identifier.hasSuffix(".downloader.safari") { return ("downloader", downloaderScheme) }
        if identifier.hasSuffix(".pricetracker.safari") { return ("pricetracker", priceTrackerScheme) }
        if identifier.hasSuffix(".reader.safari") { return ("reader", readerScheme) }
        return ("luna", lunaScheme)
    }

    private static func enabledKey(forSurface surface: String) -> String {
        "safariExtensionEnabled.\(surface)"
    }

    private static func hasRunKey(forSurface surface: String) -> String {
        "safariExtensionHasRun.\(surface)"
    }

    private static func takeoverKey(forSurface surface: String) -> String {
        "onboarding.safariTakeoverPending.\(surface)"
    }

    /// Records that this extension just ran. Native messages only arrive once the
    /// extension is enabled and Safari has loaded it, so any message is enough to
    /// prove the extension has run at least once for this surface.
    static func recordEnabled() {
        let (surface, _) = currentSurfaceAndScheme
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(true, forKey: hasRunKey(forSurface: surface))
        defaults?.set(Date().timeIntervalSince1970, forKey: enabledKey(forSurface: surface))
        defaults?.synchronize()
    }

    /// Consumes the app's takeover-pending flag ONE-SHOT: `true` and cleared if
    /// the app was waiting on this hand-off, else `false` with nothing to clear.
    ///
    /// Returns the payload for the `"onboardingStatus"` response.
    static func recordEnabledAndConsumeTakeover() -> (takeover: Bool, scheme: String) {
        let (surface, scheme) = currentSurfaceAndScheme
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(true, forKey: hasRunKey(forSurface: surface))
        defaults?.set(Date().timeIntervalSince1970, forKey: enabledKey(forSurface: surface))

        let pendingKey = takeoverKey(forSurface: surface)
        guard defaults?.bool(forKey: pendingKey) == true else {
            defaults?.synchronize()
            return (false, scheme)
        }
        defaults?.removeObject(forKey: pendingKey)
        defaults?.synchronize()
        return (true, scheme)
    }
}
