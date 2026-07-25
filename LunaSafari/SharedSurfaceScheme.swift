//
//  SharedSurfaceScheme.swift
//  LunaSafari
//

import Foundation

/// Which Luna surface this extension belongs to, and the URL scheme its page
/// buttons deep-link into. Derived from the extension's OWN bundle id suffix
/// (`<hostAppBundleId>.safari` — see `SafariWebExtensionHandler`'s
/// `isHost(appSuffix:)` helper, which this mirrors), because an extension may
/// only ever hand content to its own containing app.
///
/// The scheme literals mirror `LunaURLClassification.LunaDeepLink`'s; this
/// target links no package (see `SharedSafariURL.swift` for the established
/// pattern), so they're duplicated here.
enum SharedSurfaceScheme {
    private static let lunaScheme = "luna"
    private static let readerScheme = "lunareader"
    private static let downloaderScheme = "lunadownloader"
    private static let priceTrackerScheme = "lunapricetracker"

    /// This extension's own surface + URL scheme. The central Luna app's
    /// extension has the bare `<prefix>.safari` bundle id (no content suffix)
    /// and maps to the "luna" surface.
    static var currentSurfaceAndScheme: (surface: String, scheme: String) {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        if identifier.hasSuffix(".downloader.safari") { return ("downloader", downloaderScheme) }
        if identifier.hasSuffix(".pricetracker.safari") { return ("pricetracker", priceTrackerScheme) }
        if identifier.hasSuffix(".reader.safari") { return ("reader", readerScheme) }
        return ("luna", lunaScheme)
    }
}
