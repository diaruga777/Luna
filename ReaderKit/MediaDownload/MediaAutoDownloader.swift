//
//  MediaAutoDownloader.swift
//  Clip
//

import Foundation

/// Saves a just-ingested social post's media to Photos when the user has enabled
/// auto-download for its platform. Hooked into the ingest funnel
/// (`ReadingListIngestor.ingestPlatformItem`) so EVERY save method flows through it
/// — including share-sheet saves, which the main app re-ingests from the pending
/// queue, so the download runs in the app where Photos access was granted.
enum MediaAutoDownloader {
    static func runIfEnabled(
        forURLString urlString: String, service: MediaDownloading = MediaDownloadService()
    ) {
        guard let platform = PlatformClassifier.classify(urlString)?.platform,
              MediaDownloadablePlatform.supported.contains(platform),
              AutoDownloadSettings.isEnabled(for: platform),
              let url = URL(string: urlString)
        else { return }
        // The service's add-only auth request is a no-op once granted via the toggle.
        Task { _ = try? await service.downloadFirstMediaToPhotos(from: url, onProgress: { _ in }) }
    }
}
