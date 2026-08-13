//
//  PendingDeleteReaper.swift
//  LunaStorage
//

import Foundation

/// Unlinks the files the database has finished with.
///
/// A file system cannot join a transaction, so releasing an artifact is two
/// commits: the transaction that drops the last ownership edge queues the path in
/// `pending_deletes` (a trigger does it), and this runs afterwards to unlink the
/// file and clear the row. Nothing is lost to a crash in between — the row is
/// still there at the next launch, and the work is the same work.
///
/// **Any process may run it, at any time, as often as it likes.** It is called
/// after the mutations that queue something, at launch, and when an app
/// backgrounds. Each path is handled in its own transaction, which is what makes
/// two processes reaping at once harmless: the second finds the row gone.
///
/// The re-reference check inside that transaction is the race this exists to
/// close. Between the commit that queued a path and the unlink, another process
/// can save an article that references the same image; the insert rescues the path
/// out of the queue, but only a check taken under the write lock can be sure it
/// happened BEFORE the unlink rather than during it.
enum PendingDeleteReaper {

    /// Failures tolerated in silence. A path failing this often is not a transient
    /// busy file — something about it will not delete — so it earns a log line,
    /// once, and keeps its row.
    static let attemptsBeforeLogging = 5

    /// Unlinks everything queued. Returns the number of paths it cleared, which is
    /// what a test asserts on.
    @discardableResult
    static func reap(
        in database: SavesDatabase, containerURL: URL,
        fileManager: FileManager = .default
    ) -> Int {
        var cleared = 0
        for path in queuedPaths(in: database) {
            if reap(path: path, in: database, containerURL: containerURL, fileManager: fileManager) {
                cleared += 1
            }
        }
        return cleared
    }

    /// The whole queue. Read in one go rather than held open: each path then takes
    /// the write lock only for as long as its own unlink.
    private static func queuedPaths(in database: SavesDatabase) -> [String] {
        let paths: [String]? = try? database.perform { db in
            var paths: [String] = []
            try db.query("SELECT relative_path FROM pending_deletes") { row in
                if let path = row.string(0) { paths.append(path) }
            }
            return paths
        }
        return paths ?? []
    }

    /// One path: unlink it and clear its row, or record the attempt. True when the
    /// row is gone afterwards.
    ///
    /// The unlink happens INSIDE the transaction on purpose. Holding the write lock
    /// across it is what stops another process from taking a reference to the file
    /// between this check and the delete — and `removeItem` on a path that is
    /// already gone is a success here, so a retried transaction body is safe.
    private static func reap(
        path: String, in database: SavesDatabase, containerURL: URL, fileManager: FileManager
    ) -> Bool {
        let cleared: Bool? = try? database.transaction { db in
            var queued = false
            try db.query(
                "SELECT 1 FROM pending_deletes WHERE relative_path = ?",
                { try $0.bind(1, path) }
            ) { _ in queued = true }
            guard queued else { return false }

            // A `files` row for this path means someone owns the file again. The
            // rescue trigger normally clears the queue entry on the spot; clearing
            // it here covers a row left behind by a process that crashed between
            // the two.
            var owned = false
            try db.query(
                "SELECT 1 FROM files WHERE relative_path = ?",
                { try $0.bind(1, path) }
            ) { _ in owned = true }
            if owned {
                try clear(path: path, in: db)
                return true
            }

            guard let url = resolvedURL(forRelativePath: path, containerURL: containerURL) else {
                // A path this cannot resolve to somewhere inside the container is
                // one nothing should be deleting. Drop the row rather than retry
                // it forever.
                try clear(path: path, in: db)
                return true
            }
            guard fileManager.fileExists(atPath: url.path) else {
                try clear(path: path, in: db)
                return true
            }
            do {
                try fileManager.removeItem(at: url)
                try clear(path: path, in: db)
                return true
            } catch {
                try recordAttempt(path: path, error: error, in: db)
                return false
            }
        }
        return cleared ?? false
    }

    private static func clear(path: String, in db: SavesDatabase) throws {
        try db.run("DELETE FROM pending_deletes WHERE relative_path = ?") { try $0.bind(1, path) }
    }

    private static func recordAttempt(path: String, error: Error, in db: SavesDatabase) throws {
        try db.run(
            "UPDATE pending_deletes SET attempts = attempts + 1 WHERE relative_path = ?"
        ) { try $0.bind(1, path) }
        let attempts = try db.scalarInt(
            "SELECT attempts FROM pending_deletes WHERE relative_path = ?",
            { try $0.bind(1, path) }) ?? 0
        if attempts == Int64(attemptsBeforeLogging) {
            SharedDiagnosticLog.record(
                "pending delete stuck after \(attempts) attempts: \(path) — \(error)",
                category: "store")
        }
    }

    /// Where `relativePath` is on disk, or nil when it does not name a file inside
    /// the container. The queue is written by triggers from paths Swift recorded,
    /// but the file names inside those paths came off the web, so the last thing
    /// before an unlink checks the result is somewhere it is allowed to delete.
    static func resolvedURL(forRelativePath relativePath: String, containerURL: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("..")
        else { return nil }
        let root = containerURL.standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), url.path != root.path else { return nil }
        return url
    }
}
