//
//  ShareViewController.swift
//  ClipShare
//

import UIKit
import UniformTypeIdentifiers

/// Zero-UI share extension: receives a web URL or a document (PDF/text/
/// Markdown/RTF) from the share sheet, appends it to the shared reading list,
/// and completes immediately. The main app downloads/parses on next launch.
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

    private func complete() {
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
