//
//  MediaAutoDownloader.swift
//  Clip
//

import ClipURLClassification
import Foundation

/// Saves a just-ingested social post's media to Photos when the user has enabled
/// auto-download for its platform. Hooked into the ingest funnel
/// (`ReadingListIngestor.ingestPlatformItem`) so EVERY save method flows through it
/// — including share-sheet saves, which the main app re-ingests from the pending
/// queue, so the download runs in the app where Photos access was granted.
public enum MediaAutoDownloader {
    /// Whether a saved URL is a platform whose media should auto-download (enabled +
    /// supported). Used by the share extension to decide whether to stay alive.
    public static func isEnabled(forURLString urlString: String) -> Bool {
        guard let platform = PlatformRecognizer.recognize(urlString)?.platform else { return false }
        return MediaDownloadablePlatform.supported.contains(platform)
            && AutoDownloadSettings.isEnabled(for: platform)
    }

    /// Downloads the post's first media item to Photos if auto-download is enabled
    /// for its platform and it hasn't already been downloaded. AWAITS completion (so
    /// the app intent finishes the download before returning) and marks the URL so
    /// the main-app ingest fallback won't download it again. Returns true if it saved.
    @discardableResult
    public static func runIfEnabledAwaiting(
        forURLString urlString: String, service: MediaDownloading = MediaDownloadService()
    ) async -> Bool {
        guard isEnabled(forURLString: urlString),
              !AutoDownloadSettings.wasDownloaded(urlString),
              let url = URL(string: urlString)
        else { return false }
        do {
            _ = try await service.downloadFirstMediaToPhotos(from: url, onProgress: { _ in })
            AutoDownloadSettings.markDownloaded(urlString)
            return true
        } catch {
            return false
        }
    }
}
