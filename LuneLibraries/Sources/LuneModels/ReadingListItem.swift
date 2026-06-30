//
//  ReadingListItem.swift
//  Lune
//

import Foundation

/// One saved weblink in the reading list.
public struct ReadingListItem: Codable, Identifiable {
    /// Lifecycle of the item's downloaded content.
    public enum State: String, Codable {
        /// Saved but content not yet downloaded/extracted.
        case pending
        /// Content downloaded and extracted; ready to read.
        case ready
        /// Download or extraction failed; retried on next launch / pull-to-refresh.
        case failed
        /// Hard-paywalled article (WSJ, FT, …) whose text couldn't be extracted
        /// directly or from the Wayback Machine, and whose archive.today snapshot
        /// requires solving a CAPTCHA an automated fetch can't pass. The item is
        /// saved (with its title) and shown in the list with a "tap to unlock"
        /// affordance; tapping opens the archive snapshot in a web view where the
        /// user solves the CAPTCHA, after which the article is extracted and the
        /// item transitions to `.ready`.
        case needsCaptcha
    }

    /// How far the user has gotten with the article.
    public enum ReadState: String, Codable {
        /// Never opened — bright in the list.
        case unopened
        /// Opened at least once — dimmed in the list.
        case opened
        /// Finished (scrolled to the bottom, or RSVP played to the end).
        case read
    }

    /// Which reader the user last used for this article.
    public enum ReaderMode: String, Codable {
        /// Plain scrolling text.
        case scroll
        /// Auto-advancing chunk highlight over the scrolling text.
        case highlight
        /// One word/chunk at a time, centered (ReadMaxx-style).
        case rsvp
        /// A locally saved HTML snapshot of the original page.
        case original
    }

    /// Send-to-Kindle delivery status. Absent means never requested.
    public enum SendState: String, Codable {
        /// Send requested but not yet delivered (e.g. article still ingesting,
        /// or the app died mid-send). Retried on pull-to-refresh.
        case queued
        /// Delivered to the SMTP server.
        case sent
        /// Delivery failed. Retried on pull-to-refresh.
        case failed
    }

    public let id: UUID
    public var urlString: String
    public var title: String?
    public var dateAdded: Date
    /// When the user last "bumped" this item in catch-up — re-sorts it to the top of
    /// the reading list and is shown (instead of the save date) on its catch-up card.
    public var bumpDate: Date?
    public var state: State
    /// File name (inside the Articles directory) of the extracted `ArticleContent` JSON.
    public var contentFileName: String?
    /// A preserved `.webarchive` in OriginalArchives, captured from the source page
    /// before parsing. The Original reader loads this artifact directly; it never
    /// rebuilds a page from parsed reader blocks.
    public var originalArchiveFileName: String?
    /// RSVP resume position (word index).
    public var lastWordIndex: Int?
    public var readState: ReadState
    public var lastReaderMode: ReaderMode?
    /// Scroll reader resume position (content offset).
    public var lastScrollOffset: Double?
    /// Read-aloud resume position (word index); non-nil once audio has played.
    public var lastSpokenWordIndex: Int?
    /// Eye-tracking estimate of the last word read (word index); nil when the
    /// feature is disabled or unavailable.
    public var eyeTrackedWordIndex: Int?
    /// Total words in the extracted article (for reading-time estimates).
    public var wordCount: Int?
    /// 0…1 how far the user has gotten (scroll depth or RSVP position).
    public var readingProgress: Double?
    /// YouTube video ID when this item is a video link rather than an article.
    public var youtubeVideoID: String?
    /// YouTube channel name (from oEmbed), shown in the list subtitle.
    public var channelName: String?
    /// Downloaded video thumbnail (inside the Articles directory).
    public var thumbnailFileName: String?
    /// Username of the friend who shared this item to us, when it arrived via
    /// a social message (display only).
    public var sharedByUsername: String?
    /// File extension (e.g. "pdf", "txt", "md") when this item is an imported
    /// document with no web URL. The raw file lives at
    /// `Articles/<id>-source.<documentType>`.
    public var documentType: String?
    /// Per-destination send status (e.g. "kindle", "boox"), keyed by destination
    /// id. Absent = never requested for that destination.
    public var sendStates: [String: SendState]
    /// When the article was last delivered to each destination (the once-per-day
    /// resend guard), keyed by destination id.
    public var datesSent: [String: Date]
    /// When the user last pressed save for this URL while it was already in the
    /// list (the double-save-to-send detection window).
    public var lastSaveAttemptDate: Date?

    /// The content platform this item belongs to (nil = a plain article/document).
    public var platform: ContentPlatform?
    /// Platform item id (tweet id, post shortcode, etc.) — generalizes `youtubeVideoID`.
    public var platformItemID: String?
    /// Artist (music) or show (podcast).
    public var mediaCreatorName: String?
    /// Track (music) or episode (podcast) title.
    public var mediaItemTitle: String?
    /// Which service the original URL came from (music/podcast), if any.
    public var mediaSourceService: MusicProvider?
    /// Where this item was captured from — drives per-source auto-send. Absent
    /// on legacy items (treated as `.manual`).
    public var captureSource: CaptureSource?

    /// When this save is a price tracker (a product page with a price), this
    /// payload carries the watched store URLs, prices, and alert config. Absent
    /// for ordinary articles/media. Its presence is what makes the item render in
    /// the price-tracking section instead of the reader.
    public var priceTracker: PriceTracker?

    public var url: URL? { URL(string: urlString) }

    /// Whether this save is a price tracker rather than an article/media item.
    public var isPriceTracker: Bool { priceTracker != nil }

    /// Capture source for routing/auto-send, defaulting legacy items to `.manual`.
    public var effectiveCaptureSource: CaptureSource { captureSource ?? .manual }

    public var isYouTubeVideo: Bool { youtubeVideoID != nil || platform == .youtube }

    /// The platform for rendering/routing — falls back to `.youtube` for legacy
    /// items saved before `platform` existed.
    public var contentPlatform: ContentPlatform? {
        platform ?? (youtubeVideoID != nil ? .youtube : nil)
    }

    /// A recognized platform item (vs. a plain article/document).
    public var isPlatformItem: Bool { contentPlatform != nil }

    /// A provider-agnostic media item with no shareable http URL.
    public var isURLlessMedia: Bool { contentPlatform?.isURLless ?? false }

    /// An imported document (PDF/text/etc.) rather than a web link or video.
    public var isDocument: Bool { documentType != nil }

    /// `documentType` reduced to a safe file extension — lowercased alphanumerics,
    /// capped — so a crafted value (the field is decoded from App-Group JSON any
    /// process can write) can't smuggle path separators into a file path.
    public var sanitizedDocumentType: String? {
        guard let documentType else { return nil }
        let cleaned = documentType.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? nil : String(cleaned.prefix(8))
    }

    /// Whether `urlString` is a real web page URL (http/https) rather than one of
    /// the synthetic `lunemail://` / `lunedoc://` schemes used for imports.
    public static func isWebPageURL(_ urlString: String) -> Bool {
        guard let scheme = URL(string: urlString)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Whether this item has a real web URL that can be shared (false for
    /// documents and imported emails, whose URLs are synthetic `clip…://` ones).
    public var isShareable: Bool { Self.isWebPageURL(urlString) }

    /// Whether the reader should offer the original-archive view mode for this save.
    ///
    /// EVERY textual save owns an original artifact and should expose it: a
    /// `.webarchive` (or, as a fallback, the live page) for web pages, and the
    /// imported source file for PDFs/other documents. The sole exception is an
    /// EMAIL-text import (`lunemail://`, `captureSource == .email`), which has no
    /// original artifact at all. This is a *capability* of the save's source, not a
    /// statement about whether the archive file has finished downloading — so a web
    /// page never loses the mode just because its `.webarchive` capture is absent.
    public var canHaveOriginalArchive: Bool {
        guard effectiveCaptureSource != .email else { return false }
        return isShareable || isDocument
    }

    /// Only items with a real web URL can be sent to other users.
    public var canShareToFriends: Bool { isShareable }

    /// Send status for one destination (e.g. "kindle", "boox").
    public func sendState(for destinationID: String) -> SendState? { sendStates[destinationID] }
    /// Last delivery time for one destination.
    public func dateSent(for destinationID: String) -> Date? { datesSent[destinationID] }

    public init(urlString: String) {
        self.id = UUID()
        self.urlString = urlString
        self.title = nil
        self.dateAdded = Date()
        self.bumpDate = nil
        self.state = .pending
        self.contentFileName = nil
        self.originalArchiveFileName = nil
        self.lastWordIndex = nil
        self.readState = .unopened
        self.lastReaderMode = nil
        self.lastScrollOffset = nil
        self.lastSpokenWordIndex = nil
        self.eyeTrackedWordIndex = nil
        self.wordCount = nil
        self.readingProgress = nil
        self.youtubeVideoID = nil
        self.channelName = nil
        self.thumbnailFileName = nil
        self.sharedByUsername = nil
        self.documentType = nil
        self.sendStates = [:]
        self.datesSent = [:]
        self.lastSaveAttemptDate = nil
        self.platform = nil
        self.platformItemID = nil
        self.mediaCreatorName = nil
        self.mediaItemTitle = nil
        self.mediaSourceService = nil
        self.captureSource = nil
        self.priceTracker = nil
    }

    #if DEBUG
    /// Deterministic fixture initializer for tests and the UI-test seeding harness.
    /// `seed` derives a stable UUID (so the same fixture round-trips to the same id
    /// across runs), and every field is set explicitly so a fixture is fully
    /// reproducible. DEBUG-only — never reachable in a release build.
    public init(
        seed: String,
        urlString: String,
        title: String?,
        dateAdded: Date,
        state: State = .ready,
        readState: ReadState = .unopened,
        bumpDate: Date? = nil,
        wordCount: Int? = nil,
        readingProgress: Double? = nil,
        lastReaderMode: ReaderMode? = nil,
        sharedByUsername: String? = nil,
        documentType: String? = nil,
        platform: ContentPlatform? = nil,
        platformItemID: String? = nil,
        mediaCreatorName: String? = nil,
        mediaItemTitle: String? = nil,
        mediaSourceService: MusicProvider? = nil,
        youtubeVideoID: String? = nil,
        channelName: String? = nil,
        captureSource: CaptureSource? = nil,
        priceTracker: PriceTracker? = nil
    ) {
        self.id = ReadingListItem.deterministicUUID(from: seed)
        self.urlString = urlString
        self.title = title
        self.dateAdded = dateAdded
        self.bumpDate = bumpDate
        self.state = state
        self.contentFileName = nil
        self.originalArchiveFileName = nil
        self.lastWordIndex = nil
        self.readState = readState
        self.lastReaderMode = lastReaderMode
        self.lastScrollOffset = nil
        self.lastSpokenWordIndex = nil
        self.eyeTrackedWordIndex = nil
        self.wordCount = wordCount
        self.readingProgress = readingProgress
        self.youtubeVideoID = youtubeVideoID
        self.channelName = channelName
        self.thumbnailFileName = nil
        self.sharedByUsername = sharedByUsername
        self.documentType = documentType
        self.sendStates = [:]
        self.datesSent = [:]
        self.lastSaveAttemptDate = nil
        self.platform = platform
        self.platformItemID = platformItemID
        self.mediaCreatorName = mediaCreatorName
        self.mediaItemTitle = mediaItemTitle
        self.mediaSourceService = mediaSourceService
        self.captureSource = captureSource
        self.priceTracker = priceTracker
    }

    /// A stable UUID derived from a seed string (so fixtures get reproducible ids).
    public static func deterministicUUID(from seed: String) -> UUID {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Spread the 64-bit FNV hash across the 16 UUID bytes deterministically.
        var bytes = [UInt8](repeating: 0, count: 16)
        var mix = hash
        for index in 0..<16 {
            bytes[index] = UInt8(truncatingIfNeeded: mix)
            mix = mix &* 0x100000001b3 &+ UInt64(index)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    #endif

    /// Legacy single-destination send keys, read only to migrate old reading-list
    /// JSON into the per-destination `sendStates`/`datesSent` (folded under the
    /// "kindle" id, which is all that existed before).
    private enum LegacyCodingKeys: String, CodingKey {
        case sendState, dateSent, originalPageFileName
    }

    // Manual decoding so items saved before readState existed still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        urlString = try container.decode(String.self, forKey: .urlString)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        bumpDate = try container.decodeIfPresent(Date.self, forKey: .bumpDate)
        state = try container.decode(State.self, forKey: .state)
        contentFileName = try container.decodeIfPresent(String.self, forKey: .contentFileName)
        originalArchiveFileName = try container.decodeIfPresent(String.self, forKey: .originalArchiveFileName)
        // Pre-webarchive builds stored a reconstructed HTML reader page under this
        // key. Retain only the name long enough for delete cleanup; `.html` is never
        // considered an original archive by `ReadingListStore`.
        if originalArchiveFileName == nil {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            originalArchiveFileName = try legacy.decodeIfPresent(String.self, forKey: .originalPageFileName)
        }
        lastWordIndex = try container.decodeIfPresent(Int.self, forKey: .lastWordIndex)
        readState = try container.decodeIfPresent(ReadState.self, forKey: .readState) ?? .unopened
        lastReaderMode = try container.decodeIfPresent(ReaderMode.self, forKey: .lastReaderMode)
        lastScrollOffset = try container.decodeIfPresent(Double.self, forKey: .lastScrollOffset)
        lastSpokenWordIndex = try container.decodeIfPresent(Int.self, forKey: .lastSpokenWordIndex)
        eyeTrackedWordIndex = try container.decodeIfPresent(Int.self, forKey: .eyeTrackedWordIndex)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
        readingProgress = try container.decodeIfPresent(Double.self, forKey: .readingProgress)
        youtubeVideoID = try container.decodeIfPresent(String.self, forKey: .youtubeVideoID)
        channelName = try container.decodeIfPresent(String.self, forKey: .channelName)
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        sharedByUsername = try container.decodeIfPresent(String.self, forKey: .sharedByUsername)
        documentType = try container.decodeIfPresent(String.self, forKey: .documentType)
        if let states = try container.decodeIfPresent([String: SendState].self, forKey: .sendStates) {
            sendStates = states
        } else {
            // Migrate the pre-multi-destination single `sendState` → "kindle".
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let old = try legacy.decodeIfPresent(SendState.self, forKey: .sendState) {
                sendStates = ["kindle": old]
            } else {
                sendStates = [:]
            }
        }
        if let dates = try container.decodeIfPresent([String: Date].self, forKey: .datesSent) {
            datesSent = dates
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let old = try legacy.decodeIfPresent(Date.self, forKey: .dateSent) {
                datesSent = ["kindle": old]
            } else {
                datesSent = [:]
            }
        }
        lastSaveAttemptDate = try container.decodeIfPresent(Date.self, forKey: .lastSaveAttemptDate)
        platform = try container.decodeIfPresent(ContentPlatform.self, forKey: .platform)
        platformItemID = try container.decodeIfPresent(String.self, forKey: .platformItemID)
        mediaCreatorName = try container.decodeIfPresent(String.self, forKey: .mediaCreatorName)
        mediaItemTitle = try container.decodeIfPresent(String.self, forKey: .mediaItemTitle)
        mediaSourceService = try container.decodeIfPresent(MusicProvider.self, forKey: .mediaSourceService)
        captureSource = try container.decodeIfPresent(CaptureSource.self, forKey: .captureSource)
        priceTracker = try container.decodeIfPresent(PriceTracker.self, forKey: .priceTracker)
    }
}
