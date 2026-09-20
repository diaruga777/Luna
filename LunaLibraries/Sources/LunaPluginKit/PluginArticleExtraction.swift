//
//  PluginArticleExtraction.swift
//  LunaPluginKit
//

import Foundation
import LunaHTMLClassification
import LunaModels
import SwiftSoup

/// `luna.html.article` — Luna's own main-content extraction, offered to a
/// plugin.
///
/// A generated plugin that hand-writes a readability pass keeps the site's
/// related-links rail and drops the article's own images. This runs the
/// extractor Luna's article ingest runs (`ArticleExtractor`, LunaHTMLClassification
/// — a kind-neutral module every kit already carries), then renders the
/// blocks it found back to the small clean HTML an `ArticleModel` wants.
///
/// It is native in every process that can run it: the app and the
/// share/action extensions through `PluginHTMLBridge`, and the Safari
/// content-script world through the `plugins.article` native message, which
/// `SafariPluginMessages+Luna.swift` answers by calling this same function.
/// The node harness approximates it with `@mozilla/readability`.
public enum PluginArticleExtraction {

    /// What a plugin reads back. Every field is already absolute and clean;
    /// `html` carries only the tags `docs/plugins/api.md` lists for an
    /// `ArticleModel`.
    public struct Article: Equatable, Sendable {
        public let title: String
        public let html: String
        public let text: String
        public let author: String?
        public let publishedAt: String?
        public let leadImageURL: String?
        public let excerpt: String?
    }

    /// The largest excerpt a page's own description may contribute. The Model
    /// caps `excerpt` at 1000 characters, so a longer one is trimmed here
    /// rather than rejected on adoption.
    public static let excerptLimit = 1000

    /// `nil` when the page has no article body — the answer a plugin returns
    /// to let Luna's own extraction continue.
    public static func extract(html: String, baseURL: URL) -> Article? {
        guard let content = try? ArticleExtractor().extract(html: html, baseURL: baseURL),
              !content.blocks.isEmpty
        else { return nil }
        let document = try? SwiftSoup.parse(html, baseURL.absoluteString)
        let metadata = document.map { PluginHTMLMetadata.read(from: $0) } ?? [:]
        let leadImage = content.blocks.first { $0.kind == .image }?.imageURLString
        return Article(
            title: content.title,
            html: articleHTML(blocks: content.blocks),
            text: content.wholeText,
            author: content.author ?? metadata["author"],
            publishedAt: metadata["published"].flatMap(PluginTextParsing.date)
                ?? metadata["published"],
            leadImageURL: metadata["image"] ?? leadImage,
            excerpt: metadata["description"].map { String($0.prefix(excerptLimit)) })
    }

    /// The extracted blocks as the clean subset an `ArticleModel` carries:
    /// `p`, `h2`, `blockquote`, `ul`/`li`, `figure`/`figcaption`, `img` and
    /// inline `a`. Consecutive list items share one `ul`.
    static func articleHTML(blocks: [ArticleContent.Block]) -> String {
        var parts: [String] = []
        var openList = false
        func closeList() {
            if openList { parts.append("</ul>"); openList = false }
        }
        for block in blocks {
            switch block.kind {
            case .listItem:
                if !openList { parts.append("<ul>"); openList = true }
                parts.append("<li>\(inlineHTML(block))</li>")
            case .paragraph:
                closeList()
                parts.append("<p>\(inlineHTML(block))</p>")
            case .heading:
                closeList()
                parts.append("<h2>\(inlineHTML(block))</h2>")
            case .quote:
                closeList()
                parts.append("<blockquote><p>\(inlineHTML(block))</p></blockquote>")
            case .caption:
                closeList()
                parts.append("<figcaption>\(inlineHTML(block))</figcaption>")
            case .image:
                closeList()
                guard let source = block.imageURLString else { continue }
                let alt = block.text.isEmpty ? "" : " alt=\"\(escape(block.text))\""
                parts.append("<figure><img src=\"\(escape(source))\"\(alt)></figure>")
            case .tableOfContents:
                // Navigation furniture the reader shows and no consumer reads.
                continue
            }
        }
        closeList()
        return parts.joined()
    }

    /// One block's text with its link ranges as anchors. The ranges are UTF-16
    /// offsets, which is how the extractor recorded them.
    private static func inlineHTML(_ block: ArticleContent.Block) -> String {
        let units = Array(block.text.utf16)
        let links = block.links
            .filter { $0.start >= 0 && $0.length > 0 && $0.start + $0.length <= units.count }
            .sorted { $0.start < $1.start }
        var out = ""
        var cursor = 0
        for link in links where link.start >= cursor {
            out += escape(string(units[cursor..<link.start]))
            let label = escape(string(units[link.start..<(link.start + link.length)]))
            out += "<a href=\"\(escape(link.urlString))\">\(label)</a>"
            cursor = link.start + link.length
        }
        out += escape(string(units[cursor...]))
        return out
    }

    private static func string(_ units: ArraySlice<UInt16>) -> String {
        String(decoding: Array(units), as: UTF16.self)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
