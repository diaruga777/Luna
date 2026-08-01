//
//  ArticleImageDownloader.swift
//  Luna
//

import LunaStorage
import LunaFetch
import LunaModels
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches article images once at ingest time, leaving every reader surface with
/// durable local files. Header-image CDNs are often stricter than the HTML host,
/// so image requests deliberately look like the page's own browser subresources.
public enum ArticleImageDownloader {
    // Sized for a durable OFFLINE reader: store (nearly) all of a page's images so a
    // preloaded/saved article reads completely with no network. Per-page caps, not global.
    private static let maxImages = 30
    /// Per-image cap on the RAW download (before transcode), so one giant original can't
    /// blow up memory.
    private static let maxBytes = 12 * 1024 * 1024
    /// Per-article budget on STORED (transcoded) bytes — stop once the page's images add
    /// up to this, so an image-heavy page can't run away with disk.
    private static let maxStoredBytesPerArticle = 40 * 1024 * 1024
    /// Downloaded images are transcoded to a downsampled JPEG/PNG so the reader can
    /// decode them near-instantly (slow WebP/AVIF/HEIC decodes were the cause of the
    /// "images flash in late" delay). Sized generously for a 3x retina content column.
    private static let maxStoredPixelSize = 2048

    public static func download(
        _ content: ArticleContent, itemID: UUID, store: ReadingListStore, refererURL: URL
    ) async -> ArticleContent {
        await download(content, itemID: itemID, store: store, refererURL: refererURL) { _, _ in true }
    }

    /// Downloads only unknown-size images that appear near the top of the article.
    /// Images with declared dimensions already have stable placeholders, so they do
    /// not need to block the row becoming readable.
    public static func downloadInitialLayoutImages(
        _ content: ArticleContent, itemID: UUID, store: ReadingListStore, refererURL: URL
    ) async -> ArticleContent {
        let initialTextBudget = 3_200
        return await download(content, itemID: itemID, store: store, refererURL: refererURL) { block, textBeforeBlock in
            guard block.kind == .image else { return false }
            if block.imageWidth != nil, block.imageHeight != nil { return false }
            return textBeforeBlock <= initialTextBudget
        }
    }

    /// Downloads every image whose dimensions the page didn't declare, wherever it
    /// sits in the article. Those are exactly the images that have no placeholder
    /// to sit in, so they are the ones whose late arrival reflows the text under
    /// the reader's feet: a surface that must show FINAL layout on its first frame
    /// (the extension readers) awaits this before it displays anything. Images with
    /// declared dimensions are left alone — their placeholders already hold the
    /// right space, so they can load in behind them without moving a word.
    public static func downloadUnknownSizeImages(
        _ content: ArticleContent, itemID: UUID, store: ReadingListStore, refererURL: URL
    ) async -> ArticleContent {
        await download(content, itemID: itemID, store: store, refererURL: refererURL) { block, _ in
            block.kind == .image && (block.imageWidth == nil || block.imageHeight == nil)
        }
    }

    private static func download(
        _ content: ArticleContent,
        itemID: UUID,
        store: ReadingListStore,
        refererURL: URL,
        shouldDownload: (ArticleContent.Block, Int) -> Bool
    ) async -> ArticleContent {
        var downloaded = 0
        var storedBytes = 0
        var blocks: [ArticleContent.Block] = []
        var textBeforeBlock = 0

        for var block in content.blocks {
            guard block.kind == .image else {
                blocks.append(block)
                textBeforeBlock += block.text.count
                continue
            }
            // A main-app ingestion may already have cached this image before the
            // action/share reader opens; preserve it rather than re-fetching it.
            guard let rawURL = block.imageURLString, let imageURL = URL(string: rawURL) else {
                blocks.append(block)
                continue
            }
            // Older Luna builds accepted WebP from image CDNs even for a `.gif`
            // source URL, then transcoded only frame zero to JPEG. Treat that legacy
            // still as missing so reopening the article repairs it in place. A real
            // preserved/converted animation is always stored as `.gif`.
            if let fileName = block.imageFileName {
                if !expectsGIFAnimation(imageURL) || fileName.lowercased().hasSuffix(".gif") {
                    blocks.append(block)
                    continue
                }
                block.imageFileName = nil
            }
            guard shouldDownload(block, textBeforeBlock) else {
                blocks.append(block)
                continue
            }
            // Images are keyed by a stable hash of their URL, NOT the item id, so the
            // same image reuses one local file across every reader/open (the inline
            // viewer builds a fresh transient item each time — itemId naming meant it
            // re-fetched every open). If a local copy already exists, skip the network.
            let base = Self.stableBase(for: rawURL)
            if let existing = Self.existingFileName(
                base: base, in: store.articlesDirectory,
                animatedGIFOnly: expectsGIFAnimation(imageURL)
            ) {
                block.imageFileName = existing
                blocks.append(block)
                continue
            }
            guard downloaded < maxImages, storedBytes < maxStoredBytesPerArticle,
                  let image = await fetch(imageURL, refererURL: refererURL) else {
                if downloaded < maxImages, storedBytes < maxStoredBytesPerArticle {
                    SharedDiagnosticLog.record("image download failed: \(imageURL.absoluteString)", category: "images")
                }
                blocks.append(block)
                continue
            }

            let fileName = "\(base).\(image.fileExtension)"
            let destination = store.articlesDirectory.appendingPathComponent(fileName)
            do {
                try image.data.write(to: destination, options: .atomic)
                block.imageFileName = fileName
                blocks.append(block)
                downloaded += 1
                storedBytes += image.data.count
                SharedDiagnosticLog.record("image downloaded: \(imageURL.absoluteString)", category: "images")
            } catch {
                blocks.append(block)
                continue
            }
        }

        var updated = content
        updated.blocks = blocks
        return updated
    }

    /// Synchronously fill in `imageFileName` for every image block whose downloaded
    /// file already exists on disk (keyed by the image URL's stable hash). No network,
    /// no decoding — just a hash + file-existence check per image, cheap enough to run
    /// on the main thread right before the first render, so on-disk images bake into
    /// the article *with the text* instead of popping in later via the async `download`.
    /// Blocks whose file isn't cached yet are returned unchanged (the async `download`
    /// fetches those). Returns `content` untouched when no image needs resolving.
    public static func resolveLocalImages(
        _ content: ArticleContent, store: ReadingListStore
    ) -> ArticleContent {
        guard content.blocks.contains(where: { block in
            guard block.kind == .image else { return false }
            if block.imageFileName == nil { return true }
            guard let rawURL = block.imageURLString, let imageURL = URL(string: rawURL),
                  expectsGIFAnimation(imageURL) else { return false }
            return block.imageFileName?.lowercased().hasSuffix(".gif") != true
        })
        else { return content }
        let directory = store.articlesDirectory
        var blocks: [ArticleContent.Block] = []
        blocks.reserveCapacity(content.blocks.count)
        for var block in content.blocks {
            if block.kind == .image, let rawURL = block.imageURLString,
               let imageURL = URL(string: rawURL) {
                let expectsAnimation = expectsGIFAnimation(imageURL)
                if let current = block.imageFileName,
                   expectsAnimation, !current.lowercased().hasSuffix(".gif") {
                    // Unlink a legacy frame-zero JPEG so the reader's missing-image
                    // pass can fetch the animation again.
                    block.imageFileName = nil
                }
                if block.imageFileName == nil,
                   let existing = existingFileName(
                       base: stableBase(for: rawURL), in: directory,
                       animatedGIFOnly: expectsAnimation) {
                    block.imageFileName = existing
                }
            }
            blocks.append(block)
        }
        var updated = content
        updated.blocks = blocks
        return updated
    }

    /// Stable, filesystem-safe filename stem for an image URL (so the same image maps
    /// to one local file regardless of which item/open requested it).
    private static func stableBase(for rawURL: String) -> String {
        let digest = SHA256.hash(data: Data(rawURL.utf8))
        return "img-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// An already-downloaded file for `base` (any image extension), or nil.
    private static func existingFileName(
        base: String, in directory: URL, animatedGIFOnly: Bool = false
    ) -> String? {
        // Prefer GIF before legacy JPEG when both exist after an automatic repair.
        let candidates = animatedGIFOnly
            ? ["gif"]
            : ["gif", "jpg", "png", "jpeg", "webp", "heic", "heif", "avif", "img"]
        for ext in candidates {
            let name = "\(base).\(ext)"
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                return name
            }
        }
        return nil
    }

    private static func fetch(_ url: URL, refererURL: URL) async -> (data: Data, fileExtension: String)? {
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            acceptHeader(for: url),
            forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 512, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let originalExtension = fileExtension(for: http.mimeType, url: url)
        if CGImageSourceGetCount(source) > 1 {
            // GIF and APNG are directly animated by ImageIO. A CDN may still ignore
            // our GIF-specific Accept header and serve animated WebP; convert that
            // sequence to GIF rather than feeding it through the single-frame raster
            // transcode below.
            if originalExtension == "gif" { return (data, "gif") }
            if originalExtension == "png" { return (data, "png") }
            if let gif = transcodeAnimationToGIF(source) { return (gif, "gif") }
            return nil
        }
        // Transcode to a downsampled, fast-decoding format up front. Keep animated
        // GIFs as-is (transcoding would freeze the animation); everything else (incl.
        // slow-to-decode webp/avif/heic) becomes jpg, or png when it has transparency.
        if originalExtension != "gif", let transcoded = transcode(data) {
            return transcoded
        }
        return (data, originalExtension)
    }

    /// Requests the original GIF representation from content-negotiating CDNs.
    /// WordPress's i0.wp.com otherwise sees WebP support and returns animated WebP;
    /// older Luna builds then flattened it during the normal raster transcode.
    static func acceptHeader(for url: URL) -> String {
        if expectsGIFAnimation(url) {
            return "image/gif,image/apng,image/*,*/*;q=0.8"
        }
        return "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
    }

    private static func expectsGIFAnimation(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gif"
    }

    /// Converts an animated format that ImageIO can decode (notably WebP) into a
    /// GIF sequence that `CGAnimateImageAtURLWithBlock` can play efficiently.
    private static func transcodeAnimationToGIF(_ source: CGImageSource) -> Data? {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, count, nil)
        else { return nil }

        let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loopCount = animationLoopCount(in: sourceProperties) ?? 0
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]
        ] as CFDictionary)

        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
            let delay = max(0.02, animationDelay(in: properties) ?? 0.1)
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func animationDelay(in properties: [CFString: Any]?) -> Double? {
        for dictionaryKey in [
            kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary,
            kCGImagePropertyWebPDictionary,
        ] {
            guard let dictionary = properties?[dictionaryKey] as? [CFString: Any] else { continue }
            for delayKey in [
                kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime,
                kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime,
            ] {
                if let number = dictionary[delayKey] as? NSNumber { return number.doubleValue }
            }
        }
        return nil
    }

    private static func animationLoopCount(in properties: [CFString: Any]?) -> Int? {
        for (dictionaryKey, loopKey) in [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
        ] {
            if let dictionary = properties?[dictionaryKey] as? [CFString: Any],
               let number = dictionary[loopKey] as? NSNumber {
                return number.intValue
            }
        }
        return nil
    }

    /// Downsamples to `maxStoredPixelSize` and re-encodes as JPEG (or PNG when the
    /// source has an alpha channel). Returns nil if the source can't be decoded.
    private static func transcode(_ data: Data) -> (data: Data, fileExtension: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxStoredPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let hasAlpha: Bool
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let ext = hasAlpha ? "png" : "jpg"
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil) else { return nil }
        let destOptions: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, ext)
    }

    private static func fileExtension(for mimeType: String?, url: URL) -> String {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "image/avif": return "avif"
        case "image/gif": return "gif"
        default:
            let ext = url.pathExtension.lowercased()
            return ext.allSatisfy({ $0.isLetter || $0.isNumber }) && !ext.isEmpty ? ext : "img"
        }
    }
}
