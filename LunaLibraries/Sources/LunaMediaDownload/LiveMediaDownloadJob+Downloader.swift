//
//  LiveMediaDownloadJob+Downloader.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels

/// The parts of a job that depend on which PROCESS is asking, or on the
/// Downloader's own snapshot type. The data and its persistence live in
/// LunaModels; these do not.
extension LiveMediaDownloadJob {
    var isDownloaderOwned: Bool {
        ownership == .downloader
            || (ownership == nil && MediaAutoDownloader.isRunningInDownloader)
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
            receivedByteCount: receivedByteCount,
            message: statusMessage,
            thumbnailFileName: thumbnailFileName,
            failureKind: failureKind)
    }
}
