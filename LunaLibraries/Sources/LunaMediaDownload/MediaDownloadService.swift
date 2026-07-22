//
//  MediaDownloadService.swift
//  Luna
//

import Foundation
import LunaStorage
import LunaURLClassification

/// Resolves → downloads → saves a social post's first media item to Photos.
/// Used by both entry points (the action extension button + the reading list
/// long-press menu). Streams the file to disk so a large video never sits in
/// memory, and reports progress for the action extension's progress bar.
public struct MediaDownloadService: MediaDownloading {

    private let resolver: SocialMediaResolving
    private let saver: PhotoLibrarySaving

    public init(resolver: SocialMediaResolving = SocialMediaResolver(),
         saver: PhotoLibrarySaving = PhotoLibrarySaver()) {
        self.resolver = resolver
        self.saver = saver
    }

    public func downloadFirstMediaToPhotos(
        from url: URL, onProgress: @escaping (Double) -> Void
    ) async throws -> MediaAsset.Kind {
        guard MediaDownloadablePlatform.supports(url.absoluteString) else {
            throw MediaDownloadError.unsupported
        }
        // Permission first (so the prompt appears before any work), then resolve.
        guard await saver.requestAddAuthorization() else { throw MediaDownloadError.permissionDenied }

        let assets = await resolver.resolveAssets(for: url)
        guard let asset = assets.first else { throw MediaDownloadError.noMedia }
        let expected = await MediaDownloadPreflight.expectedByteCount(
            for: asset, sourceURL: url)
        if let error = MediaDownloadPreflight.storageError(
            expectedByteCount: expected,
            requiresProcessingCopy: asset.timeRange?.isEffective == true) {
            throw error
        }

        let referer = MediaDownloadService.referer(for: url)
        let fileURL: URL
        do {
            fileURL = try await MediaFileDownloader.download(asset, referer: referer, onProgress: onProgress)
        } catch {
            throw MediaDownloadError.downloadFailed
        }

        do {
            _ = try await saver.save(fileURL: fileURL, kind: asset.kind)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw MediaDownloadError.saveFailed
        }
        // `shouldMoveFile` consumes it on success; clean up defensively otherwise.
        try? FileManager.default.removeItem(at: fileURL)
        return asset.kind
    }

    public func downloadFirstMediaToAppStorage(
        from url: URL, title: String?, onProgress: @escaping (Double) -> Void
    ) async throws -> SavedMediaItem {
        guard MediaDownloadablePlatform.supports(url.absoluteString) else {
            throw MediaDownloadError.unsupported
        }
        let pending = try SavedMediaStore.shared.ensureUndownloaded(
            id: ReadingListStore.shared.item(forURLString: url.absoluteString)?.id ?? UUID(),
            sourceURLString: url.absoluteString,
            title: title)
        let assets = await resolver.resolveAssets(for: url)
        guard let asset = assets.first else { throw MediaDownloadError.noMedia }
        let expected = await MediaDownloadPreflight.expectedByteCount(
            for: asset, sourceURL: url)
        if let error = MediaDownloadPreflight.storageError(
            expectedByteCount: expected,
            requiresProcessingCopy: asset.timeRange?.isEffective == true) {
            throw error
        }

        let referer = MediaDownloadService.referer(for: url)
        let fileURL: URL
        do {
            fileURL = try await MediaFileDownloader.download(asset, referer: referer, onProgress: onProgress)
        } catch {
            throw MediaDownloadError.downloadFailed
        }

        if AutoDownloadSettings.autoSaveDownloadsToPhotos,
           await saver.requestReadAuthorization() {
            do {
                let identifier = try await saver.save(
                    fileURL: fileURL, kind: asset.kind, shouldMoveFile: false)
                guard let item = try SavedMediaStore.shared.transitionToPhotosReference(
                    pending.id, localIdentifier: identifier, kind: asset.kind)
                else { throw MediaDownloadError.saveFailed }
                try? FileManager.default.removeItem(at: fileURL)
                await copyToClipboardIfEnabled(item)
                return item
            } catch {
                // The completed file remains available because PhotoKit was told not
                // to move it. Preserve it locally when Photos cannot become backing.
            }
        }

        do {
            let item = try SavedMediaStore.shared.addDownloadedFile(
                fileURL,
                kind: asset.kind,
                sourceURLString: url.absoluteString,
                title: title,
                fileExtension: fileURL.pathExtension,
                requiringItemID: pending.id)
            await copyToClipboardIfEnabled(item)
            return item
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw MediaDownloadError.saveFailed
        }
    }

    public func downloadFirstMediaToFile(
        from url: URL, onProgress: @escaping (Double) -> Void
    ) async throws -> DownloadedMedia {
        guard MediaDownloadablePlatform.supports(url.absoluteString) else {
            throw MediaDownloadError.unsupported
        }
        // No Photos permission here — previewing inline shouldn't prompt; the prompt
        // is deferred until the user taps "Save to Photos".
        let assets = await resolver.resolveAssets(for: url)
        guard let asset = assets.first else { throw MediaDownloadError.noMedia }
        let expected = await MediaDownloadPreflight.expectedByteCount(
            for: asset, sourceURL: url)
        if let error = MediaDownloadPreflight.storageError(
            expectedByteCount: expected,
            requiresProcessingCopy: asset.timeRange?.isEffective == true) {
            throw error
        }

        let referer = MediaDownloadService.referer(for: url)
        do {
            let fileURL = try await MediaFileDownloader.download(
                asset, referer: referer, onProgress: onProgress)
            return DownloadedMedia(fileURL: fileURL, kind: asset.kind)
        } catch {
            throw MediaDownloadError.downloadFailed
        }
    }

    public func saveDownloadedMediaToPhotos(_ media: DownloadedMedia) async throws -> String {
        guard await saver.requestReadAuthorization() else {
            throw MediaDownloadError.permissionDenied
        }
        do {
            return try await saver.save(fileURL: media.fileURL, kind: media.kind)
        } catch {
            throw MediaDownloadError.saveFailed
        }
    }

    /// TikTok, Reddit, and YouTube media CDNs receive their site's Referer.
    /// `url` is always the already-recognized source post URL (every caller gates on
    /// `MediaDownloadablePlatform.supports` first), so an anchored host-suffix match
    /// is exactly as reliable here as the old substring check and doesn't risk a
    /// stray `faketiktok.com` false positive.
    private static func referer(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if HostMatching.hostSuffixMatches(host, "tiktok.com") { return "https://www.tiktok.com/" }
        if HostMatching.hostSuffixMatches(host, anyOf: ["reddit.com", "redd.it"]) {
            return "https://www.reddit.com/"
        }
        if PlatformRecognizer.recognize(url.absoluteString)?.platform == .youtube {
            return "https://www.youtube.com/"
        }
        return nil
    }
}

/// Streams a remote media file to a temp file (memory-efficient) with progress,
/// via a download-task delegate. Picks the file extension from the asset kind and
/// the response's MIME type.
public final class MediaFileDownloader: NSObject, URLSessionDownloadDelegate {

    public static func download(
        _ asset: MediaAsset, referer: String?, onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let downloaded: URL
        if let audioURL = asset.audioURL {
            downloaded = try await downloadAndMux(
                videoURL: asset.url, audioURL: audioURL, dashManifestURL: asset.dashManifestURL,
                referer: referer, onProgress: onProgress)
        } else {
            let downloader = MediaFileDownloader(asset: asset, onProgress: onProgress)
            downloaded = try await downloader.run(referer: referer)
        }
        do {
            let final = try await MediaVideoTrimmer.trimIfNeeded(
                fileURL: downloaded, timeRange: asset.timeRange)
            if final != downloaded { try? FileManager.default.removeItem(at: downloaded) }
            return final
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
    }

    /// Reddit hosts video and audio as two separate files — downloads the
    /// video, resolves+downloads the audio via `RedditAudioFetcher` (its URL
    /// is a guess, not one Reddit hands back directly, so that tries a couple
    /// of fallbacks), and muxes them with `MediaMuxer`. If the audio still
    /// can't be fetched, degrades gracefully to the silent video rather than
    /// failing the whole download.
    private static func downloadAndMux(
        videoURL: URL, audioURL: URL, dashManifestURL: URL?, referer: String?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let videoFile = try await MediaFileDownloader(
            asset: MediaAsset(url: videoURL, kind: .video),
            onProgress: { onProgress($0 * 0.4) }
        ).run(referer: referer)
        onProgress(0.4)

        guard let audioFile = await RedditAudioFetcher.fetch(
            primaryAudioURL: audioURL, dashManifestURL: dashManifestURL,
            referer: referer ?? "https://www.reddit.com/")
        else {
            onProgress(1)
            return videoFile
        }
        onProgress(0.8)

        let muxedURL = MediaDownloadStorage.newFileURL(extension: "mp4")
        do {
            try await MediaMuxer.mux(videoURL: videoFile, audioURL: audioFile, outputURL: muxedURL)
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
            onProgress(1)
            return muxedURL
        } catch {
            try? FileManager.default.removeItem(at: audioFile)
            onProgress(1)
            return videoFile
        }
    }

    private let asset: MediaAsset
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    private init(asset: MediaAsset, onProgress: @escaping (Double) -> Void) {
        self.asset = asset
        self.onProgress = onProgress
    }

    private func run(referer: String?) async throws -> URL {
        var request = URLRequest(url: asset.url, timeoutInterval: 60)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: request)
            if let expected = asset.estimatedByteCount, expected > 0 {
                task.countOfBytesClientExpectsToReceive = expected
            }
            task.resume()
        }
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        let http = downloadTask.response as? HTTPURLResponse
        if let http, !(200..<300).contains(http.statusCode) {
            finish(.failure(MediaDownloadError.downloadFailed))
            return
        }
        let ext = MediaFileDownloader.fileExtension(for: asset, mimeType: http?.mimeType)
        let destination = MediaDownloadStorage.newFileURL(extension: ext)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onProgress(1)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session.invalidateAndCancel()
        continuation.resume(with: result)
    }

    /// The file extension to save under — preserve png/gif/mp4 when known, else a
    /// sensible default per kind (jpg for stills, mp4 for video).
    public static func fileExtension(for asset: MediaAsset, mimeType: String?) -> String {
        switch asset.kind {
        case .video:
            return "mp4"
        case .gif:
            return "gif"
        case .image:
            if mimeType == "image/png" { return "png" }
            if mimeType == "image/gif" { return "gif" }
            let pathExt = asset.url.pathExtension.lowercased()
            if pathExt == "png" { return "png" }
            if pathExt == "gif" { return "gif" }
            return "jpg"
        }
    }
}
