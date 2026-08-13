//
//  MediaAutoDownloader.swift
//  Luna
//

import LunaModels
import LunaURLClassification
import LunaStorage
import Foundation

/// Saves a just-ingested social post's media. Luna and Luna Downloader use the
/// same supported-platform policy and app-owned media library. Hooked into the ingest funnel
/// (`ReadingListIngestor.ingestPlatformItem`) so EVERY save method flows through it
/// — including share-sheet saves, which the main app re-ingests from the pending
/// queue.
public enum MediaAutoDownloader {
    /// Whether a saved URL is supported by a media-handling app. Used by the
    /// share extension to decide whether to stay alive.
    public static func isEnabled(forURLString urlString: String) -> Bool {
        guard isRunningInDownloader else { return false }
        if DirectMediaURL.kind(for: urlString) != nil { return true }
        guard let platform = PlatformRecognizer.recognize(urlString)?.platform else { return false }
        return MediaDownloadablePlatform.supported.contains(platform)
    }

    /// Downloads the post's first media item if it hasn't already been downloaded.
    /// Media-handling apps persist to their shared app-owned media library.
    /// AWAITS completion (so the app intent finishes the download before returning)
    /// and marks the URL so the main-app ingest fallback won't download it again.
    @discardableResult
    public static func runIfEnabledAwaiting(forURLString urlString: String) async -> Bool {
        ensureUndownloaded(urlString)
        guard isEnabled(forURLString: urlString),
              !AutoDownloadSettings.wasDownloaded(urlString),
              let url = URL(string: urlString)
        else { return false }
        do {
            _ = try await MediaDownloadService().downloadFirstMediaToAppStorage(
                from: url, title: nil, onProgress: { _ in })
            AutoDownloadSettings.markDownloaded(urlString)
            return true
        } catch {
            if case MediaDownloadError.noMedia = error {
                MediaSaveFailureRecording.recordNoMedia(
                    sourceURLString: urlString, detail: "the post exposed no playable asset")
            } else {
                SaveDiagnostics.record(
                    "media: auto-download failed — \(SaveDiagnostics.snippet("\(error)"))",
                    category: "media")
            }
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
        handlesMedia: Bool = MediaAutoDownloader.isRunningInDownloader
    ) -> Bool {
        // Media handoffs are media handling: only apps that handle media
        // (Downloader and the central Luna app) start one — never a sibling
        // app writing cross-app on Downloader's behalf.
        guard handlesMedia,
              MediaDownloadablePlatform.supports(urlString)
        else { return false }
        if DirectMediaURL.kind(for: urlString) != nil { return true }
        guard let platform = PlatformRecognizer.recognize(urlString)?.platform else { return false }
        return MediaDownloadablePlatform.supported.contains(platform)
    }

    /// Starts the background transfer for an App Intent save, reporting WHY it
    /// didn't start when it didn't (see `LiveMediaDownloadStartResult`) so the
    /// intent can throw instead of exiting with silent success.
    public static func startDownloaderIntentDownload(
        forURLString urlString: String
    ) async -> LiveMediaDownloadStartResult {
        guard shouldStartDownloaderIntentDownload(forURLString: urlString) else {
            return .unsupported
        }
        return await LiveMediaDownloadManager.shared.startReportingResult(
            urlString: urlString, ownership: .downloader)
    }

    /// The result of an awaited App Intent download: the bytes, or the reason
    /// there are none. `.failed` is the case that must reach the user — the
    /// transfer ended with nothing in the library.
    public enum AwaitedIntentDownload: Equatable {
        case completed(DownloadedMedia)
        /// No transfer was needed or one is legitimately still queued — nothing
        /// to hand back now, and nothing wrong (`isDownloadHandled` reasons).
        case handledWithoutFile(LiveMediaDownloadStartResult)
        /// Nothing was downloaded and nothing will be.
        case failed(message: String?)
    }

    /// Completes a Downloader-owned App Intent download before returning and
    /// exposes the resulting local bytes for a Shortcut result. Existing
    /// durable downloads are reused without another network fetch. A
    /// Photos-backed item is copied to a transient file because `IntentFile`
    /// needs an on-disk resource it can hand to Shortcuts.
    /// `onByteProgress` receives the transfer's `(received, expected)` byte counts
    /// as they land, so an awaiting App Intent can report REAL download progress
    /// instead of an estimate. Called on the polling cadence of
    /// `waitForDownloaderResult`.
    public static func downloadForDownloaderIntentAwaiting(
        forURLString urlString: String,
        onByteProgress: @escaping (Int64, Int64?) -> Void = { _, _ in }
    ) async -> AwaitedIntentDownload {
        guard shouldStartDownloaderIntentDownload(forURLString: urlString),
              let url = URL(string: urlString)
        else { return .failed(message: nil) }

        if let existing = SavedMediaStore.shared.existingDownloadedItem(
            forURLString: urlString
        ) {
            guard let media = await exportFile(from: existing) else {
                return .failed(message: nil)
            }
            return .completed(media)
        }

        let start = await LiveMediaDownloadManager.shared.startReportingResult(
            urlString: url.absoluteString,
            title: ReadingListStore.shared.item(forURLString: urlString)?.title,
            ownership: .downloader)
        switch start {
        case .started: break
        case .deferredUntilWiFi, .alreadyDownloaded:
            // Nothing to await: the transfer is the user's Wi-Fi setting's to
            // run, or the library already holds it (a race with another save).
            return .handledWithoutFile(start)
        case .notAuthorized, .unsupported, .failed:
            guard LiveMediaDownloadManager.shared.currentDownloadSnapshot(
                forSourceURLString: urlString) != nil
            else {
                AutoDownloadSettings.unmarkDownloaded(urlString)
                if case let .failed(message) = start { return .failed(message: message) }
                return .failed(message: nil)
            }
        }
        guard let item = await LiveMediaDownloadManager.shared.waitForDownloaderResult(
            forSourceURLString: urlString, onByteProgress: onByteProgress),
            let media = await exportFile(from: item)
        else { return .failed(message: nil) }
        return .completed(media)
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
            case .audio:
                let ext = sourceExtension?.lowercased() ?? ""
                return ["aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "wav"].contains(ext)
                    ? ext
                    : "m4a"
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
        _ = try? SavedMediaStore.shared.ensureUndownloaded(
            id: item.id,
            sourceURLString: item.urlString,
            title: item.title,
            dateSaved: item.dateAdded)
    }

    /// Whether the running process belongs to an app that OWNS media handling —
    /// Luna Downloader or the central Luna app (either the app itself or one of
    /// its extensions; `LunaApp` resolves both). Public so the share surface can
    /// route saves into the app-owned `SavedMediaStore` (the media grid's data
    /// source) rather than Photos.
    public static var isRunningInDownloader: Bool {
        switch LunaApp.current {
        case .luna, .downloader: return true
        case .reader, .priceTracker: return false
        }
    }
}
