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

    /// True when hosted by the "Read in Click" action extension
    /// (`com.apple.ui-services`) rather than the zero-UI share extension
    /// (`com.apple.share-services`). The action extension always opens the
    /// reader; the share extension only does when the user enabled it.
    private var isActionExtension: Bool {
        let nsExtension = Bundle.main.infoDictionary?["NSExtension"] as? [String: Any]
        return (nsExtension?["NSExtensionPointIdentifier"] as? String) == "com.apple.ui-services"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let host = isActionExtension ? "action" : "share"
        // Flatten attachments across ALL input items (action extensions may
        // split content across items differently than share extensions).
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            SharedDiagnosticLog.record(
                "\(host) extension: no attachments (\(items.count) item(s)), completing",
                category: "share")
            complete()
            return
        }
        let types = providers.map { $0.registeredTypeIdentifiers.joined(separator: "|") }
            .joined(separator: ", ")
        SharedDiagnosticLog.record(
            "\(host) extension: \(providers.count) attachment(s) types=[\(types)]", category: "share")

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

        // Safari (action extension) delivers the page URL via the JavaScript
        // preprocessing result — a property-list attachment — NOT a public.url.
        if let plistProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }) {
            handleJavaScriptResult(plistProvider)
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

    /// Handles the Safari JavaScript-preprocessing result: a property-list whose
    /// `NSExtensionJavaScriptPreprocessingResultsKey` holds `{URL, title}`.
    private func handleJavaScriptResult(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) { [weak self] item, _ in
            guard let self else { return }
            let results = (item as? [String: Any])?[
                NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
            if let urlString = results?["URL"] as? String, urlString.hasPrefix("http"),
               let url = URL(string: urlString) {
                SharedReadingListAppender.append(urlString: urlString)
                SharedDiagnosticLog.record("saved url (js) \(urlString)", category: "share")
                if let mode = self.readerMode() {
                    DispatchQueue.main.async { self.presentReader(url: url, mode: mode) }
                    return
                }
            } else {
                SharedDiagnosticLog.record("js result had no http URL", category: "share")
            }
            self.complete()
        }
    }

    private func handleURL(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            guard let self else { return }
            if let url = value as? URL {
                if url.absoluteString.hasPrefix("http") {
                    SharedReadingListAppender.append(urlString: url.absoluteString)
                    SharedDiagnosticLog.record("saved url \(url.absoluteString)", category: "share")
                    // Open the article in an in-sheet reader: always for the
                    // "Read in Click" action extension, and for the share
                    // extension only when the user picked a reader experience.
                    if let mode = self.readerMode() {
                        DispatchQueue.main.async { self.presentReader(url: url, mode: mode) }
                        return
                    }
                } else if url.isFileURL {
                    SharedReadingListAppender.appendDocument(sourceURL: url)
                    SharedDiagnosticLog.record("saved file \(url.lastPathComponent)", category: "share")
                }
            } else {
                SharedDiagnosticLog.record("url attachment had no URL value", category: "share")
            }
            self.complete()
        }
    }

    /// The reader mode to present, or nil to save silently. The action extension
    /// always reads (defaulting to the scroll reader); the share extension reads
    /// only when the user picked a non-"off" share-sheet experience.
    private func readerMode() -> ShareReaderViewController.Mode? {
        let configured = ShareReaderViewController.Mode(rawValue: shareExperience())
        return isActionExtension ? (configured ?? .reader) : configured
    }

    /// The configured share-sheet experience (read from the App Group, written
    /// by the main app's settings). "off" / unknown → save silently.
    private func shareExperience() -> String {
        UserDefaults(suiteName: SharedReadingListAppender.appGroupID)?
            .string(forKey: "shareSheetExperience") ?? "off"
    }

    private func presentReader(url: URL, mode: ShareReaderViewController.Mode) {
        let reader = ShareReaderViewController(url: url, mode: mode) { [weak self] in
            self?.complete()
        }
        let nav = UINavigationController(rootViewController: reader)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
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
