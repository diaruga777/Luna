//
//  TranscriptionRequest.swift
//  LunaModels
//

import Foundation

/// A recording the app must download and transcribe into a reader article
/// (`claudedocs/plans/transcription-plugins.md` §2.3).
///
/// The pipeline carries it inside `Outcome.transcription`, the store persists it
/// as JSON in the `transcriptions` table, and the runner reads it back. It holds
/// everything the runner needs, so a job survives the process that queued it.
public struct TranscriptionRequest: Codable, Equatable, Sendable {

    public enum MediaKind: String, Codable, Sendable {
        case audio
        case video
    }

    /// The file to fetch.
    public let mediaURL: URL
    public let mediaKind: MediaKind
    /// A separate audio leg for a video. When present, only this leg is fetched.
    public let audioURL: URL?
    /// Sent on the download request. Already filtered to the allowlist by the
    /// Model decoder.
    public let requestHeaders: [String: String]
    /// After this date the URLs are stale and the runner re-resolves before
    /// fetching.
    public let expiresAt: Date?
    /// BCP-47, as the plugin wrote it. Picks the speech model's locale.
    public let language: String?
    public let title: String
    public let author: String?
    public let pluginID: String
    /// The plugin's html body, already converted. Its blocks precede the
    /// transcript in the finished article.
    public let leadContent: ArticleContent?

    public init(
        mediaURL: URL, mediaKind: MediaKind, audioURL: URL? = nil,
        requestHeaders: [String: String] = [:], expiresAt: Date? = nil,
        language: String? = nil, title: String, author: String? = nil,
        pluginID: String, leadContent: ArticleContent? = nil
    ) {
        self.mediaURL = mediaURL
        self.mediaKind = mediaKind
        self.audioURL = audioURL
        self.requestHeaders = requestHeaders
        self.expiresAt = expiresAt
        self.language = language
        self.title = title
        self.author = author
        self.pluginID = pluginID
        self.leadContent = leadContent
    }

    /// The URL the runner fetches: the audio leg when there is one.
    public var fetchURL: URL { audioURL ?? mediaURL }

    /// Whether the URLs are past their declared expiry at `now`.
    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}
