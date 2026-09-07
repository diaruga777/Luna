//
//  TranscriptionSourceDownloader.swift
//  LunaTranscribe
//

import Foundation
import LunaModels

/// Fetches a request's recording to a local file.
public protocol TranscriptionSourceDownloading {
    /// Downloads `request.fetchURL` with the request's headers and leaves the
    /// bytes at `destination`, replacing any file there. Throws
    /// `TranscriptionError`: `.sourceUnavailable` for 401/403/410,
    /// `.httpStatus` for any other non-2xx answer, `.tooLarge` past the
    /// ceiling, `.transport` for everything below HTTP.
    func download(_ request: TranscriptionRequest, to destination: URL) async throws
}

/// The `URLSession` downloader. A foreground session: a transcription job
/// runs while the app runs, under a background lease, and resumes from its
/// row after a kill rather than through a background transfer.
public final class URLSessionTranscriptionDownloader: TranscriptionSourceDownloading {

    /// A recording larger than this is never fetched.
    public static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(_ request: TranscriptionRequest, to destination: URL) async throws {
        var urlRequest = URLRequest(url: request.fetchURL)
        urlRequest.timeoutInterval = 60
        for (name, value) in request.requestHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let ceiling = ByteCeiling(limit: Self.maxBytes)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: urlRequest, delegate: ceiling)
        } catch {
            if ceiling.exceeded { throw TranscriptionError.tooLarge }
            throw TranscriptionError.transport(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403, 410: throw TranscriptionError.sourceUnavailable
            default: throw TranscriptionError.httpStatus(http.statusCode)
            }
        }
        if response.expectedContentLength > Self.maxBytes { throw TranscriptionError.tooLarge }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? 0
        if size > Self.maxBytes { throw TranscriptionError.tooLarge }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw TranscriptionError.transport(error.localizedDescription)
        }
    }
}

/// Cancels a transfer the moment it passes the ceiling, so an over-sized
/// recording is never held whole.
private final class ByteCeiling: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private(set) var exceeded = false

    init(limit: Int64) {
        self.limit = limit
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            exceeded = true
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async `download(for:)` API moves the file itself.
    }
}
