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

    var url: URL? { URL(string: urlString) }

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
    }
}
