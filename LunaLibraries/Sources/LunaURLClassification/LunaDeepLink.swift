//
//  LunaDeepLink.swift
//  Luna
//

import LunaModels
import Foundation

/// The per-app `luna*://` link schemes for opening a shared link straight into
/// one specific Luna app. Shape: `<scheme>://read?url=<percent-encoded URL>`.
///
/// Each app registers ONLY its own scheme (`$(LUNA_URL_SCHEME)` in the shared
/// Info.plist, set per app target), so a link targets exactly one app:
/// - `luna://` — the central Luna app
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
    /// The central Luna app's scheme.
    public static let lunaScheme = "luna"
    /// Luna Reader's scheme — also the historical scheme every app registered
    /// before the split, so older links keep opening Reader.
    public static let readerScheme = "lunareader"
    public static let downloaderScheme = "lunadownloader"
    public static let priceTrackerScheme = "lunapricetracker"
    public static let allSchemes = [lunaScheme, readerScheme, downloaderScheme, priceTrackerScheme]

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
    /// the broad check is correct here.
    public static func isRescueLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme, allSchemes.contains(scheme) else { return false }
        return url.host == "rescue"
    }

    /// True for a `<scheme>://read?url=…&ret=safari` link — a media or product
    /// pill tap (never the article pill's `readTarget`, which never carries the
    /// flag), asking the app to reopen the original page in Safari once the
    /// save is handled. Reading a bare `ret` query item rather than a fixed
    /// position means extra/reordered query params still parse harmlessly, the
    /// same guarantee `articleURL(from:)` already gives the `url` item.
    public static func requestsReturnToSource(_ url: URL) -> Bool {
        guard let scheme = url.scheme, allSchemes.contains(scheme), url.host == "read" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ret" })?.value == "safari"
    }

    /// `<scheme>://media?url=…` — the download Live Activity's tap-to-view
    /// link (finished, running, suspended, or failed): opens the app on the
    /// item downloading/downloaded from `sourceURLString`, without going
    /// through a save. See `SceneDelegate.route`'s `media` host branch.
    public static func mediaViewLink(scheme: String = ownScheme, sourceURLString: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "media"
        components.queryItems = [URLQueryItem(name: "url", value: sourceURLString)]
        return components.url
    }

    /// The wrapped source URL string from a `<any Luna scheme>://media?url=…`
    /// link, or nil if `url` isn't one.
    public static func mediaViewURLString(from url: URL) -> String? {
        guard let scheme = url.scheme, allSchemes.contains(scheme), url.host == "media" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
    }
}

public extension LunaApp {
    /// This app's `luna*://` deep-link scheme (`LunaDeepLink`).
    var deepLinkScheme: String {
        switch self {
        case .luna: return LunaDeepLink.lunaScheme
        case .reader: return LunaDeepLink.readerScheme
        case .downloader: return LunaDeepLink.downloaderScheme
        case .priceTracker: return LunaDeepLink.priceTrackerScheme
        }
    }
}
