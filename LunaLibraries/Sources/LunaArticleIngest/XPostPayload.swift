//
//  XPostPayload.swift
//  LunaArticleIngest
//

import Foundation

/// The decoded shape of one keyless fxtwitter response, covering both endpoints
/// the X text path uses:
///
///   • `GET /2/thread/<id>`  → `{ status, thread, author }` — the UNROLLED
///     self-reply chain. Returns the whole thread from ANY member (verified
///     against a mid-thread id), so there is no backward `replying_to_status`
///     walk to do; the array is already author-only and in posting order.
///   • `GET /status/<id>`    → `{ tweet }` — the v1 single-post fallback used
///     when the v2 thread route is unavailable.
///
/// Both decode into this one type so `XPostExtractor` has a single input shape.
/// Property names deliberately keep the wire's snake_case (matching the existing
/// `XMetadataFetcher` payload in LunaPlatforms) rather than adding a CodingKeys
/// wall — these types exist only to be decoded.
///
/// X itself serves NONE of this to an unauthenticated client: `x.com/<user>/status/<id>`
/// returns a JS login shell with no post text in it, so HTML article extraction can
/// never work on an X link. fxtwitter is a keyless read-only mirror of the public
/// post, which is why the text path goes through an API instead of the fetch/extract
/// tiers every other article uses.
public struct XPostPayload: Decodable {
    /// v2: the post the URL actually named.
    public let status: Post?
    /// v2: the unrolled self-thread, in posting order, root first. A single-post
    /// (non-thread) URL comes back as a one-element array.
    public let thread: [Post]?
    /// v2: the thread author, when the response carries it separately.
    public let author: Author?
    /// v1 fallback: the single post.
    public let tweet: Post?

    public init(status: Post? = nil, thread: [Post]? = nil, author: Author? = nil, tweet: Post? = nil) {
        self.status = status
        self.thread = thread
        self.author = author
        self.tweet = tweet
    }

    /// The posts to read, in order: the v2 unrolled thread when present,
    /// otherwise whichever single post the response carried.
    public var posts: [Post] {
        if let thread, !thread.isEmpty { return thread }
        if let status { return [status] }
        if let tweet { return [tweet] }
        return []
    }

    /// The authoritative author: the thread's, else the first post's.
    public var rootAuthor: Author? { author ?? posts.first?.author }

    /// The post the SHARED URL actually named — which is not necessarily the
    /// thread root, since a thread unrolls from any member. Used to decide
    /// whether the user shared a video (media) or text (reader) item.
    public var sharedPost: Post? { status ?? tweet ?? posts.first }

    public struct Author: Decodable {
        public let screen_name: String?
        public let name: String?
        public let id: String?

        public init(screen_name: String? = nil, name: String? = nil, id: String? = nil) {
            self.screen_name = screen_name
            self.name = name
            self.id = id
        }

        /// "Name (@handle)" — the byline shown on the saved card, falling back to
        /// whichever half the payload carried.
        public var byline: String? {
            switch (name?.trimmedNonEmptyValue, screen_name?.trimmedNonEmptyValue) {
            case let (name?, handle?): return "\(name) (@\(handle))"
            case let (name?, nil): return name
            case let (nil, handle?): return "@\(handle)"
            case (nil, nil): return nil
            }
        }
    }

    public struct Post: Decodable {
        public let id: String?
        /// The DISPLAY text: fxtwitter has already expanded every `t.co` to its
        /// destination inline and dropped the trailing self-link a quoted
        /// post/article/media attachment adds. This is the field to read — the
        /// `raw_text` facet indices are offsets into the UNEXPANDED string and do
        /// not line up with it.
        public let text: String?
        public let author: Author?
        /// X's own long-form composer flag. Present but NOT a usable
        /// long/short discriminator on its own — see `XPostExtractor`.
        public let is_note_tweet: Bool?
        /// An X Article (the premium long-form editor): a real title plus a
        /// Draft.js body. Its presence alone means "long-form".
        public let article: Article?
        public let media: Media?

        public init(
            id: String? = nil, text: String? = nil, author: Author? = nil,
            is_note_tweet: Bool? = nil, article: Article? = nil, media: Media? = nil
        ) {
            self.id = id
            self.text = text
            self.author = author
            self.is_note_tweet = is_note_tweet
            self.article = article
            self.media = media
        }
    }

    public struct Media: Decodable {
        public let all: [Item]?

        public init(all: [Item]? = nil) { self.all = all }

        public struct Item: Decodable {
            /// "photo" / "video" / "gif".
            public let type: String?
            public let url: String?
            public let width: Int?
            public let height: Int?

            public init(type: String? = nil, url: String? = nil, width: Int? = nil, height: Int? = nil) {
                self.type = type
                self.url = url
                self.width = width
                self.height = height
            }
        }

        /// Still images only. A video attachment belongs to the Downloader, never
        /// to a reader body, so it contributes no block here.
        public var photos: [Item] { (all ?? []).filter { $0.type?.lowercased() == "photo" } }

        /// Whether a moving-image attachment is present (video or looping gif).
        public var hasMotionMedia: Bool {
            (all ?? []).contains { ["video", "gif"].contains($0.type?.lowercased() ?? "") }
        }
    }

    /// An X Article: title + a Draft.js (`draft-js` `convertToRaw`) document.
    public struct Article: Decodable {
        public let title: String?
        public let content: DraftContent?

        public init(title: String? = nil, content: DraftContent? = nil) {
            self.title = title
            self.content = content
        }
    }

    /// Draft.js raw content: ordered blocks plus a keyed entity table the blocks'
    /// `entityRanges` point into.
    public struct DraftContent: Decodable {
        public let blocks: [DraftBlock]?
        /// Serialized as an ARRAY of `{key, value}` pairs (not a JSON object).
        public let entityMap: [EntityEntry]?

        public init(blocks: [DraftBlock]? = nil, entityMap: [EntityEntry]? = nil) {
            self.blocks = blocks
            self.entityMap = entityMap
        }

        /// `entityRanges[].key` (an Int) → the entity's URL, for `LINK` entities.
        public var linkURLsByKey: [Int: String] {
            var map: [Int: String] = [:]
            for entry in entityMap ?? [] {
                guard entry.value?.type?.uppercased() == "LINK",
                      let key = Int(entry.key ?? ""),
                      let url = entry.value?.data?.url?.trimmedNonEmptyValue else { continue }
                map[key] = url
            }
            return map
        }

        public struct EntityEntry: Decodable {
            /// A stringified integer on the wire, while `entityRanges[].key` is an Int.
            public let key: String?
            public let value: EntityValue?

            public init(key: String? = nil, value: EntityValue? = nil) {
                self.key = key
                self.value = value
            }
        }

        public struct EntityValue: Decodable {
            public let type: String?
            public let data: EntityData?

            public init(type: String? = nil, data: EntityData? = nil) {
                self.type = type
                self.data = data
            }
        }

        public struct EntityData: Decodable {
            public let url: String?

            public init(url: String? = nil) { self.url = url }
        }
    }

    public struct DraftBlock: Decodable {
        /// Draft.js block type: `unstyled`, `header-one`…`header-six`,
        /// `blockquote`, `unordered-list-item`, `ordered-list-item`,
        /// `code-block`, `atomic`.
        public let type: String?
        public let text: String?
        public let entityRanges: [Range]?

        public init(type: String? = nil, text: String? = nil, entityRanges: [Range]? = nil) {
            self.type = type
            self.text = text
            self.entityRanges = entityRanges
        }

        /// A Draft.js range. `offset`/`length` are JS string code units — i.e.
        /// UTF-16 — which is exactly what `ArticleContent.Link` stores, so they
        /// copy across without conversion.
        public struct Range: Decodable {
            public let offset: Int?
            public let length: Int?
            public let key: Int?

            public init(offset: Int? = nil, length: Int? = nil, key: Int? = nil) {
                self.offset = offset
                self.length = length
                self.key = key
            }
        }
    }
}

extension String {
    /// The trimmed string, or nil when it holds nothing but whitespace. Local to
    /// the X payload decoding (LunaModels' `trimmedNonEmpty` is not visible here).
    var trimmedNonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
