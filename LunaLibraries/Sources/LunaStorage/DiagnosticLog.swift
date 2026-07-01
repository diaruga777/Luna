//
//  DiagnosticLog.swift
//  Luna
//

import Foundation

/// Persistent, shareable diagnostic log.
///
/// Mirrors key runtime events (push registration, CloudKit subscription, inbox
/// drains, sends, notification auth) to a plain-text file in the App Group
/// container so they can be read back and shared straight from in-app Settings.
/// This is independent of Console.app and the unified log's archive format —
/// which can't be read across macOS/iOS-beta version gaps — and it survives
/// relaunches and background (push / bg-refresh) wakeups.
public protocol DiagnosticLogging: Sendable {
    /// Appends one timestamped line tagged with `category`.
    func record(_ message: String, category: String)
    /// The full accumulated log text, oldest line first.
    func contents() -> String
    /// Writes a header + the full log to a shareable `.txt` file, returning it.
    func exportFile() throws -> URL
    /// Erases the log file.
    func clear()
}

/// File-backed `DiagnosticLogging`. Appends are serialized on a private queue;
/// the file is trimmed to its most recent half once it exceeds `maxBytes` so it
/// can't grow without bound.
public final class DiagnosticLog: DiagnosticLogging, @unchecked Sendable {

    public static let shared = DiagnosticLog()

    private let queue = DispatchQueue(label: "com.hsanabria.luna.diagnosticlog")
    private let fileURL: URL
    private let maxBytes: Int
    private let timestampFormatter: ISO8601DateFormatter

    /// `containerURL` overrides the App Group container (tests); `maxBytes`
    /// caps the on-disk size.
    public init(containerURL: URL? = nil, maxBytes: Int = 1_000_000) {
        let directory = containerURL
            ?? FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.fileURL = directory.appendingPathComponent("clip-diagnostics.log")
        self.maxBytes = maxBytes
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = formatter
    }

    public func record(_ message: String, category: String) {
        let date = Date()
        queue.async { [weak self] in
            guard let self else { return }
            // Format on the queue: ISO8601DateFormatter isn't safe to share
            // across the threads `record` may be called from.
            let line = "\(self.timestampFormatter.string(from: date)) [\(category)] \(message)\n"
            self.append(line)
        }
    }

    public func contents() -> String {
        queue.sync {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }

    public func exportFile() throws -> URL {
        let body = contents()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-diagnostics.txt")
        try? FileManager.default.removeItem(at: destination)
        try (header() + body).write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    public func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Private

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        trimIfNeeded()
    }

    /// Keeps the file bounded: once it passes `maxBytes`, rewrite it with only
    /// its most recent `maxBytes / 2` worth of complete lines.
    private func trimIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path)[.size] as? Int, size > maxBytes,
              let existing = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return }
        let keep = existing.suffix(maxBytes / 2)
        // Drop the first (likely partial) line so the file starts cleanly.
        let trimmed = keep.drop { $0 != "\n" }.dropFirst()
        try? ("…(trimmed)\n" + trimmed).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Messaging-identity + CloudKit-container context for the export header,
    /// injected by the main app at launch (the social layer lives above storage,
    /// so it's threaded in rather than referenced directly). Default to placeholders
    /// in contexts that don't set them (extensions, tests).
    public static var exportIdentityProvider: () -> String = { "none" }
    public static var exportCloudKitContainer: () -> String = { "—" }

    /// Device, build, and identity context, prepended to exports.
    private func header() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let identity = Self.exportIdentityProvider()
        let exportedAt = ISO8601DateFormatter().string(from: Date())
        return """
        Luna diagnostics
        App: \(version) (\(build))
        OS: \(systemDescription())
        Identity UUID: \(identity)
        CloudKit container: \(Self.exportCloudKitContainer()) (public DB)
        Exported: \(exportedAt)
        ----------------------------------------

        """
    }

    private func systemDescription() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}
