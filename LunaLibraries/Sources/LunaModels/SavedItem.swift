//
//  SavedItem.swift
//  Luna
//

import Foundation

/// One saved weblink in the saves list.
///
/// `Equatable` (synthesized — every stored field is a value type, and the enum
/// fields below get automatic Equatable as enums with no associated values) lets
/// `SavesStore` detect a mutation that changed nothing and skip both the
/// row write and the `.savesChanged` notification.
public struct SavedItem: Identifiable, Equatable {
    /// Lifecycle of the item's downloaded content.
    public enum State: String, Codable {
        /// A plain saved URL, without extracted content or pending extraction.
        case link
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

    /// Ereader delivery status. Absent means never requested.
    public enum SendState: String, Codable {
        /// Send requested but not yet delivered (e.g. article still ingesting,
        /// the app died mid-send, or a soft failure is waiting for backoff).
        case queued
        /// Delivered to the SMTP server.
        case sent
        /// Terminal delivery failure. A hard failure, or enough soft failures.
        case failed
    }

    /// Lifecycle of the exact remote file a destination delivered, for a
    /// destination that tracks one (Xteink). Absent (the dictionary key is
    /// missing) means nothing has been delivered yet, or the destination
    /// doesn't track remote files.
    public enum RemoteDeleteStatus: String, Codable {
        /// Delivered and not read since. An in-app read schedules its removal
        /// unless the send was immune (queued while already read).
        case delivered
        /// The reader itself reported this article finished — it already
        /// files the book away on its own, so Luna must never also queue a
        /// remote delete for it.
        case readOnDevice
        /// The user finished it in Luna; the next non-read-report rendezvous
        /// should send `delete` for the stored remote name.
        case deletePending
        /// The device confirmed removal (or reported the file already gone).
        case deleted
    }

    public let id: UUID
    /// The user-supplied URL before a plugin/native rewrite; nil if never rewritten.
    public var originalURLString: String?
    public var urlString: String
    public var title: String?
    public var dateAdded: Date
    /// When non-nil, the item is kept in the archive tray instead of the main
    /// surface. The original save date remains unchanged for the tray footer.
    public var archivedAt: Date?
    /// Set when a reader reaches its end. The item stays on the active surface
    /// for the rest of the foreground session; the Reader app promotes this
    /// timestamp to `archivedAt` when it next backgrounds (or on the next cold
    /// launch if the process was terminated first).
    public var pendingArchiveAt: Date?
    /// When the user last "bumped" this item — re-sorts it to the top of the reading
    /// list and, where a view sorts by recency (e.g. the card-carousel root), takes
    /// priority over the save date.
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
    /// Scroll reader resume position (content offset). Part of the shared scroll/RSVP
    /// reading position: the exact pixels for `lastWordIndex`, kept ONLY while it still
    /// corresponds to it. The RSVP reader moves the shared position in word space with
    /// no pixels, so it clears this to nil — a nil offset means "resume from
    /// `lastWordIndex` by word" (see `ScrollReaderViewController`).
    public var lastScrollOffset: Double?
    /// Original/archive reader resume position (web-view content offset), kept fully
    /// DISJOINT from the shared scroll/RSVP position above — the archive is a separate
    /// snapshot and its scroll place must not move (or be moved by) the reader text.
    public var lastOriginalScrollOffset: Double?
    /// Read-aloud resume position (word index); non-nil once audio has played.
    public var lastSpokenWordIndex: Int?
    /// Total words in the extracted article (for reading-time estimates).
    public var wordCount: Int?
    /// 0…1 how far the user has gotten (scroll depth or RSVP position).
    public var readingProgress: Double?
    /// Display name of whoever sent an email-captured save — a newsletter's
    /// publisher, or the friend who shared the link. It is the ONLY meaning this
    /// field carries: it feeds the sender initials badge (`ArticleSourceBadge`)
    /// and the reader card's sender label (`ArticleCardPresenter
    /// .resolvedSenderName`), both of which read it only when
    /// `effectiveCaptureSource == .email`. Nothing else writes it.
    public var senderName: String?
    /// Normalized sender address for an incoming-email save. The UI resolves
    /// this through the contact store so later renames appear immediately.
    public var incomingSenderEmail: String?
    /// Downloaded video thumbnail (inside the Articles directory).
    public var thumbnailFileName: String?
    /// Username of the friend who shared this item to us, when it arrived via
    /// a social message (display only).
    public var sharedByUsername: String?
    /// File extension (e.g. "pdf", "txt", "md") when this item is an imported
    /// document with no web URL. The raw file lives at
    /// `Articles/<id>-source.<documentType>`.
    public var documentType: String?
    /// Per-destination send status, keyed by destination id. Absent means never requested.
    public var sendStates: [String: SendState]
    /// When the article was last delivered to each destination (the once-per-day
    /// resend guard), keyed by destination id.
    public var datesSent: [String: Date]
    /// Soft-failure count for each destination's current queued send.
    public var sendFailureCounts: [String: Int]
    /// Earliest retry time for each destination's queued send.
    public var sendNextAttemptDates: [String: Date]
    /// Last delivery error detail for each destination, used for diagnostics.
    public var sendLastErrors: [String: String]
    /// Whether this item's `readState` was already `.read` at the moment a
    /// destination's send was queued. A deliberate resend of an already-read
    /// article is exempt from both dequeue-on-read and delete-on-read for
    /// that destination — the user asked for it on purpose.
    public var sendQueuedWhileRead: [String: Bool]
    /// The exact basename delivered to each destination, after that
    /// destination's own filename sanitization — the identity a later remote
    /// delete targets.
    public var sendRemoteNames: [String: String]
    /// Lifecycle of the delivered remote file at each destination.
    public var sendRemoteStatuses: [String: RemoteDeleteStatus]
    /// When the user last pressed save for this URL while it was already in the
    /// list (the double-save-to-send detection window).
    public var lastSaveAttemptDate: Date?

    /// The content platform this item belongs to (nil = a plain article/document).
    public var platform: ContentPlatform?
    /// Platform item id (tweet id, post shortcode, etc.).
    public var platformItemID: String?
    /// Where this item was captured from — drives per-source auto-send. Absent
    /// on legacy items (treated as `.manual`).
    public var captureSource: CaptureSource?
    /// The plugin that produced this save, when one did. It routes refresh and
    /// re-resolution back to the same plugin, names the owner in Settings, and
    /// lets the deck say so when that plugin is off or deleted. Nil for every
    /// Swift-ingested save.
    public var pluginID: String?

    /// When this save is a price tracker (a product page with a price), this
    /// payload carries the watched store URLs, prices, and alert config. Absent
    /// for ordinary articles/media. Its presence is what makes the item render in
    /// the price-tracking section instead of the reader.
    public var priceTracker: PriceTracker?

    public var url: URL? { URL(string: urlString) }

    /// Whether this save is a price tracker rather than an article/media item.
    public var isPriceTracker: Bool { priceTracker != nil }

    public var isArchived: Bool { archivedAt != nil }

    /// Capture source for routing/auto-send, defaulting legacy items to `.manual`.
    public var effectiveCaptureSource: CaptureSource { captureSource ?? .manual }

    public var contentPlatform: ContentPlatform? { platform }

    /// A recognized platform item (vs. a plain article/document).
    public var isPlatformItem: Bool { contentPlatform != nil }

    /// Which of the three kinds this save is, read off its own shape — the way
    /// each card deck decides. The send coordinator asks it to match a save
    /// against a destination's declared kinds, and the export tier asks it to
    /// tell an export hook what it is handing over.
    public var exportKind: PluginModelKind {
        if priceTracker != nil { return .product }
        if isPlatformItem { return .media }
        return .article
    }

    /// An imported document (PDF/text/etc.) rather than a web link or video.
    public var isDocument: Bool { documentType != nil }

    /// `documentType` reduced to a safe file extension — lowercased alphanumerics,
    /// capped — so a crafted value (the field is read from the shared App-Group
    /// database any process can write) can't smuggle path separators into a file path.
    public var sanitizedDocumentType: String? {
        guard let documentType else { return nil }
        let cleaned = documentType.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? nil : String(cleaned.prefix(8))
    }

    /// Whether `urlString` is a real web page URL (http/https) rather than one of
    /// the synthetic `lunamail://` / `lunadoc://` schemes used for imports.
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
    /// `.webarchive` (or a styled offline snapshot of its saved article content)
    /// for web pages, and the imported source file for PDFs/other documents. The sole exception is an
    /// EMAIL-text import (`lunamail://`, `captureSource == .email`), which has no
    /// original artifact at all. This is a *capability* of the save's source, not a
    /// statement about whether the archive file has finished downloading — so a web
    /// page never loses the mode just because its `.webarchive` capture is absent.
    public var canHaveOriginalArchive: Bool {
        guard effectiveCaptureSource != .email else { return false }
        return isShareable || isDocument
    }

    /// Send status for one destination.
    public func sendState(for destinationID: String) -> SendState? { sendStates[destinationID] }
    /// Last delivery time for one destination.
    public func dateSent(for destinationID: String) -> Date? { datesSent[destinationID] }
    /// Whether this item was already `.read` when its current/last send to
    /// this destination was queued. False when never recorded.
    public func queuedWhileRead(for destinationID: String) -> Bool { sendQueuedWhileRead[destinationID] ?? false }
    /// The exact remote basename delivered to this destination, if any.
    public func remoteName(for destinationID: String) -> String? { sendRemoteNames[destinationID] }
    /// Lifecycle of the delivered remote file at this destination, if any.
    public func remoteDeleteStatus(for destinationID: String) -> RemoteDeleteStatus? { sendRemoteStatuses[destinationID] }

    public init(urlString: String, id: UUID = UUID()) {
        self.id = id
        self.urlString = urlString
        self.title = nil
        self.dateAdded = Date()
        self.archivedAt = nil
        self.pendingArchiveAt = nil
        self.bumpDate = nil
        self.state = .pending
        self.contentFileName = nil
        self.originalArchiveFileName = nil
        self.lastWordIndex = nil
        self.readState = .unopened
        self.lastReaderMode = nil
        self.lastScrollOffset = nil
        self.lastOriginalScrollOffset = nil
        self.lastSpokenWordIndex = nil
        self.wordCount = nil
        self.readingProgress = nil
        self.senderName = nil
        self.incomingSenderEmail = nil
        self.thumbnailFileName = nil
        self.sharedByUsername = nil
        self.documentType = nil
        self.sendStates = [:]
        self.datesSent = [:]
        self.sendFailureCounts = [:]
        self.sendNextAttemptDates = [:]
        self.sendLastErrors = [:]
        self.sendQueuedWhileRead = [:]
        self.sendRemoteNames = [:]
        self.sendRemoteStatuses = [:]
        self.lastSaveAttemptDate = nil
        self.platform = nil
        self.platformItemID = nil
        self.captureSource = nil
        self.pluginID = nil
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
        senderName: String? = nil,
        incomingSenderEmail: String? = nil,
        captureSource: CaptureSource? = nil,
        priceTracker: PriceTracker? = nil
    ) {
        self.id = SavedItem.deterministicUUID(from: seed)
        self.urlString = urlString
        self.title = title
        self.dateAdded = dateAdded
        self.archivedAt = nil
        self.pendingArchiveAt = nil
        self.bumpDate = bumpDate
        self.state = state
        self.contentFileName = nil
        self.originalArchiveFileName = nil
        self.lastWordIndex = nil
        self.readState = readState
        self.lastReaderMode = lastReaderMode
        self.lastScrollOffset = nil
        self.lastOriginalScrollOffset = nil
        self.lastSpokenWordIndex = nil
        self.wordCount = wordCount
        self.readingProgress = readingProgress
        self.senderName = senderName
        self.incomingSenderEmail = incomingSenderEmail
        self.thumbnailFileName = nil
        self.sharedByUsername = sharedByUsername
        self.documentType = documentType
        self.sendStates = [:]
        self.datesSent = [:]
        self.sendFailureCounts = [:]
        self.sendNextAttemptDates = [:]
        self.sendLastErrors = [:]
        self.sendQueuedWhileRead = [:]
        self.sendRemoteNames = [:]
        self.sendRemoteStatuses = [:]
        self.lastSaveAttemptDate = nil
        self.platform = platform
        self.platformItemID = platformItemID
        self.captureSource = captureSource
        self.pluginID = nil
        self.priceTracker = priceTracker
    }

    #endif

    /// A stable UUID derived from a seed string, so the same input maps to the same
    /// id across runs — used for reproducible test fixtures and for transient items
    /// whose identity must stay stable across re-creations (e.g. unsaved rabbit-hole
    /// pages, re-embedded on every mode/audio toggle).
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

}
