//
//  ArticleContent.swift
//  Clip
//

import Foundation

/// Extracted, formatted article text: an ordered list of text blocks with
/// inline link ranges (UTF-16 offsets, ready for NSAttributedString).
struct ArticleContent: Codable {
    var title: String
    var author: String?
    var blocks: [Block]

    init(title: String, author: String? = nil, blocks: [Block]) {
        self.title = title
        self.author = author
        self.blocks = blocks
    }

    /// One paragraph-level unit of the article.
    struct Block: Codable {
        enum Kind: String, Codable {
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
    struct Link: Codable {
        var start: Int
        var length: Int
        var urlString: String
    }

    var wholeText: String {
        blocks.map(\.text).joined(separator: "\n\n")
    }
}
