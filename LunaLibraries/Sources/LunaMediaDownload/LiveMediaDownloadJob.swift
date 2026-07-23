//
//  LiveMediaDownloadJob.swift
//  Luna
//

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
    }

    var id: String
    var sourceURLString: String
    var assetURLString: String?
    var mediaKind: String
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

    var mediaAssetKind: MediaAsset.Kind {
        switch mediaKind {
        case "video": return .video
        case "audio": return .audio
        case "animatedImage": return .gif
        default: return .image
        }
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
        case .resolving: return "Preparing download"
        case .downloading: return "Downloading"
        case .waiting: return "Waiting to resume"
        case .suspended: return "Paused. Resume within 5 seconds."
        case .saving: return isDownloaderOwned ? "Saving to Luna" : "Saving to Photos"
        case .finished: return isDownloaderOwned ? "Saved to Luna" : "Saved to Photos"
        case .failed: return errorMessage ?? "Download failed"
        }
    }

    var downloaderSnapshot: DownloaderJobSnapshot {
        DownloaderJobSnapshot(
            sourceURLString: sourceURLString,
            title: title,
            phase: DownloaderJobPhase(rawValue: phase.rawValue) ?? .failed,
            progress: progress,
            message: statusMessage,
            thumbnailFileName: thumbnailFileName)
    }
}
