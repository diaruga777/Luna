//
//  InlineReaderContentLoader.swift
//  LunaReaderUI
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaStorage
import Foundation

enum InlineReaderContentLoader {

    /// Resolves an inline link as native article content and caches the result for
    /// later opens. Non-article pages return nil and fall back to the live web view.
    static func load(url: URL, owner: UUID) async -> ArticleContent? {
        if let cached = PreloadStore.shared.articleContent(for: url) {
            PreloadStore.shared.addOwner(owner, toKey: PreloadStore.key(for: url))
            return cached
        }

        guard let html = try? await ArticleFetcher().fetchHTML(from: url),
              let content = try? ArticleExtractor().extract(html: html, baseURL: url),
              content.isArticleLike
        else { return nil }

        let enriched = await ArticleImageDownloader.download(
            content, itemID: owner, store: .shared, refererURL: url)
        PreloadStore.shared.record(
            url: url, rootID: owner, kind: .article,
            content: enriched, children: enriched.outboundURLs)
        return enriched
    }
}
