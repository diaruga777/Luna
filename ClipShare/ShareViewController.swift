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

        // Prefer a web URL; otherwise take the first recognized document.
        if let urlProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            handleURL(urlProvider)
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
        complete()
    }

    private func handleURL(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            if let url = value as? URL, url.absoluteString.hasPrefix("http") {
                SharedReadingListAppender.append(urlString: url.absoluteString)
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
