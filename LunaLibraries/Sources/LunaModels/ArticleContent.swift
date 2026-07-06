//
//  ArticleContent.swift
//  LunaModels
//

import Foundation

/// Extracted, formatted article text: an ordered list of text blocks with
/// inline link ranges (UTF-16 offsets, ready for NSAttributedString).
public struct ArticleContent: Codable, Equatable {
    public var title: String
    public var author: String?
    public var blocks: [Block]

    public init(title: String, author: String? = nil, blocks: [Block]) {
        self.title = title
        self.author = author
        self.blocks = blocks
    }

    /// One paragraph-level unit of the article.
    public struct Block: Codable, Equatable {
        public enum Kind: String, Codable, Equatable {
            case paragraph
            case heading
            case quote
            case listItem
            case image
        }

        public var kind: Kind
        public var text: String
        public var links: [Link]
        /// Remote source for `.image` blocks (set at extraction).
        public var imageURLString: String?
        /// Local file (inside the Articles directory) for `.image` blocks,
        /// set once the ingestor has downloaded it.
        public var imageFileName: String?
        /// Declared source dimensions for `.image` blocks, when the HTML provided
        /// them. Used to reserve layout before the bytes are downloaded.
        public var imageWidth: Int?
        public var imageHeight: Int?

        public init(kind: Kind, text: String, links: [Link],
                    imageURLString: String? = nil, imageFileName: String? = nil,
                    imageWidth: Int? = nil, imageHeight: Int? = nil) {
            self.kind = kind
            self.text = text
            self.links = links
            self.imageURLString = imageURLString
            self.imageFileName = imageFileName
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
        }
    }

    /// An inline link inside a block. `start`/`length` are UTF-16 offsets into `text`.
    public struct Link: Codable, Equatable {
        public var start: Int
        public var length: Int
        public var urlString: String

        public init(start: Int, length: Int, urlString: String) {
            self.start = start
            self.length = length
            self.urlString = urlString
        }
    }

    public var wholeText: String {
        ArticleBlockRendering.plainText(blocks: blocks.map(\.text))
    }

    /// Total length of all block text — the cheap heuristic for "is this a real
    /// article vs. a paywall stub / near-empty extraction".
    public var bodyTextLength: Int {
        blocks.reduce(0) { $0 + $1.text.count }
    }

    /// Minimum block-text length for `hasReadableBody`.
    public static let readableBodyThreshold = 1200

    // MARK: - Preload heuristics (single source of truth)

    /// Whether this page is worth rendering with the reader (the heuristic shared by
    /// the preloader, the inline link viewer, and the RabbitHole probe). A page needs
    /// enough non-empty text spread across enough blocks to read like an article.
    public var isArticleLike: Bool {
        let nonEmpty = blocks.filter { !$0.text.isEmpty }
        let totalText = nonEmpty.reduce(0) { $0 + $1.text.count }
        return totalText >= 600 && nonEmpty.count >= 3
    }

    /// De-duplicated absolute http(s) outbound links on this page, in document order
    /// (the set the preloader crawls and the link viewer keys its cache by).
    public var outboundURLs: [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for block in blocks {
            for link in block.links {
                guard seen.insert(link.urlString).inserted,
                      let url = URL(string: link.urlString),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
                else { continue }
                result.append(url)
            }
        }
        return result
    }
}
