//
//  ArticleTextRenderer.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import LunaModels
import ImageIO
import UIKit

/// The rendered article plus a map from each block's text to its range in the
/// attributed string (nil for image/skipped blocks) — used by read-aloud
/// highlighting to translate between text spaces.
public struct RenderedArticle {
    public let text: NSAttributedString
    public let blockTextRanges: [NSRange?]
    /// Attachment ranges and their local source files, for inline-image gestures.
    public let imageRanges: [(range: NSRange, fileURL: URL)]
    /// Whether this render covers the WHOLE article. `false` only for a
    /// `characterBudget`-truncated PREFIX render (the progressive-load Phase 1) —
    /// the scroll reader uses this to decide whether a full-content swap is still
    /// owed. A full render is always complete.
    public let isComplete: Bool

    public init(
        text: NSAttributedString,
        blockTextRanges: [NSRange?],
        imageRanges: [(range: NSRange, fileURL: URL)] = [],
        isComplete: Bool = true
    ) {
        self.text = text
        self.blockTextRanges = blockTextRanges
        self.imageRanges = imageRanges
        self.isComplete = isComplete
    }
}

/// Builds the attributed string for the scrolling reader from extracted blocks,
/// styling headings/quotes/lists, attaching tappable link attributes, and
/// inlining downloaded article images as text attachments.
public enum ArticleTextRenderer {

    /// Builds the full attributed string for the article.
    public static func render(
        _ content: ArticleContent, includesTitle: Bool = true
    ) -> RenderedArticle {
        render(content, characterBudget: nil, includesTitle: includesTitle)
    }

    /// Builds the attributed string for the article, optionally TRUNCATED to a
    /// leading prefix.
    ///
    /// With a `characterBudget`, blocks are appended until the cumulative count of
    /// included BODY text first exceeds the budget; the block that crosses it is
    /// included whole (so the prefix always reaches at least one full block past
    /// the threshold and fills the screen), then rendering stops. The title (and
    /// author) are always present. The returned `blockTextRanges` cover only the
    /// included blocks, and `imageRanges` only images whose block fell inside the
    /// prefix — so the prefix is a STRICT prefix of the full render (identical
    /// leading layout) and `WordMap`/image hit-testing stay consistent for it.
    /// `isComplete` is `false` only when the budget actually cut the article short.
    ///
    /// This is the scroll reader's Phase-1 fast path: laying out a few hundred
    /// characters is near-instant, so the reader paints immediately behind the
    /// entry animation; the full text is rendered and swapped in afterward.
    public static func render(
        _ content: ArticleContent,
        characterBudget: Int?,
        includesTitle: Bool = true
    ) -> RenderedArticle {
        let result = NSMutableAttributedString()
        var blockTextRanges: [NSRange?] = []
        var imageRanges: [(NSRange, URL)] = []
        let imagesDirectory = ReadingListStore.shared.articlesDirectory
        // Cap to the readable text column so images don't overflow on iPad.
        let maxImageWidth = min(UIScreen.main.bounds.width - 100, 660)

        if includesTitle {
            let titleParagraph = NSMutableParagraphStyle()
            titleParagraph.paragraphSpacing = content.author == nil ? 24 : 8
            result.append(NSAttributedString(
                string: content.title + "\n",
                attributes: [
                    .font: serifFont(size: 30, weight: .bold),
                    .foregroundColor: LunaColors.primaryText,
                    .paragraphStyle: titleParagraph,
                ]))
        }

        if let author = content.author {
            let authorParagraph = NSMutableParagraphStyle()
            authorParagraph.paragraphSpacing = 24
            result.append(NSAttributedString(
                string: author + "\n",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: LunaColors.secondaryText,
                    .paragraphStyle: authorParagraph,
                ]))
        }

        // Running count of BODY text characters included so far — drives the
        // prefix cutoff. Matches `ArticleContent.bodyTextLength` (sums block text),
        // so the budget is expressed in the same units the article reports.
        var includedTextCount = 0
        var truncated = false

        for block in content.blocks {
            // Stop once the budget is exceeded — but only AFTER at least one body
            // block is in (so the prefix is never empty / shorter than a screen).
            if let budget = characterBudget, includedTextCount > budget {
                truncated = true
                break
            }
            if block.kind == .image {
                if let fileName = block.imageFileName,
                   let imageString = attributedImage(
                       at: imagesDirectory.appendingPathComponent(fileName),
                       maxWidth: maxImageWidth) {
                    let attachmentRange = NSRange(location: result.length, length: 1)
                    result.append(imageString)
                    imageRanges.append((attachmentRange, imagesDirectory.appendingPathComponent(fileName)))
                } else if let placeholder = attributedImagePlaceholder(for: block, maxWidth: maxImageWidth) {
                    result.append(placeholder)
                }
                blockTextRanges.append(nil)
                continue
            }
            let (blockString, textOffsetInBlock) = attributedString(for: block)
            blockTextRanges.append(NSRange(
                location: result.length + textOffsetInBlock,
                length: (block.text as NSString).length))
            result.append(blockString)
            includedTextCount += block.text.count
        }
        return RenderedArticle(
            text: result, blockTextRanges: blockTextRanges, imageRanges: imageRanges,
            isComplete: !truncated)
    }

    // MARK: - Images

    /// A text attachment that scales its image to the ACTUAL available line width at
    /// layout time, never exceeding the image's natural (capped) width.
    ///
    /// The same article is rendered into text columns of different widths — the
    /// full screen, and a narrower inset reader card — but the attributed string is
    /// built once, before layout, when the final column width isn't known. A fixed
    /// attachment sized to the full screen overflows the narrower card column; being
    /// wider than the line, it can't be centered by the paragraph's `.center`
    /// alignment and instead hangs off the trailing edge (the image reads as
    /// right-shifted). Clamping to `proposedLineFragment.width` keeps every image
    /// inside its column, so `.center` always centers it.
    private final class ScalingImageAttachment: NSTextAttachment {
        /// Upper bound on display width — the image's natural width capped to the
        /// render's `maxWidth`. Small images are never upscaled past this.
        private let maxDisplayWidth: CGFloat
        /// height / width of the source image, preserved when scaling.
        private let aspectRatio: CGFloat

        init(image: UIImage, maxDisplayWidth: CGFloat, aspectRatio: CGFloat) {
            self.maxDisplayWidth = maxDisplayWidth
            self.aspectRatio = aspectRatio
            super.init(data: nil, ofType: nil)
            self.image = image
            self.bounds = CGRect(
                x: 0, y: 0, width: maxDisplayWidth, height: maxDisplayWidth * aspectRatio)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func attachmentBounds(
            for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
            glyphPosition position: CGPoint, characterIndex charIndex: Int
        ) -> CGRect {
            let available = lineFrag.width > 0 ? lineFrag.width : maxDisplayWidth
            let width = min(maxDisplayWidth, available)
            return CGRect(x: 0, y: 0, width: width, height: width * aspectRatio)
        }
    }

    private static func attributedImage(at fileURL: URL, maxWidth: CGFloat) -> NSAttributedString? {
        guard let image = downsampledImage(at: fileURL, maxWidth: maxWidth),
              image.size.width > 0, image.size.height > 0 else { return nil }
        let attachment = ScalingImageAttachment(
            image: image,
            maxDisplayWidth: min(maxWidth, image.size.width),
            aspectRatio: image.size.height / image.size.width)

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

    private static func attributedImagePlaceholder(
        for block: ArticleContent.Block, maxWidth: CGFloat
    ) -> NSAttributedString? {
        guard let width = block.imageWidth, let height = block.imageHeight,
              width > 0, height > 0 else { return nil }
        let displayWidth = min(maxWidth, CGFloat(width))
        let displayHeight = max(44, displayWidth / CGFloat(width) * CGFloat(height))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: displayWidth, height: displayHeight))
        let image = renderer.image { context in
            LunaColors.secondaryFill.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: displayWidth, height: displayHeight)))
        }
        let attachment = ScalingImageAttachment(
            image: image,
            maxDisplayWidth: displayWidth,
            aspectRatio: displayHeight / displayWidth)

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

        let scale = UIScreen.main.scale
        guard let image = ImageDownsampling.decode(
            path: fileURL.path, scale: scale, maxPixelSize: maxWidth * scale)
        else {
            return nil
        }
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
            .foregroundColor: LunaColors.primaryText,
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
            attributes[.foregroundColor] = LunaColors.secondaryText
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
