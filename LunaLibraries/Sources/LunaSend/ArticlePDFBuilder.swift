//
//  ArticlePDFBuilder.swift
//  Luna
//

import LunaModels
import UIKit

/// Renders extracted article content as a paginated, US-Letter PDF with the
/// downloaded article images inline.
///
/// Pagination is TextKit 1: one `NSTextContainer` per page hung off a single
/// `NSLayoutManager`, which is the only layout path that both breaks lines
/// exactly where the drawn page will and draws `NSTextAttachment` images for
/// free. `UIGraphicsPDFRenderer` then draws each container onto its own page.
///
/// Colours are hard-coded black-on-white rather than taken from `LunaColors`:
/// the PDF leaves the app, so it must not inherit Luna's near-black sky (both
/// Luna appearances are night — see claudedocs/visual-effects.md). For the same
/// reason nothing here reads the trait collection.
///
/// Links are styled (blue, underlined) but are NOT clickable PDF annotations —
/// TextKit drawing into a PDF context emits glyphs, not link annotations. The
/// Markdown export is the format that preserves link destinations.
public struct ArticlePDFBuilder {

    public init() {}

    // MARK: - Page geometry

    /// US Letter at 72dpi — the size every desktop and mobile PDF viewer treats
    /// as the default, and what Preview/Acrobat print without scaling.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54

    /// Hard ceiling on pages, so a pathological block that never consumes glyphs
    /// can't spin the layout loop forever.
    private static let maxPages = 500

    private static var textSize: CGSize {
        CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
    }

    // MARK: - Build

    /// Builds the PDF bytes. `imagesDirectory` is where the ingestor saved the
    /// blocks' `imageFileName` files. Heavy (lays out and rasterizes every
    /// page) — call off the main thread.
    public func build(content: ArticleContent, sourceURLString: String,
                      imagesDirectory: URL) -> Data {
        let attributed = documentString(
            content: content, sourceURLString: sourceURLString,
            imagesDirectory: imagesDirectory)

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let containers = paginate(layoutManager: layoutManager)

        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [
            kCGPDFContextTitle as String: content.title,
            kCGPDFContextCreator as String: "Luna",
        ]
        if let author = content.author, !author.isEmpty {
            info[kCGPDFContextAuthor as String] = author
        }
        format.documentInfo = info

        let bounds = CGRect(origin: .zero, size: Self.pageSize)
        let origin = CGPoint(x: Self.margin, y: Self.margin)
        return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
            for container in containers {
                context.beginPage()
                // Viewers that composite the page over their own chrome would
                // otherwise show a transparent sheet.
                UIColor.white.setFill()
                context.fill(bounds)
                let range = layoutManager.glyphRange(for: container)
                layoutManager.drawBackground(forGlyphRange: range, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
            }
        }
    }

    /// Adds one page-sized container at a time until every glyph is laid out.
    /// Stops early if a fresh container consumes nothing — that means the next
    /// item cannot fit any page, and adding more would loop forever.
    private func paginate(layoutManager: NSLayoutManager) -> [NSTextContainer] {
        var containers: [NSTextContainer] = []
        var laidOutGlyphs = 0
        repeat {
            let container = NSTextContainer(size: Self.textSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let end = NSMaxRange(layoutManager.glyphRange(for: container))
            if end <= laidOutGlyphs && !containers.isEmpty { break }
            containers.append(container)
            laidOutGlyphs = end
        } while laidOutGlyphs < layoutManager.numberOfGlyphs && containers.count < Self.maxPages
        return containers
    }

    // MARK: - Attributed string

    private func documentString(content: ArticleContent, sourceURLString: String,
                                imagesDirectory: URL) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: content.title + "\n", attributes: Self.title))
        if let author = content.author, !author.isEmpty {
            result.append(NSAttributedString(string: author + "\n", attributes: Self.byline))
        }
        if !sourceURLString.isEmpty {
            result.append(NSAttributedString(string: sourceURLString + "\n", attributes: Self.source))
        }

        for block in content.blocks {
            switch block.kind {
            case .paragraph:
                result.append(Self.body(block, attributes: Self.paragraph))
            case .heading:
                result.append(Self.body(block, attributes: Self.heading))
            case .quote:
                result.append(Self.body(block, attributes: Self.quote))
            case .listItem:
                let bullet = NSMutableAttributedString(
                    string: "•\t", attributes: Self.listItem)
                bullet.append(Self.body(block, attributes: Self.listItem))
                result.append(bullet)
            case .tableOfContents:
                result.append(NSAttributedString(
                    string: block.text + "\n", attributes: Self.listItem))
            case .caption:
                result.append(Self.body(block, attributes: Self.caption))
            case .image:
                guard let attachment = Self.attachment(
                    for: block, imagesDirectory: imagesDirectory) else { break }
                let line = NSMutableAttributedString(attachment: attachment)
                line.append(NSAttributedString(string: "\n"))
                line.addAttributes(
                    Self.figure, range: NSRange(location: 0, length: line.length))
                result.append(line)
            }
        }
        return result
    }

    /// A block's text with its outbound links visually marked. In-page
    /// `#chapter` jumps get no styling — inside a flat PDF they lead nowhere.
    private static func body(
        _ block: ArticleContent.Block, attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: block.text + "\n", attributes: attributes)
        let length = (block.text as NSString).length
        for link in block.links where !link.isInPageAnchor {
            guard link.length > 0, link.start >= 0, link.start + link.length <= length
            else { continue }
            result.addAttributes(
                [.foregroundColor: UIColor(red: 0.05, green: 0.31, blue: 0.68, alpha: 1),
                 .underlineStyle: NSUnderlineStyle.single.rawValue],
                range: NSRange(location: link.start, length: link.length))
        }
        return result
    }

    /// The downloaded image, scaled to fit the text column and at most 60% of a
    /// page's height. Oversized attachments are what would otherwise produce a
    /// container that lays out nothing — see `paginate`.
    ///
    /// The file is resolved through `ArticleImageFiles`, NOT from
    /// `block.imageFileName` alone: content is persisted before its images
    /// finish downloading, so a nil name routinely means "on disk, just not
    /// recorded yet". An animated GIF contributes its first frame — PDF has no
    /// animation to give it.
    private static func attachment(
        for block: ArticleContent.Block, imagesDirectory: URL
    ) -> NSTextAttachment? {
        guard let fileURL = ArticleImageFiles.localFile(for: block, in: imagesDirectory),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data), image.size.width > 0, image.size.height > 0
        else { return nil }

        let maxHeight = textSize.height * 0.6
        let scale = min(1, min(textSize.width / image.size.width, maxHeight / image.size.height))
        let attachment = NSTextAttachment(image: image)
        attachment.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: (image.size.width * scale).rounded(),
                         height: (image.size.height * scale).rounded()))
        return attachment
    }

    // MARK: - Styles

    /// `lineHeightMultiple` is for prose only. Applying it to the figure style
    /// would inflate the image's line fragment by 20% — TextKit puts the extra
    /// height ABOVE the baseline, so the image gets a fat gap over it and can be
    /// bumped to the next page while a fifth of the current one sits empty.
    private static func paragraphStyle(
        spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 10,
        indent: CGFloat = 0, alignment: NSTextAlignment = .natural,
        lineHeightMultiple: CGFloat = 1.2
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.alignment = alignment
        style.lineHeightMultiple = lineHeightMultiple
        return style
    }

    private static let ink = UIColor.black
    private static let mutedInk = UIColor(white: 0.35, alpha: 1)

    private static let title: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 24, weight: .bold),
        .foregroundColor: ink,
        .paragraphStyle: paragraphStyle(spacingAfter: 6),
    ]

    private static let byline: [NSAttributedString.Key: Any] = [
        .font: UIFont.italicSystemFont(ofSize: 12),
        .foregroundColor: mutedInk,
        .paragraphStyle: paragraphStyle(spacingAfter: 2),
    ]

    private static let source: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 10),
        .foregroundColor: mutedInk,
        .paragraphStyle: paragraphStyle(spacingAfter: 22),
    ]

    private static let paragraph: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 12),
        .foregroundColor: ink,
        .paragraphStyle: paragraphStyle(),
    ]

    private static let heading: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
        .foregroundColor: ink,
        .paragraphStyle: paragraphStyle(spacingBefore: 14, spacingAfter: 6),
    ]

    private static let quote: [NSAttributedString.Key: Any] = [
        .font: UIFont.italicSystemFont(ofSize: 12),
        .foregroundColor: mutedInk,
        .paragraphStyle: paragraphStyle(indent: 20),
    ]

    private static let listItem: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 12),
        .foregroundColor: ink,
        .paragraphStyle: paragraphStyle(spacingAfter: 4, indent: 16),
    ]

    /// A figure's caption: small, muted, and tucked under the picture — hence no
    /// leading space, since `figure` already left room after the image.
    private static let caption: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 10),
        .foregroundColor: mutedInk,
        .paragraphStyle: paragraphStyle(spacingAfter: 12),
    ]

    private static let figure: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 12),
        .foregroundColor: ink,
        .paragraphStyle: paragraphStyle(
            spacingBefore: 6, spacingAfter: 12, alignment: .center, lineHeightMultiple: 1),
    ]
}
