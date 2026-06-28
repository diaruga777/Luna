//
//  MediaDownloadService.swift
//  Clip
//

import Foundation

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

        let referer = MediaDownloadService.referer(for: url)
        let fileURL: URL
        do {
            fileURL = try await MediaFileDownloader.download(asset, referer: referer, onProgress: onProgress)
        } catch {
            throw MediaDownloadError.downloadFailed
        }

        do {
            try await saver.save(fileURL: fileURL, kind: asset.kind)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw MediaDownloadError.saveFailed
        }
        // `shouldMoveFile` consumes it on success; clean up defensively otherwise.
        try? FileManager.default.removeItem(at: fileURL)
        return asset.kind
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

        let referer = MediaDownloadService.referer(for: url)
        do {
            let fileURL = try await MediaFileDownloader.download(
                asset, referer: referer, onProgress: onProgress)
            return DownloadedMedia(fileURL: fileURL, kind: asset.kind)
        } catch {
            throw MediaDownloadError.downloadFailed
        }
    }

    public func saveDownloadedMediaToPhotos(_ media: DownloadedMedia) async throws {
        guard await saver.requestAddAuthorization() else {
            throw MediaDownloadError.permissionDenied
        }
        do {
            try await saver.save(fileURL: media.fileURL, kind: media.kind)
        } catch {
            throw MediaDownloadError.saveFailed
        }
    }

    /// TikTok media CDNs require the tiktok.com Referer; others download bare.
    private static func referer(for url: URL) -> String? {
        (url.host?.lowercased().contains("tiktok") ?? false) ? "https://www.tiktok.com/" : nil
    }
}

/// Streams a remote media file to a temp file (memory-efficient) with progress,
/// via a download-task delegate. Picks the file extension from the asset kind and
/// the response's MIME type.
public final class MediaFileDownloader: NSObject, URLSessionDownloadDelegate {

    public static func download(
        _ asset: MediaAsset, referer: String?, onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let downloader = MediaFileDownloader(asset: asset, onProgress: onProgress)
        return try await downloader.run(referer: referer)
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
            session.downloadTask(with: request).resume()
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
