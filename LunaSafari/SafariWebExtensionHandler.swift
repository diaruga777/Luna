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
    private static let readerAppClipURLKey = "LunaReaderAppClipURL"
    private static let downloaderAppClipURLKey = "LunaDownloaderAppClipURL"
    private static let priceTrackerAppStoreURLKey = "LunaPriceTrackerAppStoreURL"
    // Written by each app at launch (`InstalledAppMarkers` in the app shell) so any
    // host's extension knows which sibling Luna apps exist on this device.
    private static let readerInstalledKey = "lunaInstalled.reader"
    private static let downloaderInstalledKey = "lunaInstalled.downloader"
    private static let priceTrackerInstalledKey = "lunaInstalled.pricetracker"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var payload: [String: Any] = ["ok": true]
        SharedOnboardingStatus.recordEnabled()

        switch message?["type"] as? String {
        case "buttonMode", "buttonContext":
            // The app stores SafariSuggestionMode's rawValue here (default "all").
            payload["mode"] = UserDefaults(suiteName: Self.appGroupID)?
                .string(forKey: Self.suggestionModeKey) ?? "all"
            payload["isDownloaderHost"] = Self.isDownloaderHost
            payload["readerAppClipURL"] = Self.readerAppClipURL
            payload["downloaderAppClipURL"] = Self.downloaderAppClipURL
            payload["readerInstalled"] = Self.isReaderInstalled
            payload["downloaderInstalled"] = Self.isDownloaderInstalled
            payload["priceTrackerInstalled"] = Self.isPriceTrackerInstalled
            payload["priceTrackerAppStoreURL"] = Self.priceTrackerAppStoreURL
        case "bypassEnabled":
            // On-device unlocking is always enabled; the receiving Luna surface
            // decides how to present the captured article.
            payload["enabled"] = true
        case "saveContent":
            // The content script hands over the already-unlocked article HTML so the
            // app can render it as prefetched content (never re-fetching a page that
            // would re-lock outside Safari).
            if let urlString = message?["url"] as? String, urlString.hasPrefix("http"),
               let html = message?["html"] as? String {
                SharedSafariURL.recordUnlockedContent(urlString, html: html)
            }
        case "onboardingStatus":
            // background.js asks this once at script load. Records that this
            // extension is now enabled/running, and — if the app left a takeover
            // pending for this surface (its Safari onboarding step is on screen) —
            // consumes it one-shot and tells the page to show the takeover overlay.
            let (takeover, scheme) = SharedOnboardingStatus.recordEnabledAndConsumeTakeover()
            payload["takeover"] = takeover
            payload["scheme"] = scheme
        default:
            if let urlString = message?["url"] as? String, urlString.hasPrefix("http") {
                SharedSafariURL.record(urlString)
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private static var isDownloaderHost: Bool {
        isHost(appSuffix: ".downloader")
    }

    /// The extension's own host app is installed by definition; sibling apps are
    /// known from the launch markers each app writes into the App Group. A marker
    /// can go stale after an uninstall (App Group data outlives the app), in which
    /// case the deep link still lands in a remaining Luna app and the shared store
    /// surfaces the item on its proper surface.
    private static var isReaderInstalled: Bool {
        isHost(appSuffix: ".reader") || installedMarker(readerInstalledKey)
    }

    private static var isDownloaderInstalled: Bool {
        isHost(appSuffix: ".downloader") || installedMarker(downloaderInstalledKey)
    }

    private static var isPriceTrackerInstalled: Bool {
        isHost(appSuffix: ".pricetracker") || installedMarker(priceTrackerInstalledKey)
    }

    private static func isHost(appSuffix: String) -> Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(appSuffix + ".safari")
    }

    private static func installedMarker(_ key: String) -> Bool {
        UserDefaults(suiteName: appGroupID)?.bool(forKey: key) ?? false
    }

    private static var downloaderAppClipURL: String {
        infoPlistURL(forKey: downloaderAppClipURLKey)
    }

    private static var readerAppClipURL: String {
        infoPlistURL(forKey: readerAppClipURLKey)
    }

    private static var priceTrackerAppStoreURL: String {
        infoPlistURL(forKey: priceTrackerAppStoreURLKey)
    }

    private static func infoPlistURL(forKey key: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return ""
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
