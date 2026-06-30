//
//  SafariWebExtensionHandler.swift
//  ClipSafari
//

import SafariServices

/// Receives native messages from the extension's JavaScript: persists the active
/// Safari URL (for the SaveLink intent) and answers the "Read in Queue" button
/// visibility setting the content script asks for.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let appGroupID = SafariAppGroup.id
    private static let suggestionModeKey = "safariSuggestionMode"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var payload: [String: Any] = ["ok": true]

        if (message?["type"] as? String) == "buttonMode" {
            // The app stores SafariSuggestionMode's rawValue here (default "all").
            payload["mode"] = UserDefaults(suiteName: Self.appGroupID)?
                .string(forKey: Self.suggestionModeKey) ?? "all"
        } else if let urlString = message?["url"] as? String, urlString.hasPrefix("http") {
            SharedSafariURL.record(urlString)
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
