//
//  LunaDeepLink.swift
//  Luna
//

import Foundation

/// The per-app `luna*://` link schemes for opening a shared link straight into
/// one specific Luna app. Shape: `<scheme>://read?url=<percent-encoded URL>`.
///
/// Each app registers ONLY its own scheme (`$(LUNA_URL_SCHEME)` in the shared
/// Info.plist, set per app target), so a link targets exactly one app:
/// - `lunareader://` — Luna Reader
/// - `lunadownloader://` — Luna Downloader
/// - `lunapricetracker://` — Luna Price Tracker
///
/// Parsing accepts ANY of the three: the OS only delivers schemes the running
/// app registered, and a link saved through any app lands in the shared store
/// on its proper surface regardless.
///
/// NOTE: a custom scheme opens the app when it's installed, but cannot itself
/// fall back to the App Store when it isn't (only a Universal Link can). See
/// the share flow + docs for that limitation.
public enum LunaDeepLink {
    /// Luna Reader's scheme — also the historical scheme every app registered
    /// before the split, so older links keep opening Reader.
    public static let readerScheme = "lunareader"
    public static let downloaderScheme = "lunadownloader"
    public static let priceTrackerScheme = "lunapricetracker"
    public static let allSchemes = [readerScheme, downloaderScheme, priceTrackerScheme]

    /// The scheme THIS bundle registers (its Info.plist `CFBundleURLTypes`),
    /// falling back to Reader's. Lets shared library code build links that
    /// reopen the app it is running in (e.g. a Live Activity action URL).
    public static var ownScheme: String {
        let urlTypes = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        for urlType in urlTypes {
            if let scheme = (urlType["CFBundleURLSchemes"] as? [String])?.first,
               !scheme.isEmpty {
                return scheme
            }
        }
        return readerScheme
    }

    /// A `<scheme>://read?url=…` link wrapping a source URL. Defaults to the
    /// Reader app; pass another app's scheme to target it instead.
    public static func readLink(
        forArticleURL articleURL: String, scheme: String = readerScheme
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "read"
        components.queryItems = [URLQueryItem(name: "url", value: articleURL)]
        return components.url
    }

    /// Extracts the wrapped source URL from a `<any Luna scheme>://read?url=…`
    /// link, or nil if `url` isn't one.
    public static func articleURL(from url: URL) -> String? {
        guard let scheme = url.scheme, allSchemes.contains(scheme),
              url.host == "read" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
    }

    /// `<scheme>://interop` — opens straight to the cross-app-interop paywall
    /// (`claudedocs/interop-purchase.md`). Used by the interop prompt's
    /// extension-surface "Open Luna" step (`extensionContext.open`, always this
    /// app's OWN scheme, since a purchase only ever unlocks/redirects within
    /// the app the prompt is running in) and by `SceneDelegate`'s routing.
    public static func interopLink(scheme: String = ownScheme) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "interop"
        return components.url
    }

    /// True for `<any Luna scheme>://interop`.
    public static func isInteropLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme, allSchemes.contains(scheme) else { return false }
        return url.host == "interop"
    }

    /// True only for THIS containing app's `<own scheme>://interop` link.
    /// Scene routing uses the narrower check: although the parser understands
    /// every Luna scheme, a sibling app must never handle another app's purchase
    /// hand-off (each app sells and restores its own StoreKit product).
    public static func isOwnInteropLink(_ url: URL) -> Bool {
        url.scheme == ownScheme && isInteropLink(url)
    }

    /// `<scheme>://rescue` — the extension→app URL-rescue hand-off. No query
    /// payload: the URL + hint + one-shot consent travel in
    /// `PendingRescueRequestStore` (App Group), and a bare route works even when
    /// the responder-chain open silently fails (the foreground drain still finds
    /// the record). The extension targets its CONTAINING app's scheme.
    public static func rescueLink(scheme: String = ownScheme) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "rescue"
        return components.url
    }

    /// True for `<any Luna scheme>://rescue` — any app drains its own queue, so
    /// (unlike interop) the broad check is correct here.
    public static func isRescueLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme, allSchemes.contains(scheme) else { return false }
        return url.host == "rescue"
    }
}
