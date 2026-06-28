//
//  RabbitHolePreloader.swift
//  ClipReaderUI
//
//  On-demand, reader-side preloading for the experimental RabbitHole reader. Fully
//  materializes a linked page to disk — article JSON + ALL its images downloaded to the
//  shared Articles cache — exactly the way a root save does, so a preloaded link opens
//  identical to the root (text and images already local, zero fetch on load).
//
//  The save-time PreloadCoordinator only crawls depth-1 from the root; this fills the
//  gap by materializing whatever the user can actually reach from the page they're on.
//

import ClipFetch
import ClipHTMLClassification
import ClipModels
import ClipStorage
import Foundation

enum RabbitHolePreloader {

    /// Fully materialize `url`'s page on disk (article JSON + every image), owned by
    /// `rootID`, and return its content when it's article-like. A no-op fetch when the
    /// page is already cached and loaded in `PreloadStore`. Returns nil for non-article
    /// pages (those fall back to a live load on tap). Runs entirely off the main thread.
    static func materialize(url: URL, rootID: UUID) async -> ArticleContent? {
        // Already fully cached (e.g. PreloadCoordinator did it at save time)? Reuse it.
        if let cached = PreloadStore.shared.articleContent(for: url) { return cached }

        guard let html = try? await ArticleFetcher().fetchHTML(from: url),
              let content = try? ArticleExtractor().extract(html: html, baseURL: url),
              isArticleLike(content)
        else { return nil }

        // Download every image to the shared, URL-hash-keyed Articles cache — the SAME
        // step the root save and PreloadCoordinator run — then persist the enriched
        // content so the reader finds it (with imageFileName set) on tap.
        let enriched = await ArticleImageDownloader.download(
            content, itemID: rootID, store: .shared, refererURL: url)
        PreloadStore.shared.record(
            url: url, rootID: rootID, kind: .article, depthRemaining: 0,
            content: enriched, children: outboundURLs(from: enriched))
        return enriched
    }

    /// Same heuristic the layer's probe uses to decide a page is worth the reader.
    static func isArticleLike(_ content: ArticleContent) -> Bool {
        let blocks = content.blocks.filter { !$0.text.isEmpty }
        let totalText = blocks.reduce(0) { $0 + $1.text.count }
        return totalText >= 600 && blocks.count >= 3
    }

    /// De-duplicated absolute http(s) links on a page, in document order.
    static func outboundURLs(from content: ArticleContent) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for block in content.blocks {
            for link in block.links {
                guard seen.insert(link.urlString).inserted,
                      let url = URL(string: link.urlString),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
                else { continue }
                result.append(url)
            }
        }
        return result
    }
}
