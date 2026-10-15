import CoreGraphics
import Foundation
import ImageIO
import LunaModels
import LunaStorage

/// A view-only projection. The canonical article retains all images for export,
/// indexing, and Original mode. Only the exact image used in the masthead moves.
public enum ArticleBanner {
    public static func prepare(content: ArticleContent, item: SavedItem, store: SavesStore)
        -> (content: ArticleContent, imageURL: URL?) {
        let resolved = ArticleImageDownloader.resolveLocalImages(content, store: store)
        let directory = store.articlesDirectory
        let lead = resolved.blocks.firstIndex { $0.kind == .image && $0.imageFileName != nil }
        let leadURL = lead.flatMap { resolved.blocks[$0].imageFileName }.map { directory.appendingPathComponent($0) }
        let coverURL = item.thumbnailFileName.map { directory.appendingPathComponent($0) }
        let imageURL = [coverURL, leadURL].compactMap { $0 }.first {
            CGImageSourceCreateWithURL($0 as CFURL, nil) != nil
        }
        guard let imageURL else { return (resolved, nil) }
        var displayed = resolved
        let bannerSample = sample(imageURL)
        if let bannerBytes = try? Data(contentsOf: imageURL),
           let match = displayed.blocks.firstIndex(where: { block in
               guard block.kind == .image, let name = block.imageFileName else { return false }
               let url = directory.appendingPathComponent(name)
               if url == imageURL || (try? Data(contentsOf: url)) == bannerBytes { return true }
               // Inline images are resized/re-encoded at ingest. Compare the
               // lead's small pixel sample so a JPEG copy of the same cover
               // does not remain duplicated in the body.
               guard let lead, block == resolved.blocks[lead],
                     let bannerSample, let inlineSample = sample(url)
               else { return false }
               return sameImage(bannerSample, inlineSample)
           }) {
            // Captions follow their picture. Their text remains in the saved
            // content and search index, but must not float over the first prose.
            if displayed.blocks.indices.contains(match + 1), displayed.blocks[match + 1].kind == .caption {
                displayed.blocks.remove(at: match + 1)
            }
            displayed.blocks.remove(at: match)
        }
        return (displayed, imageURL)
    }

    private struct Sample {
        let aspect: Double
        let pixels: [UInt8]
    }

    private static func sample(_ url: URL) -> Sample? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16,
                bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        return drawn ? Sample(aspect: Double(image.width) / Double(image.height), pixels: pixels) : nil
    }

    private static func sameImage(_ left: Sample, _ right: Sample) -> Bool {
        guard abs(left.aspect - right.aspect) < 0.03 else { return false }
        var error = 0
        for index in left.pixels.indices where index % 4 != 3 {
            error += abs(Int(left.pixels[index]) - Int(right.pixels[index]))
        }
        return Double(error) / Double(16 * 16 * 3 * 255) < 0.015
    }
}
