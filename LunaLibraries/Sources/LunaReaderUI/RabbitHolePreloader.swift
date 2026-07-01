//
//  RabbitHolePreloader.swift
//  LunaReaderUI
//
//  On-demand, reader-side preloading for the experimental RabbitHole reader. Fully
//  materializes a linked page to disk — article JSON + ALL its images downloaded to the
//  shared Articles cache — exactly the way a root save does, so a preloaded link opens
//  identical to the root (text and images already local, zero fetch on load).
//
//  The save-time PreloadCoordinator only crawls depth-1 from the root; this fills the
//  gap by materializing whatever the user can actually reach from the page they're on.
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaStorage
import Foundation

enum RabbitHolePreloader {

    /// Fully materialize `url`'s page on disk (article JSON + every image), owned by
    /// `owner`, and return its content when it's article-like. A no-op fetch when the
    /// page is already cached and loaded in `PreloadStore` (the owner is still added, so
    /// a within-depth page warmed during reading also gains the durable owner). Returns
    /// nil for non-article pages (those fall back to a live load on tap). Runs entirely
    /// off the main thread.
    ///
    /// `owner` is the saved item id for pages within the durable depth (they persist) or
    /// a per-reader-session id for the speculative one-depth-beyond pages (released when
    /// the reader closes — see RabbitHoleReaderViewController).
    static func materialize(url: URL, owner: UUID) async -> ArticleContent? {
        // Already fully cached (e.g. PreloadCoordinator did it at save time)? Reuse it,
        // adding this owner so its refcount reflects everyone who reached the page.
        if let cached = PreloadStore.shared.articleContent(for: url) {
            PreloadStore.shared.addOwner(owner, toKey: PreloadStore.key(for: url))
            return cached
        }

        guard let html = try? await ArticleFetcher().fetchHTML(from: url),
              let content = try? ArticleExtractor().extract(html: html, baseURL: url),
              content.isArticleLike
        else { return nil }

        // Download every image to the shared, URL-hash-keyed Articles cache — the SAME
        // step the root save and PreloadCoordinator run — then persist the enriched
        // content so the reader finds it (with imageFileName set) on tap.
        let enriched = await ArticleImageDownloader.download(
            content, itemID: owner, store: .shared, refererURL: url)
        PreloadStore.shared.record(
            url: url, rootID: owner, kind: .article, depthRemaining: 0,
            content: enriched, children: enriched.outboundURLs)
        return enriched
    }
}
