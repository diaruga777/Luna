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
    private static let bypassEnabledKey = "nonArchiveBypassEnabled"
    private static let appClipURLKey = "LunaDownloaderAppClipURL"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var payload: [String: Any] = ["ok": true]

        switch message?["type"] as? String {
        case "buttonMode", "buttonContext":
            // The app stores SafariSuggestionMode's rawValue here (default "all").
            payload["mode"] = UserDefaults(suiteName: Self.appGroupID)?
                .string(forKey: Self.suggestionModeKey) ?? "all"
            payload["isDownloaderHost"] = Self.isDownloaderHost
            payload["downloaderAppClipURL"] = Self.downloaderAppClipURL
        case "bypassEnabled":
            // The "Unlock Paywalls On-Device" toggle — gates the Safari auto-bypass.
            payload["enabled"] = UserDefaults(suiteName: Self.appGroupID)?
                .bool(forKey: Self.bypassEnabledKey) ?? false
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

    private static var isDownloaderHost: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".downloader.safari")
    }

    private static var downloaderAppClipURL: String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: Self.appClipURLKey) as? String else {
            return ""
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
