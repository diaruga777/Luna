//
//  ExtensionReaderShareProvider.swift
//  LunaReaderUI
//

import LunaDesignSystem
import LunaStorage
import LunaURLClassification
import UIKit

/// The action extension's reader sharing: save the article to Luna or share the
/// link via the system sheet. Sending to a Luna friend happens in the main app
/// (it needs the email account), so the extension doesn't offer it.
public final class ExtensionReaderShareProvider: ReaderShareProviding {

    public func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) {
        // Plain URL only — no Luna deep link, no accessory text.
        let shared: Any = URL(string: urlString) ?? urlString
        LunaShareSheet.present(items: [shared], from: presenter, anchor: .view(sourceView))
    }

    public func saveLink(urlString: String) {
        // No ingestor in the extension — queue the URL; the main app ingests it.
        // The link comes from a tapped page link, so it is unwrapped here (the
        // app's own path unwraps inside the ingestor).
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return }
        SavesStore.shared.addIfAbsent(urlString: url.absoluteString, source: .shareSheet)
    }
}
