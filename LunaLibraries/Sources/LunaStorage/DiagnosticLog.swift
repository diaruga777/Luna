//
//  DiagnosticLog.swift
//  Luna
//

import Foundation

/// Identifies this install for the export header. The mail layer lives
/// above LunaStorage, so the app shell installs the answer at launch, via
/// `DiagnosticLog.exportIdentityProvider`.
public protocol DiagnosticExportIdentityProviding {
    /// The connected sending account, or a placeholder when there is none.
    var exportIdentity: String { get }
}

/// Persistent, shareable diagnostic log.
///
/// Mirrors key runtime events (push registration, CloudKit subscription,
/// inbox drains, sends, notification auth) to a plain-text file in the App
/// Group container, so they can be read back and shared straight from
/// in-app Settings. This stays independent of Console.app and the unified
/// log's archive format, which can't be read across macOS/iOS-beta version
/// gaps, and it survives relaunches and background (push / bg-refresh)
/// wakeups.
///
/// Appends are serialized on a private queue; the file is trimmed to its most
/// recent half once it exceeds `maxBytes` so it can't grow without bound.
public final class DiagnosticLog: @unchecked Sendable {

    public static let shared = DiagnosticLog()

    private let queue = DispatchQueue(label: "com.hsanabria.luna.diagnosticlog")
    private let fileURL: URL
    private let maxBytes: Int
    private let timestampFormatter: ISO8601DateFormatter

    /// `containerURL` overrides the App Group container for tests.
    /// `maxBytes` caps the on-disk size.
    public init(containerURL: URL? = nil, maxBytes: Int = 1_000_000) {
        let directory = containerURL
            ?? FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SavesStore.appGroupID)
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
            // Format on the queue. ISO8601DateFormatter is not safe to
            // share across the threads that call `record`.
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
        BackupPolicy.excludeFromBackups(destination)
        return destination
    }

    public func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Private

    private func append(_ line: String) {
        // The write and the trim both go through SharedDiagnosticLog's file
        // lock. Both loggers append to the same file in this process, and an
        // unsynchronized trim (read, then atomic rewrite) could drop a line
        // the other logger appended in between.
        SharedDiagnosticLog.appendLine(line, to: fileURL)
        trimIfNeeded()
    }

    /// Keeps the file bounded. Once it passes `maxBytes`, this rewrites the
    /// file with only its most recent `maxBytes / 2` worth of complete lines.
    private func trimIfNeeded() {
        SharedDiagnosticLog.withFileLock {
            guard let size = try? FileManager.default.attributesOfItem(
                atPath: fileURL.path)[.size] as? Int, size > maxBytes,
                  let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            else { return }
            let keep = existing.suffix(maxBytes / 2)
            // Drop the first (likely partial) line so the file starts cleanly.
            let trimmed = keep.drop { $0 != "\n" }.dropFirst()
            try? ("…(trimmed)\n" + trimmed).write(to: fileURL, atomically: true, encoding: .utf8)
            BackupPolicy.excludeFromBackups(fileURL)
        }
    }

    /// Messaging-identity context for the export header, installed by the
    /// main app at launch. The mail layer lives above storage, so this is
    /// threaded in rather than referenced directly. Nil in contexts that
    /// don't install one, such as extensions and tests, where the header
    /// prints the placeholder below.
    public static var exportIdentityProvider: (any DiagnosticExportIdentityProviding)?

    /// Device, build, and identity context, prepended to exports.
    private func header() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let identity = Self.exportIdentityProvider?.exportIdentity ?? "none"
        let exportedAt = ISO8601DateFormatter().string(from: Date())
        return """
        Luna diagnostics
        App: \(version) (\(build))
        OS: \(systemDescription())
        Identity UUID: \(identity)
        Exported: \(exportedAt)
        ----------------------------------------

        """
    }

    private func systemDescription() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}
