//
//  ShareViewController.swift
//  ClipShare
//

import Intents
import UIKit
import UniformTypeIdentifiers

/// Zero-UI share extension: receives a web URL or a document (PDF/text/
/// Markdown/RTF) from the share sheet, appends it to the shared reading list,
/// and completes immediately. The main app downloads/parses on next launch.
///
/// When launched by tapping a Click friend in the share sheet's people row, the
/// shared URL is queued as an outgoing friend-share for the main app to send
/// (the extension has no crypto/CloudKit access).
final class ShareViewController: UIViewController {

    /// Document file types accepted from the share sheet. `.text` (public.text)
    /// covers .txt, .md/.markdown, and most source/plain formats.
    private static let documentTypes: [UTType] = [.pdf, .rtf, .plainText, .text]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        guard let providers = (extensionContext?.inputItems.first as? NSExtensionItem)?.attachments,
              !providers.isEmpty
        else {
            complete()
            return
        }

        // Tapped a Click friend suggestion: the conversation identifier is the
        // friend's UUID. Queue the URL for the main app to send.
        if let intent = extensionContext?.intent as? INSendMessageIntent,
           let conversationID = intent.conversationIdentifier,
           let friendUUID = UUID(uuidString: conversationID),
           let urlProvider = providers.first(where: {
               $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
           }) {
            handleFriendShare(urlProvider, friendUUID: friendUUID)
            return
        }

        // A genuine web link conforms to public.url but NOT to a document type.
        // A shared file (e.g. a PDF) ALSO conforms to public.url (as a file-url),
        // so it must be matched as a document first — otherwise the URL branch
        // grabs it, sees a non-http file:// URL, and silently drops it.
        func isDocument(_ provider: NSItemProvider) -> Bool {
            Self.documentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }

        if let webProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) && !isDocument($0)
        }) {
            handleURL(webProvider)
            return
        }
        for provider in providers {
            if let type = Self.documentTypes.first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) {
                handleDocument(provider, type: type)
                return
            }
        }
        // Fallback: a plain URL we didn't classify as a web link above.
        if let urlProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            handleURL(urlProvider)
            return
        }
        complete()
    }

    private func handleURL(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            if let url = value as? URL {
                if url.absoluteString.hasPrefix("http") {
                    SharedReadingListAppender.append(urlString: url.absoluteString)
                } else if url.isFileURL {
                    // A file delivered only as a URL — import it as a document.
                    SharedReadingListAppender.appendDocument(sourceURL: url)
                }
            }
            self?.complete()
        }
    }

    private func handleDocument(_ provider: NSItemProvider, type: UTType) {
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
            // The system deletes `url` when this callback returns, so the
            // appender copies it synchronously here.
            if let url {
                SharedReadingListAppender.appendDocument(sourceURL: url)
            }
            self?.complete()
        }
    }

    private func handleFriendShare(_ provider: NSItemProvider, friendUUID: UUID) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            if let url = value as? URL, url.absoluteString.hasPrefix("http") {
                PendingFriendShareWriter.enqueue(
                    friendUUID: friendUUID, urlString: url.absoluteString)
            }
            self?.complete()
        }
    }

    private func complete() {
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

/// Writes outgoing friend-shares to the App Group queue the main app drains.
/// (The JSON shape must match the app's `PendingFriendShare`.)
private enum PendingFriendShareWriter {
    private struct Share: Codable {
        let friendUUID: UUID
        let urlString: String
    }

    static func enqueue(friendUUID: UUID, urlString: String) {
        guard let fileURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedReadingListAppender.appGroupID)?
            .appendingPathComponent("pendingFriendShares.json")
        else { return }
        var queue: [Share] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Share].self, from: data) {
            queue = decoded
        }
        queue.append(Share(friendUUID: friendUUID, urlString: urlString))
        if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
