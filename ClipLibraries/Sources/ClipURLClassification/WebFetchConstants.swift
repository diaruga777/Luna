//
//  WebFetchConstants.swift
//  ClipURLClassification
//

import Foundation

/// Shared HTTP-fetch constants used by both URL-classification network helpers
/// (e.g. news-aggregator unwrapping) and the article fetcher. Defined at this
/// low tier so the URL layer can make requests without depending on the
/// fetch/HTML layers.
public enum WebFetchConstants {
    /// A current mobile-Safari User-Agent string — the bytes a normal reader's
    /// browser would receive, for reproducible fetches.
    public static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    /// Cap on the HTML held in memory. Real article pages are far smaller; this
    /// keeps a mis-served large file from pushing the memory-limited share/action
    /// extension into jetsam.
    public static let maxBytes = 8 * 1024 * 1024
}
