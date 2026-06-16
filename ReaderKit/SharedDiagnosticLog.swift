//
//  SharedDiagnosticLog.swift
//  ReaderKit
//

import Foundation

/// Minimal append-only diagnostic logger usable from the share/action
/// extensions, which can't reach the main app's richer `DiagnosticLog` (it
/// depends on main-app-only CloudKit/identity types). Writes timestamped lines
/// in the SAME format, to the SAME App Group `clip-diagnostics.log` file the
/// main app reads and exports — so extension activity shows up in Settings →
/// Diagnostics alongside everything else.
enum SharedDiagnosticLog {

    private static let lock = NSLock()

    /// Appends one timestamped line tagged with `category` to the shared log.
    /// SYNCHRONOUS: an extension can be killed the instant after it logs, so the
    /// write must complete before returning — an async queue would silently lose
    /// the most diagnostic lines (the ones right before the death).
    static func record(_ message: String, category: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8), let fileURL = logFileURL() else { return }
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func logFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)?
            .appendingPathComponent("clip-diagnostics.log")
    }
}
