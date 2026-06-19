//
//  SafariWebExtensionHandler.swift
//  ClipSafari
//

import SafariServices

/// Receives native messages from the extension's JavaScript (background.js) and
/// persists the currently open Safari URL to the shared App Group so the main app
/// and the SaveLink intent can read it.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        if (message?["type"] as? String) == "archiveContent" {
            // The "Read in Queue" archive harvest — stash it for the app to ingest.
            PendingSafariArchive.write(message: message ?? [:])
        } else if let urlString = message?["url"] as? String, urlString.hasPrefix("http") {
            SharedSafariURL.record(urlString)
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
