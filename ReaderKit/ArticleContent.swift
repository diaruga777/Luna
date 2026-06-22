//
//  ArticleContent.swift
//  Clip
//

import Foundation
import ClipContentRendering

/// Extracted, formatted article text: an ordered list of text blocks with
/// inline link ranges (UTF-16 offsets, ready for NSAttributedString).
struct ArticleContent: Codable, Equatable {
    var title: String
    var author: String?
    var blocks: [Block]

    init(title: String, author: String? = nil, blocks: [Block]) {
        self.title = title
        self.author = author
        self.blocks = blocks
    }

    /// One paragraph-level unit of the article.
    struct Block: Codable, Equatable {
        enum Kind: String, Codable, Equatable {
            case paragraph
            case heading
            case quote
            case listItem
            case image
        }

        var kind: Kind
        var text: String
        var links: [Link]
        /// Remote source for `.image` blocks (set at extraction).
        var imageURLString: String?
        /// Local file (inside the Articles directory) for `.image` blocks,
        /// set once the ingestor has downloaded it.
        var imageFileName: String?

        init(kind: Kind, text: String, links: [Link],
             imageURLString: String? = nil, imageFileName: String? = nil) {
            self.kind = kind
            self.text = text
            self.links = links
            self.imageURLString = imageURLString
            self.imageFileName = imageFileName
        }
    }

    /// An inline link inside a block. `start`/`length` are UTF-16 offsets into `text`.
    struct Link: Codable, Equatable {
        var start: Int
        var length: Int
        var urlString: String
    }

    var wholeText: String {
        ArticleBlockRendering.plainText(blocks: blocks.map(\.text))
    }

    /// Total length of all block text — the cheap heuristic for "is this a real
    /// article vs. a paywall stub / near-empty extraction".
    var bodyTextLength: Int {
        blocks.reduce(0) { $0 + $1.text.count }
    }

    /// Enough body text to be worth reading rather than a paywall stub — the
    /// text-only convenience reading of the shared `ArticleExtraction.isReadableArticle`
    /// predicate (no source HTML, so the publisher-declared lock signal isn't applied).
    /// Callers holding the source HTML should use `ArticleExtraction.isReadableArticle`
    /// for the stronger, HTML-aware judgment.
    var hasReadableBody: Bool {
        ArticleExtraction.isReadableArticle(self, html: nil)
    }

    /// Minimum block-text length for `hasReadableBody`.
    static let readableBodyThreshold = 600

    /// Whether this extracted text reads as a subscription wall / metered teaser
    /// rather than the real article. Delegates to the shared `PaywallDetector`
    /// (text-only here — callers with the source HTML should use
    /// `PaywallDetector.looksPaywalled(content:html:)` for the stronger signal).
    var looksPaywalled: Bool {
        PaywallDetector.textLooksPaywalled(wholeText, bodyLength: bodyTextLength)
    }
}
