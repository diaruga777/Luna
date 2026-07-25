//
//  SafariWebExtensionHandler.swift
//  LunaSafari
//

import SafariServices

/// Receives native messages from the extension's JavaScript: persists the active
/// Safari URL (for the SaveLink intent), answers the "Read in Luna" button-visibility
/// and paywall-unlock settings the scripts ask for, and stashes the already-unlocked
/// article HTML so the app can render it without re-fetching.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let appGroupID = SafariAppGroup.id
    private static let suggestionModeKey = "safariSuggestionMode"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var payload: [String: Any] = ["ok": true]

        switch message?["type"] as? String {
        case "buttonMode", "buttonContext":
            // The app stores SafariSuggestionMode's rawValue here (default "all").
            payload["mode"] = UserDefaults(suiteName: Self.appGroupID)?
                .string(forKey: Self.suggestionModeKey) ?? "all"
            // The pill deep-links ONLY into this extension's own containing app,
            // and only for the content kinds that app handles: the central Luna
            // app handles everything; each single-content app handles one kind.
            let (_, scheme) = SharedSurfaceScheme.currentSurfaceAndScheme
            payload["scheme"] = scheme
            payload["supportsArticles"] = Self.hostHandlesArticles
            payload["supportsMedia"] = Self.hostHandlesMedia
            payload["supportsProducts"] = Self.hostHandlesProducts
        case "bypassEnabled":
            // On-device unlocking is article handling, so only article-capable
            // hosts (Reader and the central Luna app) enable the Referer
            // ruleset + in-page reveal; the receiving Luna surface decides how
            // to present the captured article.
            payload["enabled"] = Self.hostHandlesArticles
        case "saveContent":
            // The content script hands over the already-unlocked article HTML so the
            // app can render it as prefetched content (never re-fetching a page that
            // would re-lock outside Safari).
            if let urlString = message?["url"] as? String, urlString.hasPrefix("http"),
               let html = message?["html"] as? String {
                SharedSafariURL.recordUnlockedContent(urlString, html: html)
            }
        default:
            if let urlString = message?["url"] as? String, urlString.hasPrefix("http") {
                SharedSafariURL.record(urlString)
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Per-kind capability of this extension's containing app, from the bundle
    /// id suffix. The central Luna app's extension has the bare
    /// `<prefix>.safari` id (no content suffix) and handles every kind.
    private static var isCentralLunaHost: Bool {
        !isHost(appSuffix: ".reader") && !isHost(appSuffix: ".downloader")
            && !isHost(appSuffix: ".pricetracker")
    }

    private static var hostHandlesArticles: Bool {
        isCentralLunaHost || isHost(appSuffix: ".reader")
    }

    private static var hostHandlesMedia: Bool {
        isCentralLunaHost || isHost(appSuffix: ".downloader")
    }

    private static var hostHandlesProducts: Bool {
        isCentralLunaHost || isHost(appSuffix: ".pricetracker")
    }

    private static func isHost(appSuffix: String) -> Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(appSuffix + ".safari")
    }
}
