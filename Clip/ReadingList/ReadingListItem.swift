//
//  ReadingListItem.swift
//  Clip
//

import Foundation

/// One saved weblink in the reading list.
struct ReadingListItem: Codable, Identifiable {
    /// Lifecycle of the item's downloaded content.
    enum State: String, Codable {
        /// Saved but content not yet downloaded/extracted.
        case pending
        /// Content downloaded and extracted; ready to read.
        case ready
        /// Download or extraction failed; retried on next launch / pull-to-refresh.
        case failed
    }

    /// How far the user has gotten with the article.
    enum ReadState: String, Codable {
        /// Never opened — bright in the list.
        case unopened
        /// Opened at least once — dimmed in the list.
        case opened
        /// Finished (scrolled to the bottom, or RSVP played to the end).
        case read
    }

    /// Which reader the user last used for this article.
    enum ReaderMode: String, Codable {
        case scroll
        case rsvp
    }

    /// Send-to-Kindle delivery status. Absent means never requested.
    enum SendState: String, Codable {
        /// Send requested but not yet delivered (e.g. article still ingesting,
        /// or the app died mid-send). Retried on pull-to-refresh.
        case queued
        /// Delivered to the SMTP server.
        case sent
        /// Delivery failed. Retried on pull-to-refresh.
        case failed
    }

    let id: UUID
    var urlString: String
    var title: String?
    var dateAdded: Date
    var state: State
    /// File name (inside the Articles directory) of the extracted `ArticleContent` JSON.
    var contentFileName: String?
    /// RSVP resume position (word index).
    var lastWordIndex: Int?
    var readState: ReadState
    var lastReaderMode: ReaderMode?
    /// Scroll reader resume position (content offset).
    var lastScrollOffset: Double?
    /// Read-aloud resume position (word index); non-nil once audio has played.
    var lastSpokenWordIndex: Int?
    /// Eye-tracking estimate of the last word read (word index); nil when the
    /// feature is disabled or unavailable.
    var eyeTrackedWordIndex: Int?
    /// Total words in the extracted article (for reading-time estimates).
    var wordCount: Int?
    /// 0…1 how far the user has gotten (scroll depth or RSVP position).
    var readingProgress: Double?
    /// YouTube video ID when this item is a video link rather than an article.
    var youtubeVideoID: String?
    /// YouTube channel name (from oEmbed), shown in the list subtitle.
    var channelName: String?
    /// Downloaded video thumbnail (inside the Articles directory).
    var thumbnailFileName: String?
    /// Username of the friend who shared this item to us, when it arrived via
    /// a social message (display only).
    var sharedByUsername: String?
    /// File extension (e.g. "pdf", "txt", "md") when this item is an imported
    /// document with no web URL. The raw file lives at
    /// `Articles/<id>-source.<documentType>`.
    var documentType: String?
    /// Send-to-Kindle status; nil until a send is first requested.
    var sendState: SendState?
    /// When the article was last delivered to Kindle (for the once-per-day guard).
    var dateSent: Date?
    /// When the user last pressed save for this URL while it was already in the
    /// list (the double-save-to-send detection window).
    var lastSaveAttemptDate: Date?

    var url: URL? { URL(string: urlString) }

    var isYouTubeVideo: Bool { youtubeVideoID != nil }

    /// An imported document (PDF/text/etc.) rather than a web link or video.
    var isDocument: Bool { documentType != nil }

    /// Documents have no real URL to send to other users.
    var canShareToFriends: Bool { !isDocument }

    /// The `clipdoc://` identity used for imported documents (no web URL).
    static func documentURLString(id: UUID) -> String { "clipdoc://\(id.uuidString)" }

    init(urlString: String) {
        self.id = UUID()
        self.urlString = urlString
        self.title = nil
        self.dateAdded = Date()
        self.state = .pending
        self.contentFileName = nil
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
        self.sendState = nil
        self.dateSent = nil
        self.lastSaveAttemptDate = nil
    }

    // Manual decoding so items saved before readState existed still decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        urlString = try container.decode(String.self, forKey: .urlString)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        state = try container.decode(State.self, forKey: .state)
        contentFileName = try container.decodeIfPresent(String.self, forKey: .contentFileName)
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
        sendState = try container.decodeIfPresent(SendState.self, forKey: .sendState)
        dateSent = try container.decodeIfPresent(Date.self, forKey: .dateSent)
        lastSaveAttemptDate = try container.decodeIfPresent(Date.self, forKey: .lastSaveAttemptDate)
    }
}
