//
//  ArticleCoverThumbnail.swift
//  LuneReaderUI
//

import LuneStorage
import LuneFetch
import LuneHTMLClassification
import LuneModels
import Foundation

/// The ONE place reading-list cover thumbnails are produced, so every save entry
/// point (in-app, App Intent, action/share extension) ends up with an identical
/// row thumbnail for the same article.
///
/// A cover is the page's `og:image` / `twitter:image` (NOT an inline body image) —
/// the same lead art the reader header shows. Two ways to get it:
///
/// 1. From the page HTML at save time (the in-app / App Intent path already has the
///    fetched HTML): `coverImageData(html:baseURL:)`.
/// 2. As an idempotent backfill for any already-saved article that has no thumbnail
///    yet — used by the app on launch/foreground to repair extension saves (the
///    extension is short-lived and sandbox-limited, so it can't reliably fetch the
///    cover itself) and any historical rows: `backfillThumbnail(for:store:)`.
public enum ArticleCoverThumbnail {
    /// A cover candidate must be a real image, not a tracking pixel or a multi-MB
    /// original — same bounds the in-app path always used.
    private static let minBytes = 512
    private static let maxBytes = 5 * 1024 * 1024
    private static let timeout: TimeInterval = 8

    /// Downloads an article's cover image (`og:image` / `twitter:image`) from the
    /// page HTML, with a short timeout. Returns nil on any failure — the row then
    /// shows no thumbnail.
    public static func coverImageData(html: String, baseURL: URL) async -> Data? {
        guard let imageURL = LeadImageExtractor.imageURL(in: html, baseURL: baseURL) else { return nil }
        return await fetchImage(imageURL, refererURL: baseURL)
    }

    /// Idempotently gives `item` a cover thumbnail if it is a `.ready` web article
    /// that is missing one. No-op for anything that already has a thumbnail, isn't a
    /// plain web article (videos/platforms/docs/trackers fill their own thumbnail at
    /// ingest), or has no resolvable cover. Writes via `store.setThumbnail`, so it is
    /// app-group-coordinated and safe to call repeatedly.
    ///
    /// Cover source, cheapest first:
    /// 1. The article's lead inline image, if it was already downloaded to disk
    ///    (no network — reuse the bytes the reader already cached).
    /// 2. The live page's `og:image` (one short fetch), for items whose images
    ///    were never downloaded (the extension persists content without downloading).
    public static func backfillThumbnail(for item: ReadingListItem, store: ReadingListStore) async {
        // Already has a thumbnail, or isn't a plain web article — nothing to do.
        guard item.thumbnailFileName == nil,
              item.state == .ready,
              item.platform == nil,
              item.priceTracker == nil,
              item.sanitizedDocumentType == nil,
              let urlString = item.url?.absoluteString,
              let url = item.url, url.scheme?.hasPrefix("http") == true
        else { return }

        // 1. Reuse an already-downloaded lead image file (no network).
        if let content = store.content(for: item),
           let data = leadImageData(from: content, store: store) {
            store.setThumbnail(data, for: item.id)
            SharedDiagnosticLog.record(
                "thumbnail backfill (lead image) \(urlString)", category: "images")
            return
        }

        // 2. Fetch the page and pull its og:image.
        guard let html = try? await ArticleFetcher().fetchHTML(from: url),
              let data = await coverImageData(html: html, baseURL: url)
        else { return }
        store.setThumbnail(data, for: item.id)
        SharedDiagnosticLog.record("thumbnail backfill (og:image) \(urlString)", category: "images")
    }

    /// The bytes of the article's FIRST already-downloaded `.image` block, or nil if
    /// no image block has been downloaded yet. Read straight from the Articles dir.
    private static func leadImageData(
        from content: ArticleContent, store: ReadingListStore
    ) -> Data? {
        // Resolve any on-disk-but-unlinked images first (extension saves persist
        // image blocks with only a URL), so a freshly cached file is found.
        let resolved = ArticleImageDownloader.resolveLocalImages(content, store: store)
        guard let fileName = resolved.blocks.first(where: {
            $0.kind == ArticleContent.Block.Kind.image && $0.imageFileName != nil
        })?.imageFileName else { return nil }
        let fileURL = store.articlesDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL), data.count > minBytes else { return nil }
        return data
    }

    /// Downloads an image with a Safari user-agent + referer (header-image CDNs are
    /// often referer-gated). Returns nil unless it's a valid, sanely sized image.
    private static func fetchImage(_ imageURL: URL, refererURL: URL) async -> Data? {
        var request = URLRequest(url: imageURL, timeoutInterval: timeout)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > minBytes, data.count <= maxBytes
        else { return nil }
        return data
    }
}
