//
//  ArticleImageDownloader.swift
//  Clip
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches article images once at ingest time, leaving every reader surface with
/// durable local files. Header-image CDNs are often stricter than the HTML host,
/// so image requests deliberately look like the page's own browser subresources.
enum ArticleImageDownloader {
    private static let maxImages = 10
    private static let maxBytes = 12 * 1024 * 1024
    /// Downloaded images are transcoded to a downsampled JPEG/PNG so the reader can
    /// decode them near-instantly (slow WebP/AVIF/HEIC decodes were the cause of the
    /// "images flash in late" delay). Sized generously for a 3x retina content column.
    private static let maxStoredPixelSize = 2048

    static func download(
        _ content: ArticleContent, itemID: UUID, store: ReadingListStore, refererURL: URL
    ) async -> ArticleContent {
        var downloaded = 0
        var blocks: [ArticleContent.Block] = []

        for (index, var block) in content.blocks.enumerated() {
            guard block.kind == .image else {
                blocks.append(block)
                continue
            }
            // A main-app ingestion may already have cached this image before the
            // action/share reader opens; preserve it rather than re-fetching it.
            if block.imageFileName != nil {
                blocks.append(block)
                continue
            }
            guard downloaded < maxImages,
                  let rawURL = block.imageURLString,
                  let imageURL = URL(string: rawURL)
            else {
                blocks.append(block)
                continue
            }
            guard let image = await fetch(imageURL, refererURL: refererURL) else {
                SharedDiagnosticLog.record("image download failed: \(imageURL.absoluteString)", category: "images")
                blocks.append(block)
                continue
            }

            let fileName = "\(itemID.uuidString)-img\(index).\(image.fileExtension)"
            let destination = store.articlesDirectory.appendingPathComponent(fileName)
            do {
                try image.data.write(to: destination, options: .atomic)
                block.imageFileName = fileName
                blocks.append(block)
                downloaded += 1
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

    private static func fetch(_ url: URL, refererURL: URL) async -> (data: Data, fileExtension: String)? {
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(refererURL.absoluteString, forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 512, data.count <= maxBytes,
              CGImageSourceCreateWithData(data as CFData, nil) != nil
        else { return nil }

        let originalExtension = fileExtension(for: http.mimeType, url: url)
        // Transcode to a downsampled, fast-decoding format up front. Keep animated
        // GIFs as-is (transcoding would freeze the animation); everything else (incl.
        // slow-to-decode webp/avif/heic) becomes jpg, or png when it has transparency.
        if originalExtension != "gif", let transcoded = transcode(data) {
            return transcoded
        }
        return (data, originalExtension)
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
