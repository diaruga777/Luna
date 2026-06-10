//
//  PhotoIndexStore.swift
//  clipper
//

import Foundation

enum PhotoIndexStoreError: Error {
    case writeFailed(Error)
    case readFailed(Error)
}

/// Persists the photo-search index as a single flat binary file in Application
/// Support (no database — per project persistence rules). Writes are atomic so a
/// crash mid-write never corrupts a previously good index.
protocol PhotoIndexStore: Sendable {
    /// Loads the saved index, or nil if none has been written yet.
    func load() throws -> PhotoEmbeddingIndex?

    /// Atomically writes the index to disk.
    func save(_ index: PhotoEmbeddingIndex) throws

    /// Removes any saved index.
    func deleteIndex() throws

    /// Coordinated read-modify-write that inserts or replaces the entry for its
    /// `localIdentifier`. Used by the background ingest path, where the app and the
    /// extension may write concurrently — `NSFileCoordinator` serializes them so an
    /// append can't clobber the other process's index. Creates the index for
    /// `modelIdentifier`/`embeddingDimension` if none exists; skips the write if an
    /// existing index is for a different model (vectors aren't comparable).
    func appendEntry(
        _ entry: PhotoIndexEntry,
        modelIdentifier: String,
        embeddingDimension: Int
    ) throws
}

final class PhotoIndexStoreImpl: PhotoIndexStore {

    private let logger: Logger
    private let fileURL: URL

    init(logger: Logger, fileURL: URL? = nil) {
        self.logger = logger
        self.fileURL = fileURL ?? Self.defaultURL()
    }

    func load() throws -> PhotoEmbeddingIndex? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try PropertyListDecoder().decode(PhotoEmbeddingIndex.self, from: data)
        } catch {
            logger.error("Failed to read photo index: \(error)")
            throw PhotoIndexStoreError.readFailed(error)
        }
    }

    func save(_ index: PhotoEmbeddingIndex) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(index)
            // Atomic write: a partial file is never observed as the index.
            try data.write(to: fileURL, options: .atomic)
            Self.excludeFromBackup(fileURL)
        } catch {
            logger.error("Failed to write photo index: \(error)")
            throw PhotoIndexStoreError.writeFailed(error)
        }
    }

    func deleteIndex() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        try fm.removeItem(at: fileURL)
    }

    func appendEntry(
        _ entry: PhotoIndexEntry,
        modelIdentifier: String,
        embeddingDimension: Int
    ) throws {
        var coordinationError: NSError?
        var thrownError: Error?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            do {
                let current = try Self.read(at: url)
                if let current,
                   current.modelIdentifier != modelIdentifier
                    || current.embeddingDimension != embeddingDimension {
                    logger.info("Skipping index append for \(entry.localIdentifier): index model mismatch")
                    return
                }
                var index = current ?? PhotoEmbeddingIndex(
                    modelIdentifier: modelIdentifier,
                    embeddingDimension: embeddingDimension
                )
                if let existingIndex = index.entries.firstIndex(where: { $0.localIdentifier == entry.localIdentifier }) {
                    index.entries[existingIndex] = entry
                } else {
                    index.entries.append(entry)
                }
                try Self.write(index, to: url)
            } catch {
                thrownError = error
            }
        }
        if let coordinationError { throw PhotoIndexStoreError.writeFailed(coordinationError) }
        if let thrownError { throw thrownError }
    }

    // MARK: - Encoding

    private static func read(at url: URL) throws -> PhotoEmbeddingIndex? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try PropertyListDecoder().decode(PhotoEmbeddingIndex.self, from: Data(contentsOf: url))
    }

    private static func write(_ index: PhotoEmbeddingIndex, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(index).write(to: url, options: .atomic)
        excludeFromBackup(url)
    }

    private static func defaultURL() -> URL {
        // App Group container so the background ingest extension shares the index;
        // falls back to Application Support if the container is unavailable.
        let base = AppGroup.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("PhotoSearchIndex", isDirectory: true)
            .appendingPathComponent("index.plist", isDirectory: false)
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
