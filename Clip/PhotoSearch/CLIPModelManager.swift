//
//  CLIPModelManager.swift
//  clipper
//

import CoreML
import Foundation

enum CLIPModelError: Error {
    case downloadFailed(Error)
    case compilationFailed(Error)
    case incompleteDownload
    case emptyPackageListing
    case listingFailed(String)
}

/// Manages on-demand download and on-disk storage of CLIP Core ML encoders.
///
/// Each model is two `.mlpackage` directories (image + text) hosted on
/// HuggingFace. Because `.mlpackage` is a directory bundle, its files are
/// enumerated via the HuggingFace tree API and downloaded individually into a
/// staging directory, then compiled with `MLModel.compileModel` into `.mlmodelc`
/// directories that Core ML can load. Compiled models live in Application Support
/// so they survive launches and are excluded from iCloud backup (re-downloadable).
protocol CLIPModelManager: Sendable {
    /// Whether both compiled encoders for the model are available (downloaded for
    /// HuggingFace models, or present in the app bundle for bundled models).
    func isDownloaded(_ model: CLIPModel) -> Bool

    /// The compiled image-encoder `.mlmodelc` directory, or nil if a bundled
    /// model's resource isn't present in the app bundle.
    func imageEncoderURL(for model: CLIPModel) -> URL?

    /// The compiled text-encoder `.mlmodelc` directory, or nil if a bundled
    /// model's resource isn't present in the app bundle.
    func textEncoderURL(for model: CLIPModel) -> URL?

    /// Downloads and compiles both encoders, reporting fractional progress
    /// (0...1). No-op if already downloaded.
    func download(
        _ model: CLIPModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws

    /// Copies a bundled model's compiled encoders into the App Group container so
    /// the background ingest extension (which can't see the app's bundle) can load
    /// them. No-op for non-bundled models or if already staged.
    func stageBundledModelInSharedContainer(_ model: CLIPModel)
}

final class CLIPModelManagerImpl: CLIPModelManager {

    private let logger: Logger
    private let session: URLSession

    /// Fraction of the progress bar allotted to downloading (the remainder is the
    /// Core ML compile step, which is non-trivial for ViT-class encoders).
    private let downloadProgressShare = 0.9

    init(logger: Logger, session: URLSession = .shared) {
        self.logger = logger
        self.session = session
    }

    func imageEncoderURL(for model: CLIPModel) -> URL? {
        switch model.source {
        case .huggingFace:
            return Self.modelDirectory(for: model).appendingPathComponent("image.mlmodelc", isDirectory: true)
        case .bundled(let imageResource, _):
            // Prefer the App Group staged copy (so the extension can load it too),
            // falling back to the app bundle.
            let staged = Self.modelDirectory(for: model).appendingPathComponent("image.mlmodelc", isDirectory: true)
            if FileManager.default.fileExists(atPath: staged.path) { return staged }
            return Bundle.main.url(forResource: imageResource, withExtension: "mlmodelc")
        case .system:
            return nil
        }
    }

    func textEncoderURL(for model: CLIPModel) -> URL? {
        switch model.source {
        case .huggingFace:
            return Self.modelDirectory(for: model).appendingPathComponent("text.mlmodelc", isDirectory: true)
        case .bundled(_, let textResource):
            let staged = Self.modelDirectory(for: model).appendingPathComponent("text.mlmodelc", isDirectory: true)
            if FileManager.default.fileExists(atPath: staged.path) { return staged }
            return Bundle.main.url(forResource: textResource, withExtension: "mlmodelc")
        case .system:
            return nil
        }
    }

    func stageBundledModelInSharedContainer(_ model: CLIPModel) {
        guard case .bundled(let imageResource, let textResource) = model.source else { return }
        let fm = FileManager.default
        let directory = Self.modelDirectory(for: model)
        let stagedImage = directory.appendingPathComponent("image.mlmodelc", isDirectory: true)
        let stagedText = directory.appendingPathComponent("text.mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: stagedImage.path) && fm.fileExists(atPath: stagedText.path) { return }
        guard
            let bundledImage = Bundle.main.url(forResource: imageResource, withExtension: "mlmodelc"),
            let bundledText = Bundle.main.url(forResource: textResource, withExtension: "mlmodelc")
        else { return }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: stagedImage)
            try fm.copyItem(at: bundledImage, to: stagedImage)
            try? fm.removeItem(at: stagedText)
            try fm.copyItem(at: bundledText, to: stagedText)
            Self.excludeFromBackup(Self.modelsRoot())
        } catch {
            logger.error("Failed to stage bundled CLIP model to App Group: \(error)")
        }
    }

    func isDownloaded(_ model: CLIPModel) -> Bool {
        switch model.source {
        case .huggingFace:
            let fm = FileManager.default
            guard
                let imageURL = imageEncoderURL(for: model),
                let textURL = textEncoderURL(for: model)
            else { return false }
            return fm.fileExists(atPath: imageURL.path) && fm.fileExists(atPath: textURL.path)
        case .bundled:
            // Compiled by Xcode at build time; present iff the model files were
            // added to the app target.
            return imageEncoderURL(for: model) != nil && textEncoderURL(for: model) != nil
        case .system:
            // Apple Vision frameworks are always available on-device.
            return true
        }
    }

    func download(
        _ model: CLIPModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Bundled models need no download; they're either present or unavailable.
        guard case .huggingFace = model.source else {
            onProgress(1)
            return
        }
        if isDownloaded(model) {
            onProgress(1)
            return
        }

        // HuggingFace models always define packages and on-disk destinations.
        guard
            let imagePackage = model.imageEncoderPackage,
            let textPackage = model.textEncoderPackage,
            let imageDest = imageEncoderURL(for: model),
            let textDest = textEncoderURL(for: model)
        else {
            throw CLIPModelError.emptyPackageListing
        }

        do {
            // 1. Enumerate every file inside both .mlpackage directories.
            let imageFiles = try await listPackageFiles(package: imagePackage)
            let textFiles = try await listPackageFiles(package: textPackage)
            let allFiles = imageFiles + textFiles
            guard !allFiles.isEmpty else { throw CLIPModelError.emptyPackageListing }
            let totalBytes = max(1, allFiles.reduce(0) { $0 + $1.size })

            // 2. Download every file into a staging directory, recreating the
            //    package directory tree, so a partial download is never seen.
            let fm = FileManager.default
            let staging = Self.modelsRoot()
                .appendingPathComponent(".\(model.rawValue).partial", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            var completedBytes: Int64 = 0
            for file in allFiles {
                let base = completedBytes
                let forwarder = CLIPDownloadProgressForwarder(expectedBytes: file.size) { [downloadProgressShare] fraction in
                    let bytes = Double(base) + fraction * Double(file.size)
                    onProgress(min(downloadProgressShare, bytes / Double(totalBytes) * downloadProgressShare))
                }
                let remoteURL = Self.resolveURL(path: file.path)
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

            // 3. Compile both .mlpackage directories to .mlmodelc and move into place.
            onProgress(downloadProgressShare)
            let finalDir = Self.modelDirectory(for: model)
            try? fm.removeItem(at: finalDir)
            try fm.createDirectory(at: finalDir, withIntermediateDirectories: true)

            try await compile(
                packageURL: staging.appendingPathComponent(imagePackage),
                to: imageDest
            )
            onProgress((downloadProgressShare + 1) / 2)
            try await compile(
                packageURL: staging.appendingPathComponent(textPackage),
                to: textDest
            )

            try? fm.removeItem(at: staging)
            Self.excludeFromBackup(Self.modelsRoot())

            guard isDownloaded(model) else { throw CLIPModelError.incompleteDownload }
            onProgress(1)
        } catch let error as CLIPModelError {
            throw error
        } catch {
            logger.error("CLIP model download failed: \(error)")
            throw CLIPModelError.downloadFailed(error)
        }
    }

    // MARK: - HuggingFace listing

    /// One file entry returned by the HuggingFace tree API.
    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64
    }

    private func listPackageFiles(package: String) async throws -> [TreeEntry] {
        let repo = CLIPModel.huggingFaceRepo
        let rev = CLIPModel.huggingFaceRevision
        guard
            let url = URL(string:
                "https://huggingface.co/api/models/\(repo)/tree/\(rev)/\(package)?recursive=true")
        else {
            throw CLIPModelError.emptyPackageListing
        }
        let (data, _) = try await session.data(from: url)
        // The tree endpoint returns a JSON array on success; on failure (e.g. a
        // missing path) it returns an `{ "error": "..." }` object. Surface that
        // as a clear error instead of an opaque decoding type-mismatch.
        if let failure = try? JSONDecoder().decode(TreeError.self, from: data) {
            logger.error("HuggingFace tree listing failed for \(package): \(failure.error)")
            throw CLIPModelError.listingFailed(failure.error)
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return entries.filter { $0.type == "file" }
    }

    /// Error payload returned by the HuggingFace tree API when a path is invalid.
    private struct TreeError: Decodable {
        let error: String
    }

    private func compile(packageURL: URL, to destination: URL) async throws {
        do {
            let compiled = try await MLModel.compileModel(at: packageURL)
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: compiled, to: destination)
        } catch {
            throw CLIPModelError.compilationFailed(error)
        }
    }

    // MARK: - Paths

    private static func resolveURL(path: String) -> URL {
        let repo = CLIPModel.huggingFaceRepo
        let rev = CLIPModel.huggingFaceRevision
        let encoded = path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        // URL(string:) is safe here: repo/rev are static literals and the path is
        // percent-encoded above.
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(rev)/\(encoded)")!
    }

    private static func modelsRoot() -> URL {
        // App Group container so the background ingest extension loads the same
        // downloaded encoders; falls back to Application Support if unavailable.
        let base = AppGroup.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CLIPModels", isDirectory: true)
    }

    private static func modelDirectory(for model: CLIPModel) -> URL {
        modelsRoot().appendingPathComponent(model.rawValue, isDirectory: true)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Forwards `URLSessionDownloadTask` byte progress as a 0...1 fraction for a
/// single file download.
private final class CLIPDownloadProgressForwarder: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let onProgress: @Sendable (Double) -> Void
    /// Expected size from the HuggingFace tree listing, used when the server doesn't
    /// send Content-Length (so `totalBytesExpectedToWrite` is unknown).
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
