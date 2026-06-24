//
//  ArticleImageDownloader.swift
//  Clip
//

import Foundation
import ImageIO

/// Fetches article images once at ingest time, leaving every reader surface with
/// durable local files. Header-image CDNs are often stricter than the HTML host,
/// so image requests deliberately look like the page's own browser subresources.
enum ArticleImageDownloader {
    private static let maxImages = 10
    private static let maxBytes = 12 * 1024 * 1024

    static func download(
        _ content: ArticleContent, itemID: UUID, store: ReadingListStore, refererURL: URL
    ) async -> ArticleContent {
        var downloaded = 0
        var blocks: [ArticleContent.Block] = []

        for var block in content.blocks {
            guard block.kind == .image else {
                blocks.append(block)
                continue
            }
            guard downloaded < maxImages,
                  let rawURL = block.imageURLString,
                  let imageURL = URL(string: rawURL),
                  let image = await fetch(imageURL, refererURL: refererURL)
            else { continue }

            let fileName = "\(itemID.uuidString)-img\(downloaded).\(image.fileExtension)"
            let destination = store.articlesDirectory.appendingPathComponent(fileName)
            do {
                try image.data.write(to: destination, options: .atomic)
                block.imageFileName = fileName
                blocks.append(block)
                downloaded += 1
            } catch {
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

        return (data, fileExtension(for: http.mimeType, url: url))
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
