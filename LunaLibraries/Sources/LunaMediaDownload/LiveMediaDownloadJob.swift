//
//  LiveMediaDownloadJob.swift
//  Luna
//

import LunaModels
import Foundation

struct LiveMediaDownloadJob: Codable, Equatable {
    enum Phase: String, Codable {
        case resolving
        case downloading
        case waiting
        case suspended
        case saving
        case finished
        case failed
    }

    enum ErrorKind: String, Codable {
        case download
        case photosPermission
        /// Resolution found no downloadable assets — the case URL rescue targets.
        case noMedia
    }

    var id: String
    var sourceURLString: String
    var assetURLString: String?
    /// Nil for a job that hasn't resolved an asset yet (or whose legacy on-disk
    /// value didn't parse — the old "unknown" sentinel and anything else
    /// unrecognized). Never a case that CLAIMS a kind it doesn't have: the old
    /// `String` let three producers write three incompatible encodings for the
    /// same `.gif` case ("gif" from `Kind.rawValue`, "animatedImage" from the
    /// old `liveActivityKind`), so a job written by one and read by the other's
    /// assumption silently became `.image`.
    var mediaKind: MediaAsset.Kind?
    var title: String
    /// Best-effort creator/author name (from the reading-list item's fetched
    /// platform metadata), carried through to `SavedMediaStore` on completion.
    var creator: String?
    var resolveKind: String?
    var phase: Phase
    var progress: Double
    var thumbnailFileName: String?
    var fileExtension: String?
    /// Size/transfer state survives process death. Resume data is stored as a
    /// sibling file instead of bloating jobs.json with base64 bytes.
    var expectedByteCount: Int64?
    var receivedByteCount: Int64?
    var resumeDataFileName: String?
    /// Optional source-requested range (notably YouTube timestamp/clip links).
    var rangeStartSeconds: Double?
    var rangeEndSeconds: Double?
    /// The underlying YouTube video id after a `/clip/` URL has been expanded.
    /// Persisting it lets a later resolver stage survive a process relaunch.
    var resolvedVideoID: String?
    /// Guest-session identity extracted from YouTube's watch page and forwarded
    /// to the Android VR player request. Optional for jobs from older builds and
    /// for every non-YouTube platform.
    var youtubeVisitorData: String?
    var errorMessage: String?
    var errorKind: ErrorKind?
    var resolveAttempts: Int
    var mediaAttempts: Int
    var suspendDeadline: Date?
    /// Nil only for jobs written by older builds. Those retain the former
    /// Bundle.main inference while every new job carries explicit ownership.
    var ownership: LiveMediaDownloadOwnership?

    var isTerminal: Bool { phase == .finished || phase == .failed }

    var isDownloaderOwned: Bool {
        ownership == .downloader
            || (ownership == nil && MediaAutoDownloader.isRunningInDownloader)
    }

    init(
        id: String, sourceURLString: String, assetURLString: String? = nil,
        mediaKind: MediaAsset.Kind? = nil, title: String, creator: String? = nil,
        resolveKind: String? = nil,
        phase: Phase, progress: Double, thumbnailFileName: String? = nil,
        fileExtension: String? = nil,
        expectedByteCount: Int64? = nil, receivedByteCount: Int64? = nil,
        resumeDataFileName: String? = nil,
        rangeStartSeconds: Double? = nil, rangeEndSeconds: Double? = nil,
        resolvedVideoID: String? = nil, youtubeVisitorData: String? = nil,
        errorMessage: String? = nil, errorKind: ErrorKind? = nil,
        resolveAttempts: Int, mediaAttempts: Int,
        suspendDeadline: Date? = nil, ownership: LiveMediaDownloadOwnership? = nil
    ) {
        self.id = id
        self.sourceURLString = sourceURLString
        self.assetURLString = assetURLString
        self.mediaKind = mediaKind
        self.title = title
        self.creator = creator
        self.resolveKind = resolveKind
        self.phase = phase
        self.progress = progress
        self.thumbnailFileName = thumbnailFileName
        self.fileExtension = fileExtension
        self.expectedByteCount = expectedByteCount
        self.receivedByteCount = receivedByteCount
        self.resumeDataFileName = resumeDataFileName
        self.rangeStartSeconds = rangeStartSeconds
        self.rangeEndSeconds = rangeEndSeconds
        self.resolvedVideoID = resolvedVideoID
        self.youtubeVisitorData = youtubeVisitorData
        self.errorMessage = errorMessage
        self.errorKind = errorKind
        self.resolveAttempts = resolveAttempts
        self.mediaAttempts = mediaAttempts
        self.suspendDeadline = suspendDeadline
        self.ownership = ownership
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceURLString, assetURLString, mediaKind, title, creator, resolveKind
        case phase, progress, thumbnailFileName, fileExtension
        case expectedByteCount, receivedByteCount, resumeDataFileName
        case rangeStartSeconds, rangeEndSeconds
        case resolvedVideoID, youtubeVisitorData
        case errorMessage, errorKind, resolveAttempts, mediaAttempts, suspendDeadline, ownership
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceURLString = try c.decode(String.self, forKey: .sourceURLString)
        assetURLString = try c.decodeIfPresent(String.self, forKey: .assetURLString)
        mediaKind = Self.decodeLegacyMediaKind(
            try c.decodeIfPresent(String.self, forKey: .mediaKind))
        title = try c.decode(String.self, forKey: .title)
        creator = try c.decodeIfPresent(String.self, forKey: .creator)
        resolveKind = try c.decodeIfPresent(String.self, forKey: .resolveKind)
        phase = try c.decode(Phase.self, forKey: .phase)
        progress = try c.decode(Double.self, forKey: .progress)
        thumbnailFileName = try c.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension)
        expectedByteCount = try c.decodeIfPresent(Int64.self, forKey: .expectedByteCount)
        receivedByteCount = try c.decodeIfPresent(Int64.self, forKey: .receivedByteCount)
        resumeDataFileName = try c.decodeIfPresent(String.self, forKey: .resumeDataFileName)
        rangeStartSeconds = try c.decodeIfPresent(Double.self, forKey: .rangeStartSeconds)
        rangeEndSeconds = try c.decodeIfPresent(Double.self, forKey: .rangeEndSeconds)
        resolvedVideoID = try c.decodeIfPresent(String.self, forKey: .resolvedVideoID)
        youtubeVisitorData = try c.decodeIfPresent(String.self, forKey: .youtubeVisitorData)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        errorKind = try c.decodeIfPresent(ErrorKind.self, forKey: .errorKind)
        resolveAttempts = try c.decode(Int.self, forKey: .resolveAttempts)
        mediaAttempts = try c.decode(Int.self, forKey: .mediaAttempts)
        suspendDeadline = try c.decodeIfPresent(Date.self, forKey: .suspendDeadline)
        ownership = try c.decodeIfPresent(LiveMediaDownloadOwnership.self, forKey: .ownership)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceURLString, forKey: .sourceURLString)
        try c.encodeIfPresent(assetURLString, forKey: .assetURLString)
        try c.encodeIfPresent(mediaKind, forKey: .mediaKind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(creator, forKey: .creator)
        try c.encodeIfPresent(resolveKind, forKey: .resolveKind)
        try c.encode(phase, forKey: .phase)
        try c.encode(progress, forKey: .progress)
        try c.encodeIfPresent(thumbnailFileName, forKey: .thumbnailFileName)
        try c.encodeIfPresent(fileExtension, forKey: .fileExtension)
        try c.encodeIfPresent(expectedByteCount, forKey: .expectedByteCount)
        try c.encodeIfPresent(receivedByteCount, forKey: .receivedByteCount)
        try c.encodeIfPresent(resumeDataFileName, forKey: .resumeDataFileName)
        try c.encodeIfPresent(rangeStartSeconds, forKey: .rangeStartSeconds)
        try c.encodeIfPresent(rangeEndSeconds, forKey: .rangeEndSeconds)
        try c.encodeIfPresent(resolvedVideoID, forKey: .resolvedVideoID)
        try c.encodeIfPresent(youtubeVisitorData, forKey: .youtubeVisitorData)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encodeIfPresent(errorKind, forKey: .errorKind)
        try c.encode(resolveAttempts, forKey: .resolveAttempts)
        try c.encode(mediaAttempts, forKey: .mediaAttempts)
        try c.encodeIfPresent(suspendDeadline, forKey: .suspendDeadline)
        try c.encodeIfPresent(ownership, forKey: .ownership)
    }

    /// Legacy on-disk `mediaKind` strings, from before the field was typed:
    /// both `"animatedImage"` (the old `liveActivityKind` encoding) and
    /// `"gif"` (`MediaAsset.Kind.rawValue`) meant `.gif`; `"unknown"` and
    /// anything else unrecognized decode to nil rather than a guessed kind.
    private static func decodeLegacyMediaKind(_ raw: String?) -> MediaAsset.Kind? {
        guard let raw else { return nil }
        if let kind = MediaAsset.Kind(rawValue: raw) { return kind }
        return raw == "animatedImage" ? .gif : nil
    }

    mutating func fail(message: String, kind: ErrorKind = .download) {
        phase = .failed
        errorMessage = message
        errorKind = kind
        suspendDeadline = nil
    }

    /// The human-readable status line shown by both the Live Activity and the
    /// Downloader footer status view — kept as one source of truth so the two
    /// surfaces never drift.
    var statusMessage: String {
        switch phase {
        case .resolving: return L10n.string("Downloader_liveActivity_status_resolving")
        case .downloading: return L10n.string("Common_downloading")
        case .waiting: return L10n.string("Downloader_liveActivity_status_waiting")
        case .suspended: return L10n.string("Downloader_liveActivity_status_suspended")
        case .saving:
            return isDownloaderOwned
                ? L10n.string("Downloader_liveActivity_status_savingToLuna")
                : L10n.string("Downloader_liveActivity_status_savingToPhotos")
        case .finished:
            return isDownloaderOwned
                ? L10n.string("Common_savedToLuna")
                : L10n.string("Downloader_liveActivity_status_savedToPhotos")
        case .failed: return errorMessage ?? L10n.string("Downloader_liveActivity_status_downloadFailed")
        }
    }

    var downloaderSnapshot: DownloaderJobSnapshot {
        let failureKind: DownloaderJobSnapshot.FailureKind?
        switch phase {
        case .failed: failureKind = errorKind == .noMedia ? .noMedia : .other
        default: failureKind = nil
        }
        return DownloaderJobSnapshot(
            sourceURLString: sourceURLString,
            title: title,
            phase: DownloaderJobPhase(rawValue: phase.rawValue) ?? .failed,
            progress: progress,
            message: statusMessage,
            thumbnailFileName: thumbnailFileName,
            failureKind: failureKind)
    }
}
