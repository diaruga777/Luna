//
//  VLMModelManager.swift
//  clipper
//

import Foundation

enum VLMModelError: Error {
    case downloadFailed(Error)
    case emptyRepoListing
    case listingFailed(String)
    case incompleteDownload
}

/// Manages on-demand download and on-disk storage of MLX VLM checkpoints.
///
/// Each model is a whole HuggingFace repository snapshot (config, tokenizer,
/// safetensors). Files are enumerated via the HuggingFace tree API and downloaded
/// individually into a staging directory, then moved into place atomically so a
/// partial download is never seen as the model. Checkpoints live in the App Group
/// container (so the ingest extension can load them) and are excluded from iCloud
/// backup (re-downloadable).
protocol VLMModelManager: Sendable {
    /// Whether the model's checkpoint is fully downloaded.
    func isDownloaded(_ model: VLMModel) -> Bool

    /// The on-disk directory of the downloaded checkpoint, or nil if absent.
    func modelURL(for model: VLMModel) -> URL?

    /// Downloads the checkpoint, reporting fractional progress (0...1). No-op if
    /// already downloaded.
    func download(
        _ model: VLMModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

final class VLMModelManagerImpl: VLMModelManager {

    /// A file is considered the completion marker for a snapshot: if it's present
    /// in the final directory, the atomic move succeeded.
    private static let completionMarker = "config.json"

    private let logger: Logger
    private let session: URLSession

    init(logger: Logger, session: URLSession = .shared) {
        self.logger = logger
        self.session = session
    }

    func modelURL(for model: VLMModel) -> URL? {
        Self.modelDirectory(for: model)
    }

    func isDownloaded(_ model: VLMModel) -> Bool {
        guard let dir = modelURL(for: model) else { return false }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(Self.completionMarker).path
        )
    }

    func download(
        _ model: VLMModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if isDownloaded(model) {
            onProgress(1)
            return
        }

        do {
            let files = try await listRepoFiles(model: model)
            guard !files.isEmpty else { throw VLMModelError.emptyRepoListing }
            let totalBytes = max(1, files.reduce(0) { $0 + $1.size })

            let fm = FileManager.default
            let staging = Self.modelsRoot()
                .appendingPathComponent(".\(model.rawValue).partial", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            var completedBytes: Int64 = 0
            for file in files {
                let base = completedBytes
                // HuggingFace's CDN often omits Content-Length, so the download task
                // reports an unknown expected size. Fall back to the size from the
                // tree listing so progress still advances.
                let forwarder = VLMDownloadProgressForwarder(expectedBytes: file.size) { fraction in
                    let bytes = Double(base) + fraction * Double(file.size)
                    onProgress(min(1, bytes / Double(totalBytes)))
                }
                let remoteURL = Self.resolveURL(model: model, path: file.path)
                let (tempURL, _) = try await session.download(from: remoteURL, delegate: forwarder)
                let dest = staging.appendingPathComponent(file.path, isDirectory: false)
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tempURL, to: dest)
                completedBytes += file.size
            }

            // Atomic publish: move the fully-staged snapshot into its final home.
            let finalDir = Self.modelDirectory(for: model)
            try? fm.removeItem(at: finalDir)
            try fm.createDirectory(
                at: finalDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: staging, to: finalDir)
            Self.excludeFromBackup(Self.modelsRoot())

            guard isDownloaded(model) else { throw VLMModelError.incompleteDownload }
            onProgress(1)
        } catch let error as VLMModelError {
            throw error
        } catch {
            logger.error("VLM model download failed: \(error)")
            throw VLMModelError.downloadFailed(error)
        }
    }

    // MARK: - HuggingFace listing

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64
    }

    private struct TreeError: Decodable {
        let error: String
    }

    private func listRepoFiles(model: VLMModel) async throws -> [TreeEntry] {
        guard let url = URL(string:
            "https://huggingface.co/api/models/\(model.huggingFaceRepo)/tree/\(model.huggingFaceRevision)?recursive=true")
        else {
            throw VLMModelError.emptyRepoListing
        }
        let (data, _) = try await session.data(from: url)
        if let failure = try? JSONDecoder().decode(TreeError.self, from: data) {
            logger.error("HuggingFace tree listing failed for \(model.huggingFaceRepo): \(failure.error)")
            throw VLMModelError.listingFailed(failure.error)
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return entries.filter { $0.type == "file" }
    }

    // MARK: - Paths

    private static func resolveURL(model: VLMModel, path: String) -> URL {
        let encoded = path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // URL(string:) is safe: repo/rev come from a static enum and the path is
        // percent-encoded above.
        return URL(string:
            "https://huggingface.co/\(model.huggingFaceRepo)/resolve/\(model.huggingFaceRevision)/\(encoded)")!
    }

    private static func modelsRoot() -> URL {
        let base = AppGroup.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VLMModels", isDirectory: true)
    }

    private static func modelDirectory(for model: VLMModel) -> URL {
        modelsRoot().appendingPathComponent(model.rawValue, isDirectory: true)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Forwards `URLSessionDownloadTask` byte progress as a 0...1 fraction for a single
/// file download.
private final class VLMDownloadProgressForwarder: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let onProgress: @Sendable (Double) -> Void
    /// Expected size from the HuggingFace tree listing, used when the server doesn't
    /// send Content-Length (so `totalBytesExpectedToWrite` is `NSURLSessionTransferSizeUnknown`).
    private let expectedBytes: Int64

    init(expectedBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let denominator = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard denominator > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(denominator)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
