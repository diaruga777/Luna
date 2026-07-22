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
        forURLString urlString: String
    ) async -> DownloadedMedia? {
        guard shouldStartDownloaderIntentDownload(forURLString: urlString),
              let url = URL(string: urlString)
        else { return nil }

        if let existing = SavedMediaStore.shared.existingDownloadedItem(
            forURLString: urlString
        ) {
            return await exportFile(from: existing)
        }

        let started = await LiveMediaDownloadManager.shared.start(
            urlString: url.absoluteString,
            title: ReadingListStore.shared.item(forURLString: urlString)?.title,
            ownership: .downloader)
        guard started || LiveMediaDownloadManager.shared.currentDownloadSnapshot(
            forSourceURLString: urlString) != nil
        else {
            AutoDownloadSettings.unmarkDownloaded(urlString)
            return nil
        }
        guard let item = await LiveMediaDownloadManager.shared.waitForDownloaderResult(
            forSourceURLString: urlString)
        else { return nil }
        return await exportFile(from: item)
    }

    /// Materializes one saved item as a concrete, shareable file URL with a
    /// human-readable filename. Local items use a hard link when possible;
    /// Photos-backed items stream their original resource out of PhotoKit.
    public static func exportFile(from item: SavedMediaItem) async -> DownloadedMedia? {
        guard let kind = item.kind else { return nil }
        let fileName = IntentMediaExportNaming.fileName(
            title: item.title,
            sourceURLString: item.sourceURLString,
            kind: kind,
            sourceExtension: item.fileURL?.pathExtension)
        let exportURL = MediaDownloadStorage.newIntentExportURL(fileName: fileName)
        switch item.storageState {
        case .localFile:
            guard let sourceURL = item.fileURL,
                  FileManager.default.fileExists(atPath: sourceURL.path)
            else { return nil }
            do {
                // Keep the durable UUID-backed library file untouched while
                // handing Shortcuts a URL whose final path component is the
                // human-readable filename it will preserve when sharing.
                do {
                    try FileManager.default.linkItem(at: sourceURL, to: exportURL)
                } catch {
                    try FileManager.default.copyItem(at: sourceURL, to: exportURL)
                }
                return DownloadedMedia(fileURL: exportURL, kind: kind)
            } catch {
                MediaDownloadStorage.discardIntentExport(at: exportURL)
                return nil
            }
        case .photosReference(let identifier, _, _):
            do {
                try await PhotoLibrarySaver().writeResource(
                    localIdentifier: identifier, kind: kind, to: exportURL)
                return DownloadedMedia(fileURL: exportURL, kind: kind)
            } catch {
                MediaDownloadStorage.discardIntentExport(at: exportURL)
                return nil
            }
        case .undownloaded:
            return nil
        }
    }

    /// Produces the filename Shortcuts and share destinations see for media
    /// returned from an App Intent. The export URL uses this name as its last
    /// path component; it is not merely `IntentFile` presentation metadata.
    public enum IntentMediaExportNaming {
        public static func fileName(
            title: String?,
            sourceURLString: String,
            kind: MediaAsset.Kind,
            sourceExtension: String? = nil
        ) -> String {
            let titleStem = title.flatMap(sanitizedStem)
            let fallbackStem = PlatformRecognizer.recognize(sourceURLString)?.platform.rawValue
                ?? URL(string: sourceURLString).flatMap(hostStem)
                ?? "media"
            let stem = titleStem ?? sanitizedStem(fallbackStem) ?? "media"
            return "\(stem).\(fileExtension(kind: kind, sourceExtension: sourceExtension))"
        }

        private static func sanitizedStem(_ value: String) -> String? {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
            let scalars = value.unicodeScalars.map {
                allowed.contains($0) ? Character(String($0)) : " "
            }
            let collapsed = String(scalars)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
            guard !collapsed.isEmpty else { return nil }
            return String(collapsed.prefix(80))
                .trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        }

        private static func hostStem(_ url: URL) -> String? {
            guard let host = url.host?.lowercased() else { return nil }
            let labels = host.split(separator: ".").map(String.init)
            guard !labels.isEmpty else { return nil }
            if labels.count >= 2 {
                return labels[labels.count - 2]
            }
            return labels[0]
        }

        private static func fileExtension(
            kind: MediaAsset.Kind,
            sourceExtension: String?
        ) -> String {
            switch kind {
            case .video:
                return "mp4"
            case .gif:
                return "gif"
            case .image:
                let ext = sourceExtension?.lowercased() ?? ""
                return ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(ext)
                    ? ext
                    : "jpg"
            }
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
