//
//  ClickDeepLink.swift
//  Clip
//

import Foundation

/// The `clickreader://` app-link scheme for opening a shared article straight
/// into the reader. Shape: `clickreader://read?url=<percent-encoded article URL>`.
///
/// NOTE: a custom scheme opens the app when it's installed, but cannot itself
/// fall back to the App Store when it isn't (only a Universal Link can). See
/// the share flow + docs for that limitation.
public enum ClickDeepLink {
    public static let scheme = "clickreader"

    /// A `clickreader://read?url=…` link wrapping an article URL.
    public static func readLink(forArticleURL articleURL: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "read"
        components.queryItems = [URLQueryItem(name: "url", value: articleURL)]
        return components.url
    }

    /// Extracts the wrapped article URL from a `clickreader://read?url=…` link,
    /// or nil if `url` isn't one.
    public static func articleURL(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "read" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
    }
}
