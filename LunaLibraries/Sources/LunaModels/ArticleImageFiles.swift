//
//  ArticleImageFiles.swift
//  LunaModels
//

import Foundation

/// Where a downloaded article image lives on disk.
///
/// Image file names are generated independently of their source URL. The storage
/// layer maps a URL to its current live copy when it can safely share one; a path
/// queued for deletion is never mapped or reused.
///
/// This lives in LunaModels — the bottom layer, beside `ArticleContent` whose
/// `imageFileName` it resolves — because the two ends are in different link
/// groups: `ArticleImageDownloader` (LunaReaderUI) writes the files, while the
/// exporters in `LunaSend`/`LunaEpub` read them, and neither module can see the
/// other. Both must agree on the naming exactly — when they don't, an export
/// silently ships without pictures, which is precisely the bug this fixes.
public enum ArticleImageFiles {

    /// A fresh filename for a newly fetched image. The UUID is deliberately
    /// unrelated to the source URL, so a retired path can never be recreated by
    /// fetching that URL again.
    public static func newFileName(fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        let safeExtension = ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && !ext.isEmpty ? ext : "img"
        return "img-\(UUID().uuidString.lowercased()).\(safeExtension)"
    }

    /// The downloaded files a piece of content points at — the images it owns
    /// while it exists. A block with no downloaded file yet contributes nothing.
    public static func referencedNames(in content: ArticleContent) -> [String] {
        content.blocks.compactMap { $0.imageFileName }
    }

    /// The on-disk file backing an image block, when the content recorded one
    /// and its bytes still exist. A missing name means the downloader must claim
    /// a live copy transactionally or fetch a fresh, uniquely named one.
    public static func localFileName(
        for block: ArticleContent.Block, in directory: URL
    ) -> String? {
        if let recorded = block.imageFileName,
           FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(recorded).path) {
            return recorded
        }
        return nil
    }

    /// `localFileName` as a URL.
    public static func localFile(
        for block: ArticleContent.Block, in directory: URL
    ) -> URL? {
        localFileName(for: block, in: directory)
            .map { directory.appendingPathComponent($0) }
    }

    /// True when any image block still has no local file — i.e. an export from
    /// this content right now would be missing pictures.
    public static func hasUnresolvedImages(
        in content: ArticleContent, directory: URL
    ) -> Bool {
        content.blocks.contains { block in
            block.kind == .image
                && (block.imageURLString?.isEmpty == false)
                && localFileName(for: block, in: directory) == nil
        }
    }
}

/// Picks the `Referer` an article-image fetch should send.
///
/// Header-image CDNs are routinely stricter than the page host and refuse a
/// request that doesn't look like the page's own subresource, so the article's
/// URL is the right referer. An imported email or document has no web page
/// behind it (`lunamail://`, a file), so those fall back to the image's own
/// origin — a same-origin request, which is never worse than none.
public enum ArticleImageReferer {
    public static func url(for item: SavedItem, content: ArticleContent) -> URL? {
        if let itemURL = item.url, itemURL.scheme?.hasPrefix("http") == true {
            return itemURL
        }
        for block in content.blocks where block.kind == .image {
            guard let raw = block.imageURLString, let imageURL = URL(string: raw),
                  imageURL.scheme?.hasPrefix("http") == true,
                  var components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)
            else { continue }
            components.path = "/"
            components.query = nil
            components.fragment = nil
            if let origin = components.url { return origin }
        }
        return nil
    }
}
