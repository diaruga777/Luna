//
//  ExtensionReaderShareProvider.swift
//  LunaReaderUI
//

import LunaStorage
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
        let activity = UIActivityViewController(
            activityItems: [shared], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView
        presenter.present(activity, animated: true)
    }

    public func saveLink(urlString: String) {
        // No ingestor in the extension — queue the URL; the main app ingests it.
        SharedReadingListAppender.append(urlString: urlString)
    }
}
