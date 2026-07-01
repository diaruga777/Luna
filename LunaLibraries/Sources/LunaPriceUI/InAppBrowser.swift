//
//  InAppBrowser.swift
//  Luna
//

import SafariServices
import LunaTransitions
import UIKit

/// Ultimate fallback for opening a platform item: an in-app `SFSafariViewController`
/// on the original URL (used when no native app and no usable embed exist).
public enum InAppBrowser {
    /// Presents the URL in an in-app Safari view, if it's a web URL.
    public static func present(urlString: String, from presenter: UIViewController) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        let safari = SFSafariViewController(url: url)
        DotMatrixModal.present(safari, from: presenter)
    }
}
