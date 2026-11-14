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

public extension NSAttributedString.Key {
    /// Carried by an in-page jump — a table-of-contents row, a footnote marker —
    /// alongside `.link`: the `anchorID` of the block it targets. The scroll
    /// reader scrolls to that block instead of opening the link, which for a
    /// same-page href would only reopen the article the reader is already in.
    static let lunaInPageAnchor = NSAttributedString.Key("LunaInPageAnchor")
}

/// Builds the attributed string for the scrolling reader from extracted blocks,
/// styling headings/quotes/lists, attaching tappable link attributes, and
/// inlining downloaded article images as text attachments.
public enum ArticleTextRenderer {

    /// Attachments clamp to their actual TextKit column. Keep the decode/layout
    /// cap identical across the prefix and full render so a later swap cannot
    /// resize an image that is already visible.
    static let maximumImageWidth: CGFloat = 660

    /// Fix image geometry for this reader session before its first layout. Old
    /// saves and failed downloads may have no dimensions; they still need a box.
    /// The fallback is presentation state, never written back to the saved article.
    static func reservingImageLayout(in content: ArticleContent) -> ArticleContent {
        var reserved = content
        for index in reserved.blocks.indices where reserved.blocks[index].kind == .image {
            let block = reserved.blocks[index]
            // Existing local pixels supply their source dimensions at render
            // time. Only unavailable images need a fixed fallback before fetch.
            guard block.imageFileName == nil, layoutImageSize(for: block) == nil else { continue }
            let size = fallbackImageSize
            reserved.blocks[index].imageSize = .init(width: Int(size.width), height: Int(size.height))
        }
        return reserved
    }

    private static let fallbackImageSize = CGSize(width: 1200, height: 800)

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
        render(content, characterBudget: characterBudget, includesTitle: includesTitle,
               maximumImageWidth: maximumImageWidth)
    }

    struct PreparedContent {
        let rendered: RenderedArticle
        let wordMap: WordMap
    }

    /// Only immutable article/style inputs cross to the worker. A text view and
    /// its live TextKit stack are never accessed there.
    @MainActor
    static func prepareFullContent(
        _ content: ArticleContent, includesTitle: Bool,
        traits: UITraitCollection, maximumImageWidth: CGFloat
    ) async -> PreparedContent {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                var rendered: RenderedArticle!
                traits.performAsCurrent {
                    rendered = render(content, characterBudget: nil, includesTitle: includesTitle,
                                      maximumImageWidth: maximumImageWidth)
                }
                return PreparedContent(rendered: rendered, wordMap: WordMap(content: content, rendered: rendered))
            }
        }.value
    }

    private static func render(
        _ content: ArticleContent, characterBudget: Int?, includesTitle: Bool,
        maximumImageWidth: CGFloat
    ) -> RenderedArticle {
        let result = NSMutableAttributedString()
        var blockTextRanges: [NSRange?] = []
        var imageRanges: [(NSRange, URL)] = []
        let imagesDirectory = SavesStore.shared.articlesDirectory
        // Cap to the readable text column so images don't overflow on iPad.
        let maxImageWidth = maximumImageWidth

        if includesTitle {
            let titleParagraph = NSMutableParagraphStyle()
            titleParagraph.paragraphSpacing = content.author == nil ? 24 : 8
            result.append(NSAttributedString(
                string: content.title + "\n",
                attributes: [
                    .font: bodyFont(size: 30, weight: .bold),
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
        var rule: NSAttributedString?

        for (index, block) in content.blocks.enumerated() {
            // Stop once the budget is exceeded — but only AFTER at least one body
            // block is in (so the prefix is never empty / shorter than a screen).
            if let budget = characterBudget, includedTextCount > budget {
                truncated = true
                break
            }
            if index > 0, let sectionBreak = block.sectionBreakBefore {
                switch sectionBreak {
                case .space:
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont(size: 10, weight: .regular),
                    ]))
                case .rule:
                    let divider = rule ?? sectionRule()
                    rule = divider
                    result.append(divider)
                }
            }
            if block.kind == .image {
                if let fileName = block.imageFileName,
                   let imageString = attributedImage(
                       at: imagesDirectory.appendingPathComponent(fileName),
                       block: block,
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
            // The gap that lets the article resume after the chapter marks is
            // owed by the LAST row of the run, which only its neighbour reveals.
            let closesTableOfContents = block.kind == .tableOfContents
                && content.blocks[safe: index + 1]?.kind != .tableOfContents
            let (blockString, textOffsetInBlock) = attributedString(
                for: block, closesTableOfContents: closesTableOfContents)
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

    private static func sectionRule() -> NSAttributedString {
        let size = CGSize(width: 96, height: 1)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            LunaColors.separator.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: size)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 14
        let line = NSMutableAttributedString(attachment: attachment)
        line.append(NSAttributedString(string: "\n"))
        line.addAttributes([.paragraphStyle: paragraph, .font: UIFont.systemFont(ofSize: 8)],
                           range: NSRange(location: 0, length: line.length))
        return line
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

    private static func attributedImage(
        at fileURL: URL, block: ArticleContent.Block, maxWidth: CGFloat
    ) -> NSAttributedString? {
        let sourceSize = sourceImageSize(at: fileURL)
        guard let image = downsampledImage(at: fileURL, maxWidth: maxWidth, sourceSize: sourceSize),
              image.size.width > 0, image.size.height > 0 else { return nil }
        // A decoded bitmap's point size depends on device scale and ImageIO's
        // longest-edge limit. It must not decide document geometry: a tall image
        // would otherwise shrink when its placeholder is replaced by pixels.
        let size = layoutImageSize(for: block) ?? sourceSize
            ?? image.size
        let attachment = ScalingImageAttachment(
            image: fittedImage(image, sourceSize: sourceSize ?? image.size, layoutSize: size, maxWidth: maxWidth),
            maxDisplayWidth: min(maxWidth, size.width),
            aspectRatio: size.height / size.width)

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
        let size = layoutImageSize(for: block) ?? fallbackImageSize
        let displayWidth = min(maxWidth, size.width)
        let displayHeight = displayWidth / size.width * size.height
        // A solid pixel scales without allocating a full portrait-sized bitmap.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { context in
            LunaColors.secondaryFill.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
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

    /// A guessed or inaccurate publisher ratio must never stretch the photograph.
    /// Letterbox inside the reserved box without changing surrounding text layout.
    private static func fittedImage(
        _ image: UIImage, sourceSize: CGSize, layoutSize: CGSize, maxWidth: CGFloat
    ) -> UIImage {
        guard abs(sourceSize.height / sourceSize.width - layoutSize.height / layoutSize.width) > 0.01
        else { return image }
        let width = min(maxWidth, layoutSize.width)
        let box = CGSize(width: width, height: width * layoutSize.height / layoutSize.width)
        let ratio = min(box.width / image.size.width, box.height / image.size.height)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return UIGraphicsImageRenderer(size: box).image { _ in
            image.draw(in: CGRect(x: (box.width - size.width) / 2,
                                  y: (box.height - size.height) / 2,
                                  width: size.width, height: size.height))
        }
    }

    private static func layoutImageSize(for block: ArticleContent.Block) -> CGSize? {
        guard let size = block.imageSize, size.width > 0, size.height > 0 else { return nil }
        return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
    }

    private static func sourceImageSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return [5, 6, 7, 8].contains(orientation)
            ? CGSize(width: CGFloat(height), height: CGFloat(width))
            : CGSize(width: CGFloat(width), height: CGFloat(height))
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
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Decodes the image already scaled down — never holds the full-size bitmap.
    /// Cached so navigating back into an article (or reopening it) is instant.
    private static func downsampledImage(
        at fileURL: URL, maxWidth: CGFloat, sourceSize: CGSize?
    ) -> UIImage? {
        let key = "\(fileURL.path)|\(Int(maxWidth.rounded()))" as NSString
        if let cached = decodedCache.object(forKey: key) { return cached }

        let scale = UIScreen.main.scale
        // ImageIO's cap is the LONGEST edge, while this renderer limits WIDTH.
        // A portrait must retain enough pixels across the visible text column.
        let longestEdgeRatio = sourceSize.map { max(1, $0.height / $0.width) } ?? 1
        guard let image = ImageDownsampling.decode(
            path: fileURL.path, scale: scale, maxPixelSize: min(4096, maxWidth * scale * longestEdgeRatio))
        else {
            return nil
        }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        decodedCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Returns the styled block string plus the offset of the block's text
    /// within it (after any bullet prefix).
    private static func attributedString(
        for block: ArticleContent.Block, closesTableOfContents: Bool = false
    ) -> (NSAttributedString, Int) {
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
            attributes[.font] = bodyFont(size: 19, weight: .regular)
        case .heading:
            attributes[.font] = bodyFont(size: 24, weight: .semibold)
            paragraph.paragraphSpacingBefore = 12
        case .quote:
            attributes[.font] = italicBodyFont(size: 19)
            attributes[.foregroundColor] = LunaColors.secondaryText
            paragraph.firstLineHeadIndent = 16
            paragraph.headIndent = 16
        case .listItem:
            attributes[.font] = bodyFont(size: 19, weight: .regular)
            paragraph.headIndent = 18
            prefix = "•  "
        case .caption:
            // A picture's caption/credit: smaller and dimmer than the body, and
            // pulled up tight against the image directly above it so the two read
            // as one figure. Rendered here but never spoken or flashed — see
            // `ArticleContent.Block.isReadableProse`.
            attributes[.font] = bodyFont(size: 15, weight: .regular)
            attributes[.foregroundColor] = LunaColors.secondaryText
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacingBefore = 0
        case .tableOfContents:
            // The page's own chapter marks read as navigation, not prose: a
            // compact indented list, smaller than the body it introduces. Its
            // label (the one row with no jump) sits above the list, unindented.
            let isLabel = block.links.isEmpty
            attributes[.font] = bodyFont(size: 16, weight: isLabel ? .semibold : .regular)
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = closesTableOfContents ? 20 : 3
            if isLabel {
                attributes[.foregroundColor] = LunaColors.secondaryText
                paragraph.paragraphSpacingBefore = 14
                paragraph.paragraphSpacing = closesTableOfContents ? 20 : 6
            } else {
                paragraph.firstLineHeadIndent = 18
                paragraph.headIndent = 18
            }
        }

        // A line separator wraps without the paragraph margin and occupies the
        // same UTF-16 space as the saved newline, so links and word ranges align.
        let lines = block.text.replacingOccurrences(of: "\n", with: "\u{2028}")
        let text = NSMutableAttributedString(string: prefix + lines + "\n", attributes: attributes)
        let prefixLength = (prefix as NSString).length
        let blockLength = (block.text as NSString).length
        if let baseFont = attributes[.font] as? UIFont, let styles = block.inlineStyles {
            for style in styles {
                guard style.start >= 0, style.start < blockLength, style.length > 0,
                      style.length <= blockLength - style.start else { continue }
                let size = style.isLarger ? baseFont.pointSize * 1.25 : baseFont.pointSize
                let font: UIFont
                if style.isBold {
                    font = block.kind == .quote
                        ? ReaderSettings.font.italicFont(size: size, weight: .bold)
                        : ReaderSettings.font.font(size: size, weight: .bold)
                } else {
                    font = baseFont.withSize(size)
                }
                text.addAttribute(.font, value: font, range: NSRange(
                    location: prefixLength + style.start, length: style.length))
            }
        }
        for link in block.links {
            guard let url = URL(string: link.urlString) else { continue }
            let range = NSRange(location: link.start + prefixLength, length: link.length)
            guard range.location + range.length <= text.length else { continue }
            text.addAttribute(.link, value: url, range: range)
            // A same-page jump is resolved by the reader, not by opening the URL.
            if let anchorID = link.anchorID {
                text.addAttribute(.lunaInPageAnchor, value: anchorID, range: range)
            }
        }
        return (text, prefixLength)
    }

    /// Reader type respects the user's typeface and size settings; the size
    /// also follows the system accessibility text size (clamped — see
    /// `ReaderSettings.systemTypeScale`).
    private static func bodyFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        ReaderSettings.font.font(
            size: size * ReaderSettings.effectiveFontScale, weight: weight)
    }

    private static func italicBodyFont(size: CGFloat) -> UIFont {
        ReaderSettings.font.italicFont(size: size * ReaderSettings.effectiveFontScale)
    }
}
