//
//  MediaAutoDownloader.swift
//  Luna
//

import LunaURLClassification
import LunaStorage
import Foundation

/// Saves a just-ingested social post's media. Luna Downloader always stores
/// supported media in its app-owned library; sibling apps keep the older
/// per-platform opt-in Photos behavior. Hooked into the ingest funnel
/// (`ReadingListIngestor.ingestPlatformItem`) so EVERY save method flows through it
/// — including share-sheet saves, which the main app re-ingests from the pending
/// queue.
public enum MediaAutoDownloader {
    /// Whether a saved URL is a platform whose media should auto-download (enabled +
    /// supported). Used by the share extension to decide whether to stay alive.
    public static func isEnabled(forURLString urlString: String) -> Bool {
        guard let platform = PlatformRecognizer.recognize(urlString)?.platform else { return false }
        return MediaDownloadablePlatform.supported.contains(platform)
            && (isRunningInDownloader || AutoDownloadSettings.isEnabled(for: platform))
    }

    /// Downloads the post's first media item if auto-download is enabled for its
    /// platform and it hasn't already been downloaded. Downloader persists to its
    /// app-owned media library; sibling apps use the legacy Photos destination.
    /// AWAITS completion (so the app intent finishes the download before returning)
    /// and marks the URL so the main-app ingest fallback won't download it again.
    @discardableResult
    public static func runIfEnabledAwaiting(
        forURLString urlString: String, service: MediaDownloading = MediaDownloadService()
    ) async -> Bool {
        ensureUndownloaded(urlString)
        guard isEnabled(forURLString: urlString),
              !AutoDownloadSettings.wasDownloaded(urlString),
              let url = URL(string: urlString)
        else { return false }
        do {
            if isRunningInDownloader {
                _ = try await service.downloadFirstMediaToAppStorage(
                    from: url, title: nil, onProgress: { _ in })
            } else {
                _ = try await service.downloadFirstMediaToPhotos(from: url, onProgress: { _ in })
            }
            AutoDownloadSettings.markDownloaded(urlString)
            return true
        } catch {
            return false
        }
    }

    /// Starts a system-owned background transfer + Live Activity and returns once
    /// the work has been handed off. This is the path for processes with short
    /// lifetimes (Shortcuts/App Intents and share/action extensions).
    @discardableResult
    public static func startLiveActivityIfEnabled(forURLString urlString: String) async -> Bool {
        ensureUndownloaded(urlString)
        guard isEnabled(forURLString: urlString) else { return false }
        return await LiveMediaDownloadManager.shared.start(urlString: urlString)
    }

    /// App Intents always hand downloadable media to the Downloader-owned background
    /// path when the Downloader has ever launched, independent of platform toggles.
    public static func shouldStartDownloaderIntentDownload(
        forURLString urlString: String,
        downloaderWasInstalled: Bool = LunaInstallationMarkers.downloaderWasInstalled
    ) -> Bool {
        guard downloaderWasInstalled,
              let platform = PlatformRecognizer.recognize(urlString)?.platform
        else { return false }
        return MediaDownloadablePlatform.supported.contains(platform)
    }

    public static func startDownloaderIntentDownload(forURLString urlString: String) async -> Bool {
        guard shouldStartDownloaderIntentDownload(forURLString: urlString) else { return false }
        return await LiveMediaDownloadManager.shared.start(
            urlString: urlString, ownership: .downloader)
    }

    /// Completes a Downloader-owned App Intent download before returning and
    /// exposes the resulting local bytes for a Shortcut result. Existing
    /// durable downloads are reused without another network fetch. A
    /// Photos-backed item is copied to a transient file because `IntentFile`
    /// needs an on-disk resource it can hand to Shortcuts.
    public static func downloadForDownloaderIntentAwaiting(
        forURLString urlString: String,
        service: MediaDownloading = MediaDownloadService()
    ) async -> DownloadedMedia? {
        guard shouldStartDownloaderIntentDownload(forURLString: urlString),
              let url = URL(string: urlString)
        else { return nil }

        if let existing = SavedMediaStore.shared.existingDownloadedItem(
            forURLString: urlString
        ) {
            return await intentMedia(from: existing)
        }

        do {
            let item = try await service.downloadFirstMediaToAppStorage(
                from: url,
                title: ReadingListStore.shared.item(forURLString: urlString)?.title,
                onProgress: { _ in })
            AutoDownloadSettings.markDownloaded(urlString)
            return await intentMedia(from: item)
        } catch {
            AutoDownloadSettings.unmarkDownloaded(urlString)
            return nil
        }
    }

    private static func intentMedia(from item: SavedMediaItem) async -> DownloadedMedia? {
        guard let kind = item.kind else { return nil }
        switch item.storageState {
        case .localFile:
            guard let fileURL = item.fileURL,
                  FileManager.default.fileExists(atPath: fileURL.path)
            else { return nil }
            return DownloadedMedia(fileURL: fileURL, kind: kind)
        case .photosReference(let identifier, _, _):
            let ext: String
            switch kind {
            case .image: ext = "jpg"
            case .gif: ext = "gif"
            case .video: ext = "mp4"
            }
            let fileURL = MediaDownloadStorage.newFileURL(extension: ext)
            do {
                try await PhotoLibrarySaver().writeResource(
                    localIdentifier: identifier, kind: kind, to: fileURL)
                return DownloadedMedia(fileURL: fileURL, kind: kind)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        case .undownloaded:
            return nil
        }
    }

    private static func ensureUndownloaded(_ urlString: String) {
        guard isRunningInDownloader,
              let item = ReadingListStore.shared.item(forURLString: urlString) else { return }
        try? SavedMediaStore.shared.ensureUndownloaded(
            id: item.id,
            sourceURLString: item.urlString,
            title: item.title,
            creator: item.channelName,
            dateSaved: item.dateAdded)
    }

    /// Whether the running process belongs to Luna Downloader (the app OR one of its
    /// extensions — bundle ids are all `…downloader[.share|.action2|.safari]`). Public
    /// so the share surface can route saves into the app-owned `SavedMediaStore`
    /// (the Downloader grid's data source) rather than Photos.
    public static var isRunningInDownloader: Bool {
        guard let identifier = Bundle.main.bundleIdentifier?.lowercased() else { return false }
        return identifier.contains(".downloader")
    }
}
