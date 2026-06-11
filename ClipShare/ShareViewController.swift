//
//  ShareViewController.swift
//  ClipShare
//

import UIKit
import UniformTypeIdentifiers

/// Zero-UI share extension: receives a web URL from the share sheet, appends it
/// to the shared reading list, and completes immediately. The main app downloads
/// the content on next launch (or the SaveLink intent path covers Safari).
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let provider = item.attachments?.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            })
        else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] value, _ in
            if let url = value as? URL, url.absoluteString.hasPrefix("http") {
                SharedReadingListAppender.append(urlString: url.absoluteString)
            }
            DispatchQueue.main.async {
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }
}
