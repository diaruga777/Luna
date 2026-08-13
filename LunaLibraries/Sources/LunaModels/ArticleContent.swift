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
            /// One row of an in-page table of contents (the page's own
            /// chapter-mark list). Renders in the scroll reader as a tappable
            /// jump, and is skipped by every word-stream consumer — see
            /// `isReadableProse`.
            case tableOfContents
            /// A figure's caption/credit line — the text the page prints under
            /// (or over) a picture. It belongs to the picture, not to the prose:
            /// the scroll reader shows it tucked under its image, and every
            /// word-stream consumer skips it, so RSVP never flashes a photo
            /// credit mid-sentence and read-aloud never speaks one. See
            /// `isReadableProse`.
            case caption
        }

        public var kind: Kind
        public var text: String
        public var links: [Link]
        /// The HTML `id`/`name` this block's element carried, when some in-page
        /// link on the page pointed at it — i.e. the block is a jump destination.
        /// Nil for the overwhelming majority of blocks; only referenced anchors
        /// are recorded (see `InPageAnchors`).
        public var anchorID: String?
        /// Remote source for `.image` blocks (set at extraction).
        public var imageURLString: String?
        /// Local file (inside the Articles directory) for `.image` blocks,
        /// set once the ingestor has downloaded it.
        public var imageFileName: String?
        /// Declared source dimensions for `.image` blocks, when the HTML provided
        /// both of them. Used to reserve layout before the bytes are downloaded —
        /// there is no representable state with only one dimension known.
        public var imageSize: BlockImageSize?

        public init(kind: Kind, text: String, links: [Link],
                    imageURLString: String? = nil, imageFileName: String? = nil,
                    imageSize: BlockImageSize? = nil,
                    anchorID: String? = nil) {
            self.kind = kind
            self.text = text
            self.links = links
            self.imageURLString = imageURLString
            self.imageFileName = imageFileName
            self.imageSize = imageSize
            self.anchorID = anchorID
        }

        /// Whether this block belongs to the article's word stream — the ONE
        /// index space `RSVPEngine`, `WordMap`, `SpeechController` and the audio
        /// script all share. A table of contents is navigation furniture and a
        /// caption belongs to its picture: both are rendered but never read, and
        /// every one of those consumers must agree to skip them or their word
        /// indices drift apart.
        public var isReadableProse: Bool { kind != .tableOfContents && kind != .caption }

        private enum CodingKeys: String, CodingKey {
            case kind, text, links, anchorID, imageURLString, imageFileName, imageSize
            // Old on-disk keys, from before width and height merged into `imageSize`.
            // Decoding still falls back to them for saves made before the merge.
            case imageWidth, imageHeight
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(Kind.self, forKey: .kind)
            text = try container.decode(String.self, forKey: .text)
            links = try container.decode([Link].self, forKey: .links)
            anchorID = try container.decodeIfPresent(String.self, forKey: .anchorID)
            imageURLString = try container.decodeIfPresent(String.self, forKey: .imageURLString)
            imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
            if let size = try container.decodeIfPresent(BlockImageSize.self, forKey: .imageSize) {
                imageSize = size
            } else if let width = try container.decodeIfPresent(Int.self, forKey: .imageWidth),
                      let height = try container.decodeIfPresent(Int.self, forKey: .imageHeight) {
                imageSize = BlockImageSize(width: width, height: height)
            } else {
                imageSize = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(links, forKey: .links)
            try container.encodeIfPresent(anchorID, forKey: .anchorID)
            try container.encodeIfPresent(imageURLString, forKey: .imageURLString)
            try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
            try container.encodeIfPresent(imageSize, forKey: .imageSize)
        }
    }

    /// A `.image` block's declared source dimensions. Both fields are always
    /// present together, so no consumer needs to handle a partial state.
    public struct BlockImageSize: Codable, Equatable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// An inline link inside a block. `start`/`length` are UTF-16 offsets into `text`.
    public struct Link: Codable, Equatable {
        public var start: Int
        public var length: Int
        public var urlString: String
        /// Set when the link is a jump WITHIN this page (a `#chapter` href) rather
        /// than a navigation: the `anchorID` of the block it targets. Decided at
        /// extraction, where the document's own base URL is authoritative — the
        /// reader must never re-derive "is this the same page?" from the absolute
        /// URL, which a redirect or an archive capture makes unreliable.
        public var anchorID: String?

        public init(start: Int, length: Int, urlString: String, anchorID: String? = nil) {
            self.start = start
            self.length = length
            self.urlString = urlString
            self.anchorID = anchorID
        }

        /// True for a `#chapter` jump inside this same article.
        public var isInPageAnchor: Bool { anchorID != nil }
    }

    /// The block an in-page link targets, or nil when the destination didn't
    /// survive extraction. Anchors are compared exactly: they are copied
    /// verbatim from the same document's markup, so no normalization applies.
    public func blockIndex(forAnchorID anchorID: String) -> Int? {
        blocks.firstIndex { $0.anchorID == anchorID }
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
    /// In-page jumps are not outbound — crawling them would refetch this article.
    public var outboundURLs: [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for block in blocks {
            for link in block.links {
                guard !link.isInPageAnchor,
                      seen.insert(link.urlString).inserted,
                      let url = URL(string: link.urlString),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
                else { continue }
                result.append(url)
            }
        }
        return result
    }
}
