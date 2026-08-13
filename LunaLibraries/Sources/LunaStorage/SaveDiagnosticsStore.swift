//
//  SaveDiagnosticsStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig

/// The per-save diagnostic trace: everything Luna observed while trying (and
/// failing) to save one URL — network requests, response shapes, classification
/// decisions, bypass strategies, rescue attempts — as plain timestamped text
/// lines in the same `ISO8601 [category] message` format as the shared
/// `clip-diagnostics.log`.
///
/// One file per saved item, `<AppGroup>/saveDiagnostics/<UUID>.log`.
/// A file exists only for items whose save FAILED: the ingest layer buffers a
/// save's lines in memory (`SaveDiagnosticsRecorder`, LunaModels) and flushes
/// them here only when the outcome is `.failed`; later attempts — launch-sweep
/// retries, Apple Intelligence rescues — append to the same file. The failed
/// save card exports this file for the user to share, and the URL-rescue engine
/// reads it back as failure evidence for the model.
///
/// Like the reason/count sidecar (`SaveFailureStore`), this deliberately never
/// touches the saves database. Writes are SYNCHRONOUS for the same reason
/// `SharedDiagnosticLog`'s are: an extension can be jetsammed the instant after
/// a save fails, and the flush must land before that.
public final class SaveDiagnosticsStore: @unchecked Sendable {
    public static let shared = SaveDiagnosticsStore()

    private let directoryURL: URL?
    private let maxBytesPerFile: Int
    private let lock = NSLock()

    public init(containerURL: URL? = nil, maxBytesPerFile: Int = 262_144) {
        let base = containerURL ?? AppConfig.sharedContainerURL()
        self.directoryURL = base?.appendingPathComponent("saveDiagnostics", isDirectory: true)
        self.maxBytesPerFile = maxBytesPerFile
    }

    // MARK: - Writing

    /// Appends pre-formatted lines (each already timestamped by the recorder)
    /// to the item's trace file, creating it on first flush. Oversized files
    /// are trimmed from the FRONT so the most recent attempt survives.
    public func appendLines(_ lines: [String], for itemID: UUID) {
        guard !lines.isEmpty else { return }
        let block = lines.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
        guard let data = block.data(using: .utf8), let fileURL = fileURL(for: itemID) else { return }
        lock.lock(); defer { lock.unlock() }
        ensureDirectory()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            BackupPolicy.excludeFromBackups(fileURL)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        trimIfNeededLocked(fileURL)
    }

    public func appendLine(_ line: String, for itemID: UUID) {
        appendLines([line], for: itemID)
    }

    // MARK: - Reading

    /// The whole trace, or nil when this item never flushed one.
    public func contents(for itemID: UUID) -> String? {
        guard let fileURL = fileURL(for: itemID) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func hasDiagnostics(for itemID: UUID) -> Bool {
        guard let fileURL = fileURL(for: itemID) else { return false }
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Writes `header + trace` to a shareable .txt in the temporary directory
    /// and returns its URL (same shape as `DiagnosticLog.exportFile`).
    public func exportFile(for itemID: UUID, header: String) throws -> URL {
        guard let body = contents(for: itemID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let name = "luna-save-diagnostics-\(itemID.uuidString.prefix(8)).txt"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try (header + body).write(to: destination, atomically: true, encoding: .utf8)
        BackupPolicy.excludeFromBackups(destination)
        return destination
    }

    // MARK: - Lifecycle

    /// Removes an item's trace — call wherever the item stops being failed
    /// (successful retry or rescue) and when the item is deleted.
    public func delete(for itemID: UUID) {
        guard let fileURL = fileURL(for: itemID) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Drops trace files for items no longer present (paired with
    /// `SaveFailureStore.prune`).
    public func prune(keeping ids: Set<UUID>) {
        guard let directoryURL else { return }
        let keep = Set(ids.map { $0.uuidString.uppercased() })
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "log" {
            let stem = file.deletingPathExtension().lastPathComponent.uppercased()
            if !keep.contains(stem) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Private

    private func fileURL(for itemID: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(itemID.uuidString).log")
    }

    private func ensureDirectory() {
        guard let directoryURL,
              !FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        BackupPolicy.excludeFromBackups(directoryURL)
    }

    /// Keeps the file under `maxBytesPerFile` by dropping the OLDEST half at a
    /// line boundary (the inverse priority of `DiagnosticLog.trimIfNeeded`,
    /// which this otherwise mirrors): retries append forever, and the newest
    /// attempt is the one worth sharing.
    private func trimIfNeededLocked(_ fileURL: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int, size > maxBytesPerFile,
              let data = try? Data(contentsOf: fileURL) else { return }
        var tail = data.suffix(maxBytesPerFile / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: newline))
        }
        var trimmed = Data("…(trimmed)\n".utf8)
        trimmed.append(tail)
        try? trimmed.write(to: fileURL, options: .atomic)
    }
}
