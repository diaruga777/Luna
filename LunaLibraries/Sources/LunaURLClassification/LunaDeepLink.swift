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
/// - `lunavault://` — Luna Vault (file/library routes; not URL-kind ingest)
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
    /// Luna Reader's scheme. Every app registered this scheme before the
    /// per-app split, so a link written before then still opens Reader.
    public static let readerScheme = "lunareader"
    public static let downloaderScheme = "lunadownloader"
    public static let priceTrackerScheme = "lunapricetracker"
    public static let vaultScheme = "lunavault"
    public static let writerScheme = "lunawriter"
    public static let allSchemes = [lunaScheme, readerScheme, downloaderScheme, priceTrackerScheme, vaultScheme, writerScheme]

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
        return appScheme(forBundleIdentifier: Bundle.main.bundleIdentifier) ?? readerScheme
    }

    /// App extensions do not register URL schemes, but their bundle identifier
    /// is the containing app identifier plus `.share`, `.action2`, or `.safari`.
    /// Recovering the host facet here makes extension-to-app links target the
    /// app that owns the extension instead of falling back to Reader.
    public static func appScheme(forBundleIdentifier bundleIdentifier: String?) -> String? {
        guard var components = bundleIdentifier?.split(separator: ".").map(String.init),
              !components.isEmpty else { return nil }
        if let suffix = components.last,
           ["share", "action2", "safari"].contains(suffix) {
            components.removeLast()
        }
        switch components.last {
        case "luna": return lunaScheme
        case "reader": return readerScheme
        case "downloader": return downloaderScheme
        case "pricetracker": return priceTrackerScheme
        case "vault": return vaultScheme
        case "writer": return writerScheme
        default: return nil
        }
    }

    /// Extracts the wrapped source URL from a `<any Luna scheme>://read?url=…`
    /// link, or nil if `url` isn't one.
    public static func articleURL(from url: URL) -> String? {
        guard let scheme = url.scheme, allSchemes.contains(scheme),
              url.host == "read" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
    }

    /// `<scheme>://save?url=…` — Safari's "Finish in Luna"
    /// (`claudedocs/plans/plugin-platform.md` §8.2).
    ///
    /// Safari has no save row to lock: a plugin that asked for a browser there
    /// has nothing stored. So the app ingests the page from scratch, in the
    /// foreground, with the user present — which is exactly the state the
    /// browser step needs.
    public static func saveLink(scheme: String = ownScheme, urlString: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "save"
        components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        return components.url
    }

    /// The wrapped page from a `<any Luna scheme>://save?url=…` link, or nil
    /// when `url` is not one.
    public static func saveURL(from url: URL) -> String? {
        guard let scheme = url.scheme, allSchemes.contains(scheme), url.host == "save"
        else { return nil }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `<scheme>://llm?item=<uuid>` — the extension's LLM hand-off falling
    /// back to the app. An extension may only ask its host to open a URL, and
    /// the host may refuse; when it does, the extension opens this instead and
    /// the app opens the provider from a process that is always allowed to.
    /// The item id is all it carries — the prompt and the chosen provider are
    /// already in the shared hand-off record.
    public static let llmHandoffHost = "llm"

    public static func llmHandoffLink(scheme: String = ownScheme, itemID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = llmHandoffHost
        components.queryItems = [URLQueryItem(name: "item", value: itemID.uuidString)]
        return components.url
    }

    /// True for `<any Luna scheme>://llm?item=…`. Every app runs the recovery
    /// hand-off, so the broad scheme check is correct here.
    public static func isLLMHandoffLink(_ url: URL) -> Bool {
        llmHandoffItemID(from: url) != nil
    }

    public static func llmHandoffItemID(from url: URL) -> UUID? {
        guard let scheme = url.scheme, allSchemes.contains(scheme),
              url.host == llmHandoffHost,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "item" })?.value
        else { return nil }
        return UUID(uuidString: value)
    }

    /// `<scheme>://resolvedmedia` — the Safari in-page player's download
    /// hand-off. Payload-free on purpose: the resolved
    /// assets travel in `PendingResolvedMediaStore` (App Group), so a link this
    /// short can't truncate them and a foreground drain still finds them if the
    /// open silently fails. The `resolvedMediaHost` constant is mirrored in
    /// `content.js` — pinned by `SafariVideoOverlayTests`.
    public static let resolvedMediaHost = "resolvedmedia"

    /// True for `<any Luna scheme>://resolvedmedia` — an app with no media kind
    /// simply drains nothing, so the broad scheme check is correct here too.
    public static func isResolvedMediaLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme, allSchemes.contains(scheme) else { return false }
        return url.host == resolvedMediaHost
    }

    /// `<scheme>://pluginmodel` — the Safari plugin walk's save/download
    /// hand-off (`claudedocs/plans/plugin-platform.md` §13.1). Payload-free for
    /// the same reason `resolvedMediaHost` is: the Model travels in
    /// `PendingPluginModelStore` (App Group). Mirrored in `content.js`.
    public static let pluginModelHost = "pluginmodel"

    /// Safari's plugin-recovery hand-off to central Luna. The recovery case
    /// itself lives in the App Group; this route carries only its stable id.
    public static let pluginRecoveryHost = "pluginrecovery"

    public static func pluginRecoveryLink(
        scheme: String = lunaScheme, caseID: UUID? = nil
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = pluginRecoveryHost
        if let caseID {
            components.queryItems = [URLQueryItem(name: "case", value: caseID.uuidString)]
        }
        return components.url
    }

    /// True for a central-Luna plugin-recovery hand-off. Unlike model/save
    /// routes this must never target a facet app: only central Luna owns the
    /// plugin authoring UI.
    public static func isPluginRecoveryLink(_ url: URL) -> Bool {
        pluginRecoveryCaseID(from: url) != nil
    }

    public static func pluginRecoveryCaseID(from url: URL) -> UUID? {
        guard url.scheme == lunaScheme, url.host == pluginRecoveryHost,
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "case" })?.value
        else { return nil }
        return UUID(uuidString: raw)
    }

    /// True for `<any Luna scheme>://pluginmodel` — an app that runs no plugin
    /// platform simply drains nothing, so the broad scheme check is correct
    /// here too (only central Luna's queue is ever non-empty).
    public static func isPluginModelLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme, allSchemes.contains(scheme) else { return false }
        return url.host == pluginModelHost
    }

    /// The hosts whose links may ask to bounce back to Safari: a pill save
    /// (`read`), the in-page player's download (`resolvedmedia`), and the
    /// plugin walk's hand-off (`pluginmodel`). Every other host is refused
    /// even when it carries the flag.
    private static let returnToSourceHosts = ["read", resolvedMediaHost, pluginModelHost]

    /// True for a `<scheme>://read?url=…&ret=safari` link — a media or product
    /// pill tap (never the article pill's `readTarget`, which never carries the
    /// flag), asking the app to reopen the original page in Safari once the
    /// save is handled. Reading a bare `ret` query item rather than a fixed
    /// position means extra/reordered query params still parse harmlessly, the
    /// same guarantee `articleURL(from:)` already gives the `url` item.
    public static func requestsReturnToSource(_ url: URL) -> Bool {
        guard let scheme = url.scheme, allSchemes.contains(scheme),
              let host = url.host, returnToSourceHosts.contains(host) else { return false }
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

    /// `<scheme>://media?url=…&share=1` — the FINISHED download activity's
    /// Share button. Deliberately the same `media` route as `mediaViewLink`
    /// (so `mediaViewURLString(from:)` still recovers the source URL and the
    /// deck still centers on the item); the flag is the one extra thing it
    /// asks for — the system share sheet over the downloaded file.
    public static func mediaShareLink(scheme: String = ownScheme, sourceURLString: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "media"
        components.queryItems = [
            URLQueryItem(name: "url", value: sourceURLString),
            URLQueryItem(name: "share", value: "1"),
        ]
        return components.url
    }

    /// The wrapped source URL string from a `<any Luna scheme>://media?url=…`
    /// link, or nil if `url` isn't one. Also answers a `&share=1` link — the
    /// share route is the view route plus a flag.
    public static func mediaViewURLString(from url: URL) -> String? {
        guard let scheme = url.scheme, allSchemes.contains(scheme), url.host == "media" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
    }

    /// True for a `<any Luna scheme>://media?url=…&share=1` link — the finished
    /// activity's Share tap, as opposed to a plain tap-to-view. Reads a bare
    /// `share` query item rather than a fixed position, so extra or reordered
    /// params still parse, the same tolerance `mediaViewURLString(from:)` and
    /// `requestsReturnToSource(_:)` already give theirs.
    public static func mediaShareRequested(from url: URL) -> Bool {
        guard let scheme = url.scheme, allSchemes.contains(scheme), url.host == "media"
        else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "share" })?.value == "1"
    }

    /// Opens a tracked product's card and immediately starts its in-app seller
    /// browser. Share/action extensions use this route because a web search that
    /// outlives the extension belongs to the containing app process.
    public static func priceTrackerAddSellerLink(
        scheme: String = ownScheme, itemID: UUID
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "price-add-seller"
        components.queryItems = [URLQueryItem(name: "item", value: itemID.uuidString)]
        return components.url
    }

    /// The tracker identifier from a `<luna scheme>://price-add-seller?item=…`
    /// route, or nil for malformed and unrelated links.
    public static func priceTrackerAddSellerItemID(from url: URL) -> UUID? {
        guard let scheme = url.scheme, allSchemes.contains(scheme),
              url.host == "price-add-seller",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "item" })?.value
        else { return nil }
        return UUID(uuidString: value)
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
        case .vault: return LunaDeepLink.vaultScheme
        case .writer: return LunaDeepLink.writerScheme
        }
    }
}
