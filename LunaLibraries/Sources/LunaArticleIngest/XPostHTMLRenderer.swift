//
//  XPostHTMLRenderer.swift
//  LunaArticleIngest
//

import LunaModels
import Foundation

/// Renders extracted post content back out as a small, self-contained HTML
/// document — the `html` half of a `SocialTextArticle`.
///
/// X gives an unauthenticated client no article markup at all, so there is no
/// real source HTML to carry. But the article artifact stages downstream are
/// written against source HTML, not content: the card thumbnail comes from an
/// `og:image` (`ArticleCoverThumbnail`) and the offline copy comes from
/// `WebArchiveCapturer`. Rendering the post we just extracted satisfies both
/// with the post's own material — and keeps the archiver from navigating to
/// x.com and capturing a login wall instead.
///
/// Pure and dependency-free, so `XPostHTMLRendererTests` can assert the escaping.
enum XPostHTMLRenderer {

    /// A minimal document for `content`: `og:` metadata (including the first
    /// image as `og:image`, which is what becomes the card thumbnail) plus the
    /// blocks as semantic HTML.
    static func html(for content: ArticleContent, url: URL) -> String {
        let leadImage = content.blocks.first { $0.kind == .image }?.imageURLString

        var head = """
            <meta charset="utf-8">
            <meta property="og:type" content="article">
            <meta property="og:title" content="\(attribute(content.title))">
            <meta property="og:url" content="\(attribute(url.absoluteString))">
            <title>\(escaped(content.title))</title>
            """
        if let author = content.author {
            head += "\n<meta name=\"author\" content=\"\(attribute(author))\">"
        }
        if let leadImage {
            head += "\n<meta property=\"og:image\" content=\"\(attribute(leadImage))\">"
        }

        var body = "<h1>\(escaped(content.title))</h1>"
        if let author = content.author {
            body += "\n<p class=\"byline\">\(escaped(author))</p>"
        }
        body += "\n" + content.blocks.map(element(for:)).joined(separator: "\n")

        return """
            <!DOCTYPE html>
            <html>
            <head>
            \(head)
            </head>
            <body>
            <article>
            \(body)
            </article>
            </body>
            </html>
            """
    }

    /// One block as its HTML element, with the block's inline links applied.
    private static func element(for block: ArticleContent.Block) -> String {
        switch block.kind {
        case .image:
            guard let source = block.imageURLString else { return "" }
            var tag = "<img src=\"\(attribute(source))\""
            if let width = block.imageWidth { tag += " width=\"\(width)\"" }
            if let height = block.imageHeight { tag += " height=\"\(height)\"" }
            return tag + ">"
        case .heading:
            return "<h2>\(linked(block))</h2>"
        case .quote:
            return "<blockquote><p>\(linked(block))</p></blockquote>"
        case .listItem:
            return "<ul><li>\(linked(block))</li></ul>"
        case .caption:
            return "<figcaption>\(linked(block))</figcaption>"
        case .paragraph, .tableOfContents:
            return "<p>\(linked(block))</p>"
        }
    }

    /// The block's text with its links wrapped in anchors. Links are applied from
    /// the END backwards so each splice leaves the earlier offsets valid, and each
    /// range is validated against the text — an out-of-range link is skipped
    /// rather than allowed to corrupt the markup.
    private static func linked(_ block: ArticleContent.Block) -> String {
        let text = block.text as NSString
        let ordered = block.links
            .filter { $0.start >= 0 && $0.length > 0 && $0.start + $0.length <= text.length }
            .sorted { $0.start > $1.start }

        var result = ""
        var cursor = text.length
        for link in ordered {
            let tail = NSRange(location: link.start + link.length, length: cursor - (link.start + link.length))
            guard tail.length >= 0 else { continue }
            let label = text.substring(with: NSRange(location: link.start, length: link.length))
            result = "<a href=\"\(attribute(link.urlString))\">\(escaped(label))</a>"
                + escaped(text.substring(with: tail)) + result
            cursor = link.start
        }
        return escaped(text.substring(to: cursor)) + result
    }

    /// Escapes text content. `&` first, so the entities it introduces aren't
    /// double-escaped by the later replacements.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes a value going inside a double-quoted attribute.
    private static func attribute(_ value: String) -> String {
        escaped(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
