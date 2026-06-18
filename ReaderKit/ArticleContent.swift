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

    /// Total length of all block text — the cheap heuristic for "is this a real
    /// article vs. a paywall stub / near-empty extraction".
    var bodyTextLength: Int {
        blocks.reduce(0) { $0 + $1.text.count }
    }

    /// Enough body text to be worth reading rather than a paywall stub. Shared by
    /// the ingestor and both extensions so they agree on the threshold. A body that
    /// clears the length bar but `looksPaywalled` does NOT count — that's a
    /// subscription wall or a crawler teaser, not the article.
    var hasReadableBody: Bool {
        bodyTextLength >= Self.readableBodyThreshold && !looksPaywalled
    }

    /// Minimum block-text length for `hasReadableBody`.
    static let readableBodyThreshold = 600

    /// High-precision phrases that only appear in subscription walls / metered
    /// previews — FT's "Try unlimited access" marketing interstitial, or the WSJ
    /// Wayback snapshot that carries just the lede plus the "personal,
    /// non-commercial use" / "Subscriber Agreement" boilerplate. Deliberately
    /// specific (not a bare "subscribe") so a real article that merely mentions
    /// subscribing isn't misread as a wall.
    private static let paywallMarkers = [
        "subscribe to read", "subscribe to continue", "to continue reading",
        "try unlimited access", "unlimited digital access", "complete digital access",
        "digital access to quality", "cancel anytime", "this article is for subscribers",
        "subscriber agreement", "personal, non-commercial use", "register to continue",
        "sign in to read", "become a subscriber", "start your free trial",
    ]

    /// A SHORT body containing subscription-wall language is a stub/teaser, not the
    /// article — so the resolver should fall back to a full archive. Real articles
    /// run long, so they're never flagged even if a marker appears in a footer.
    var looksPaywalled: Bool {
        guard bodyTextLength < Self.paywallStubMaxLength else { return false }
        let lowercased = wholeText.lowercased()
        return Self.paywallMarkers.contains { lowercased.contains($0) }
    }

    /// Bodies shorter than this are eligible to be judged a paywall stub.
    static let paywallStubMaxLength = 2500
}
