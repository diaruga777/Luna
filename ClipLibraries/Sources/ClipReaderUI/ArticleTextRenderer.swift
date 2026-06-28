//
//  ArticleTextRenderer.swift
//  Clip
//

import ClipDesignSystem
import ClipStorage
import ClipModels
import ImageIO
import UIKit

/// The rendered article plus a map from each block's text to its range in the
/// attributed string (nil for image/skipped blocks) — used by read-aloud
/// highlighting and eye tracking to translate between text spaces.
public struct RenderedArticle {
    public let text: NSAttributedString
    public let blockTextRanges: [NSRange?]
    /// Attachment ranges and their local source files, for inline-image gestures.
    public let imageRanges: [(range: NSRange, fileURL: URL)]

    public init(
        text: NSAttributedString,
        blockTextRanges: [NSRange?],
        imageRanges: [(range: NSRange, fileURL: URL)] = []
    ) {
        self.text = text
        self.blockTextRanges = blockTextRanges
        self.imageRanges = imageRanges
    }
}

/// Builds the attributed string for the scrolling reader from extracted blocks,
/// styling headings/quotes/lists, attaching tappable link attributes, and
/// inlining downloaded article images as text attachments.
public enum ArticleTextRenderer {

    public static func render(_ content: ArticleContent) -> RenderedArticle {
        let result = NSMutableAttributedString()
        var blockTextRanges: [NSRange?] = []
        var imageRanges: [(NSRange, URL)] = []
        let imagesDirectory = ReadingListStore.shared.articlesDirectory
        // Cap to the readable text column so images don't overflow on iPad.
        let maxImageWidth = min(UIScreen.main.bounds.width - 40, 660)

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.paragraphSpacing = content.author == nil ? 24 : 8
        result.append(NSAttributedString(
            string: content.title + "\n",
            attributes: [
                .font: serifFont(size: 30, weight: .bold),
                .foregroundColor: UIColor.label,
                .paragraphStyle: titleParagraph,
            ]))

        if let author = content.author {
            let authorParagraph = NSMutableParagraphStyle()
            authorParagraph.paragraphSpacing = 24
            result.append(NSAttributedString(
                string: author + "\n",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: authorParagraph,
                ]))
        }

        for block in content.blocks {
            if block.kind == .image {
                if let fileName = block.imageFileName,
                   let imageString = attributedImage(
                       at: imagesDirectory.appendingPathComponent(fileName),
                       maxWidth: maxImageWidth) {
                    let attachmentRange = NSRange(location: result.length, length: 1)
                    result.append(imageString)
                    imageRanges.append((attachmentRange, imagesDirectory.appendingPathComponent(fileName)))
                }
                blockTextRanges.append(nil)
                continue
            }
            let (blockString, textOffsetInBlock) = attributedString(for: block)
            blockTextRanges.append(NSRange(
                location: result.length + textOffsetInBlock,
                length: (block.text as NSString).length))
            result.append(blockString)
        }
        return RenderedArticle(text: result, blockTextRanges: blockTextRanges, imageRanges: imageRanges)
    }

    // MARK: - Images

    private static func attributedImage(at fileURL: URL, maxWidth: CGFloat) -> NSAttributedString? {
        guard let image = downsampledImage(at: fileURL, maxWidth: maxWidth) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        let displayWidth = min(maxWidth, image.size.width)
        let displayHeight = displayWidth / image.size.width * image.size.height
        attachment.bounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 14
        paragraph.paragraphSpacingBefore = 6
        paragraph.alignment = .center

        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: result.length))
        return result
    }

    /// In-memory cache of already-decoded, downsampled images. The bytes are on
    /// disk (downloaded once at ingest), but decoding them is a synchronous, costly
    /// main-thread operation — re-decoding on every reader open is the visible pause.
    /// Keyed by file path + target width so a re-open is instant.
    nonisolated(unsafe) private static let decodedCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Bound the cache so a long reading session can't accumulate decoded bitmaps
        // unboundedly (NSCache also evicts under memory pressure).
        cache.countLimit = 24
        return cache
    }()

    /// Decodes the image already scaled down — never holds the full-size bitmap.
    /// Cached so navigating back into an article (or reopening it) is instant.
    private static func downsampledImage(at fileURL: URL, maxWidth: CGFloat) -> UIImage? {
        let key = "\(fileURL.path)|\(Int(maxWidth.rounded()))" as NSString
        if let cached = decodedCache.object(forKey: key) { return cached }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            return nil
        }
        let scale = UIScreen.main.scale
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth * scale,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        decodedCache.setObject(image, forKey: key)
        return image
    }

    /// Returns the styled block string plus the offset of the block's text
    /// within it (after any bullet prefix).
    private static func attributedString(for block: ArticleContent.Block) -> (NSAttributedString, Int) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 14
        paragraph.lineSpacing = 5

        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
        var prefix = ""
        switch block.kind {
        case .paragraph, .image:
            // .image is handled by the caller; treat as paragraph defensively.
            attributes[.font] = serifFont(size: 19, weight: .regular)
        case .heading:
            attributes[.font] = serifFont(size: 24, weight: .semibold)
            paragraph.paragraphSpacingBefore = 12
        case .quote:
            attributes[.font] = italicSerifFont(size: 19)
            attributes[.foregroundColor] = UIColor.secondaryLabel
            paragraph.firstLineHeadIndent = 16
            paragraph.headIndent = 16
        case .listItem:
            attributes[.font] = serifFont(size: 19, weight: .regular)
            paragraph.headIndent = 18
            prefix = "•  "
        }

        let text = NSMutableAttributedString(string: prefix + block.text + "\n", attributes: attributes)
        let prefixLength = (prefix as NSString).length
        for link in block.links {
            guard let url = URL(string: link.urlString) else { continue }
            let range = NSRange(location: link.start + prefixLength, length: link.length)
            guard range.location + range.length <= text.length else { continue }
            text.addAttribute(.link, value: url, range: range)
        }
        return (text, prefixLength)
    }

    /// Reader type respects the user's font (serif/sans) and size settings.
    private static func serifFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let scaled = size * ReaderSettings.fontScale
        let base = UIFont.systemFont(ofSize: scaled, weight: weight)
        guard ReaderSettings.useSerifFont,
              let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: scaled)
    }

    private static func italicSerifFont(size: CGFloat) -> UIFont {
        let scaled = size * ReaderSettings.fontScale
        let base = UIFont.italicSystemFont(ofSize: scaled)
        guard ReaderSettings.useSerifFont,
              let descriptor = UIFont.systemFont(ofSize: scaled).fontDescriptor
                  .withDesign(.serif)?.withSymbolicTraits(.traitItalic) else { return base }
        return UIFont(descriptor: descriptor, size: scaled)
    }
}
