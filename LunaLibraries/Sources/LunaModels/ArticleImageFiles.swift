//
//  ArticleImageFiles.swift
//  LunaModels
//

import CryptoKit
import Foundation

/// Where a downloaded article image lives on disk, and how to find it again.
///
/// Images are keyed by a stable hash of their SOURCE URL, not by the item id, so
/// one image is one file no matter how many saves, preloads or readers reference
/// it (the saves database counts the ownership; see `SavedFileOwnership`).
///
/// This lives in LunaModels — the bottom layer, beside `ArticleContent` whose
/// `imageFileName` it resolves — because the two ends are in different link
/// groups: `ArticleImageDownloader` (LunaReaderUI) writes the files, while the
/// exporters in `LunaSend`/`LunaEpub` read them, and neither module can see the
/// other. Both must agree on the naming exactly — when they don't, an export
/// silently ships without pictures, which is precisely the bug this fixes.
public enum ArticleImageFiles {

    /// Every extension the downloader can store, in the order to probe them.
    /// GIF first so an automatic repair's animation wins over the legacy
    /// frame-zero JPEG left beside it.
    public static let storedExtensions = [
        "gif", "jpg", "png", "jpeg", "webp", "heic", "heif", "avif", "img",
    ]

    /// The downloaded files a piece of content points at — the images it owns
    /// while it exists. A block with no downloaded file yet contributes nothing.
    public static func referencedNames(in content: ArticleContent) -> [String] {
        content.blocks.compactMap { $0.imageFileName }
    }

    /// Stable, filesystem-safe filename stem for an image URL.
    public static func stableBase(forImageURL rawURL: String) -> String {
        let digest = SHA256.hash(data: Data(rawURL.utf8))
        return "img-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// An already-downloaded file for `base` (any stored extension), or nil.
    public static func existingFileName(
        base: String, in directory: URL, animatedGIFOnly: Bool = false
    ) -> String? {
        let candidates = animatedGIFOnly ? ["gif"] : storedExtensions
        for ext in candidates {
            let name = "\(base).\(ext)"
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path) {
                return name
            }
        }
        return nil
    }

    /// The on-disk file backing an image block: the name the content recorded
    /// when that file is really there, else the URL-hash-keyed file some other
    /// save/preload already downloaded. Nil when nothing is local yet.
    ///
    /// The fallback keeps an export honest. Content is persisted the moment an
    /// article becomes readable, but its images finish downloading after that.
    /// A stored `imageFileName` of nil means "not yet," not "never" — trusting
    /// it alone would ship an export with no pictures.
    public static func localFileName(
        for block: ArticleContent.Block, in directory: URL
    ) -> String? {
        if let recorded = block.imageFileName,
           FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(recorded).path) {
            return recorded
        }
        guard let rawURL = block.imageURLString, !rawURL.isEmpty else { return nil }
        return existingFileName(base: stableBase(forImageURL: rawURL), in: directory)
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
