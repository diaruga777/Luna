import Foundation
import CryptoKit

public enum PodcastIdentity {
    public static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func show(_ url: URL) -> String { hash(url.absoluteString) }
    public static func episode(showID: String, guid: String) -> String { hash(showID + "\n" + guid) }
    public static func webURL(_ value: String?, relativeTo base: URL? = nil) -> URL? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
}

public struct PodcastShow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var feedURL: URL
    public var title: String
    public var author: String
    public var summary: String = ""
    public var artworkURL: URL?
    public var websiteURL: URL?
    public var directoryID: String?
    public var categories: [String] = []
    public var explicit = false
    public var serial = false
    public var followed = false
    public var settings = PodcastShowSettings()
    public var etag: String?
    public var lastModified: String?
    public var lastRefresh: Date?
    public var refreshError: String?
    public var updatedAt = Date()
    public init(feedURL: URL, title: String, author: String = "", id: String? = nil) {
        self.feedURL = feedURL; self.title = title; self.author = author
        self.id = id ?? PodcastIdentity.show(feedURL)
    }
}
public struct PodcastShowSettings: Codable, Equatable, Sendable {
    public var newestFirst = true
    public var hidePlayed = false
    /// 0 = off, -1 = all unplayed, positive = latest N unplayed.
    public var automaticDownloadLimit = 1
    public var notifications = false
    public var playbackRate: Float = 1
    // Retained for decoding older libraries; queues now contain explicit selections only.
    public var continuousPlayback = true
    public init() {}
}
public struct PodcastChapter: Codable, Equatable, Sendable {
    public var start: Double
    public var title: String
    public var url: URL?
    public var imageURL: URL?
    public init(start: Double, title: String, url: URL? = nil, imageURL: URL? = nil) {
        self.start = start; self.title = title; self.url = url; self.imageURL = imageURL
    }
}
public struct PodcastTranscriptReference: Codable, Equatable, Sendable {
    public var url: URL
    public var type: String
    public var language: String?
    public init(url: URL, type: String, language: String? = nil) { self.url = url; self.type = type; self.language = language }
}
public struct PodcastEpisode: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var showID: String
    public var guid: String
    public var title: String
    public var summary: String = ""
    public var publishedAt: Date
    public var mediaURL: URL
    public var mediaType: String = "audio/mpeg"
    public var byteCount: Int64 = 0
    public var duration: Double = 0
    public var artworkURL: URL?
    public var websiteURL: URL?
    public var season: Int?
    public var number: Int?
    public var episodeType: String = "full"
    public var explicit = false
    public var chapters: [PodcastChapter] = []
    public var chaptersURL: URL?
    public var transcripts: [PodcastTranscriptReference] = []
    public var isVideo: Bool { mediaType.hasPrefix("video/") || ["mp4", "mov", "m4v"].contains(mediaURL.pathExtension.lowercased()) }
    public init(showID: String, guid: String, title: String, publishedAt: Date, mediaURL: URL) {
        self.showID = showID; self.guid = guid; self.title = title; self.publishedAt = publishedAt; self.mediaURL = mediaURL
        self.id = PodcastIdentity.episode(showID: showID, guid: guid)
    }
}
public struct PodcastEpisodeState: Codable, Equatable, Sendable {
    public var position: Double = 0
    public var listened = false
    public var saved = false
    public var lastPlayedAt: Date?
    public var completedAt: Date?
    public var suppressAutomaticDownload = false
    public var updatedAt = Date()
    public init() {}
}
public struct PodcastCursor: Codable, Equatable, Sendable {
    public var updatedAt = Date()
    public var episodeID: String
    public var publishedAt: Date
    public init(episode: PodcastEpisode) { episodeID = episode.id; publishedAt = episode.publishedAt }
}
public struct PodcastStation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var showIDs: [String] = []
    public var allShows = false
    public var unplayedOnly = true
    public var newestFirst = false
    public var episodesPerShow = 0
    public var media: String = "all"
    public var updatedAt = Date()
    public init(name: String) { self.name = name }
}
public struct PodcastSettings: Codable, Equatable, Sendable {
    public var skipBack: Double = 15
    public var skipForward: Double = 30
    public var cellularDownloads = false
    public var cellularStreaming = true
    public var removePlayedDownloads = true
    public var playedRetentionHours: Double = 24
    /// Nil preserves compatibility with libraries written before the byte cap.
    public var downloadByteLimit: Int64?
    public var maximumDownloadBytes: Int64 { max(0, downloadByteLimit ?? 2_000_000_000) }
    public var downloadSavedEpisodes = true
    public var hidePlayed = false
    // Retained for decoding older libraries; queues now contain explicit selections only.
    public var continuousPlayback = true
    public var syncEnabled = false
    public var countryCode = Locale.current.region?.identifier.lowercased() ?? "us"
    public var favoriteCategories: [String] = []
    public init() {}
}
public struct PodcastLibraryState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var shows: [String: PodcastShow] = [:]
    public var episodes: [String: PodcastEpisode] = [:]
    public var progress: [String: PodcastEpisodeState] = [:]
    public var cursors: [String: PodcastCursor] = [:]
    public var stations: [PodcastStation] = []
    public var deletedStations: [String: Date] = [:]
    public var settings = PodcastSettings()
    public var currentEpisodeID: String?
    public var lastPlayedEpisodeID: String?
    public var queue: [String] = []
    public var continuation: [String] = []
    public var naturallyExhaustedQueue = false
    public var updatedAt = Date()
    public init() {}
}
public struct PodcastError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
public extension Notification.Name {
    static let lunaPodcastsChanged = Notification.Name("lunaPodcastsChanged")
    static let lunaPodcastPlaybackChanged = Notification.Name("lunaPodcastPlaybackChanged")
    static let lunaMediaSurfaceChanged = Notification.Name("lunaMediaSurfaceChanged")
}
