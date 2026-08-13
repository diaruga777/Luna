//
//  SavedFileOwnership.swift
//  LunaStorage
//

import Foundation
import LunaModels

/// What an owned file IS, recorded on the `files` row.
///
/// The kind is what lets one save reconcile a single sort of artifact without
/// disturbing the others: writing a thumbnail must not look like a claim that the
/// save owns no images.
enum OwnedFileKind: String {
    /// `Articles/<id>.json` — the parsed article the reader renders.
    case content
    /// `OriginalArchives/<id>.webarchive` — the captured original page.
    case archive
    /// `OriginalArchives/<id>-reader-source.html` — the HTML the archive is
    /// captured FROM, held only until it has been.
    case readerSource
    /// `Articles/<id>-source.<ext>` — an imported document, copied in whole.
    case document
    /// `Articles/<id>-thumb.jpg` — the card's artwork.
    case thumbnail
    /// `Articles/<id>-product.jpg` — a tracked product's photo.
    case productImage
    /// `Articles/img-<hash>.<ext>` — a downloaded article image, shared by every
    /// save and preloaded page whose content references the same source URL.
    case image
}

/// The writes to `files` / `file_refs` / `file_holders`: which saves and preloaded
/// pages hold which files on disk.
///
/// Every call here runs INSIDE the caller's transaction, alongside the row write
/// that made the artifact set what it is. That is the point of moving ownership
/// into SQL: a save's row and the files it holds commit together, so a crash
/// cannot leave one without the other. Freeing a file is not done here at all —
/// the schema's triggers do it, and `PendingDeleteReaper` performs the unlink.
///
/// A file name is only ever a name. Nothing here accepts a name carrying a path
/// separator, and an `image` must additionally look like one the downloader wrote
/// (`img-…`): the names for those come out of article content, which came off the
/// web, and the queue at the far end of this deletes what it is handed.
enum SavedFileOwnership {

    // MARK: - Paths

    /// The container-relative path of a file in `Articles/`, or nil when the name
    /// is not a plain file name.
    static func articlesPath(_ fileName: String) -> String? {
        path("Articles", fileName)
    }

    /// The container-relative path of a file in `OriginalArchives/`.
    static func archivesPath(_ fileName: String) -> String? {
        path("OriginalArchives", fileName)
    }

    /// The path of a downloaded article image, or nil for any name the image
    /// downloader would not have produced.
    static func imagePath(_ fileName: String) -> String? {
        guard fileName.hasPrefix("img-") else { return nil }
        return articlesPath(fileName)
    }

    private static func path(_ directory: String, _ fileName: String) -> String? {
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent
        else { return nil }
        return "\(directory)/\(fileName)"
    }

    /// The artifacts a save's own columns name, with the kind each one is.
    ///
    /// Read at every row write, so a file whose name arrives through a column —
    /// a thumbnail the platform ingestor wrote, a product photo the price
    /// ingestor wrote — is owned from the moment the column points at it, without
    /// every writer having to remember.
    static func columnDerivedPaths(of item: ReadingListItem) -> [(OwnedFileKind, String)] {
        var paths: [(OwnedFileKind, String)] = []
        if let name = item.contentFileName, let path = articlesPath(name) {
            paths.append((.content, path))
        }
        if let name = item.originalArchiveFileName, let path = archivesPath(name) {
            paths.append((.archive, path))
        }
        if let ext = item.sanitizedDocumentType,
           let path = articlesPath("\(item.id.uuidString)-source.\(ext)") {
            paths.append((.document, path))
        }
        if let name = item.thumbnailFileName, let path = articlesPath(name) {
            paths.append((.thumbnail, path))
        }
        if let name = item.priceTracker?.imageFileName, let path = articlesPath(name) {
            paths.append((.productImage, path))
        }
        return paths
    }

    /// The path of the HTML an archive is captured from. Named from the id rather
    /// than a column, so `saveReaderSourceHTML` and `removeReaderSourceHTML` take
    /// and release this edge themselves.
    static func readerSourcePath(for itemID: UUID) -> String? {
        archivesPath("\(itemID.uuidString)-reader-source.html")
    }

    // MARK: - Save ownership

    /// Makes `saveID`'s holdings in `kinds` exactly `artifacts`. Edges it held in
    /// those kinds and no longer wants are dropped — which is what frees a
    /// replaced thumbnail or an image an edited article no longer shows. Kinds
    /// outside the set are left alone, so a thumbnail write does not touch the
    /// save's images.
    static func reconcile(
        saveID: UUID, kinds: Set<OwnedFileKind>, artifacts: [(OwnedFileKind, String)],
        in db: SavesDatabase
    ) throws {
        let wanted = Set(artifacts.map(\.1))
        for held in try heldPaths(saveID: saveID, kinds: kinds, in: db)
        where !wanted.contains(held) {
            try detach(path: held, from: saveID, in: db)
        }
        for (kind, path) in artifacts {
            try attach(path: path, kind: kind, to: saveID, in: db)
        }
    }

    /// The paths `saveID` holds in `kinds`.
    static func heldPaths(
        saveID: UUID, kinds: Set<OwnedFileKind>, in db: SavesDatabase
    ) throws -> [String] {
        let list = kinds.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var paths: [String] = []
        try db.query(
            """
            SELECT files.relative_path FROM file_refs
            JOIN files ON files.id = file_refs.file_id
            WHERE file_refs.save_id = ? AND files.kind IN (\(list))
            """,
            { try $0.bind(1, uuid: saveID) }
        ) { row in
            if let path = row.string(0) { paths.append(path) }
        }
        return paths
    }

    /// Records that `saveID` holds `path`. `kind` is written only when the file
    /// row is new: a file already known as an image stays one.
    ///
    /// BOTH statements are conditional on the save existing, so a save that is not
    /// there records nothing at all. `OR IGNORE` would not cover the edge — SQLite
    /// raises a foreign-key violation through it — and a `files` row without the
    /// edge that was meant to follow it would be exactly the zero-holder row the
    /// schema's triggers exist to prevent.
    static func attach(
        path: String, kind: OwnedFileKind?, to saveID: UUID, in db: SavesDatabase
    ) throws {
        try db.run(
            """
            INSERT INTO files (relative_path, kind)
                SELECT ?, ? WHERE EXISTS (SELECT 1 FROM saves WHERE id = ?)
                ON CONFLICT (relative_path) DO NOTHING
            """
        ) {
            try $0.bind(1, path)
            try $0.bind(2, kind?.rawValue)
            try $0.bind(3, uuid: saveID)
        }
        try db.run(
            """
            INSERT OR IGNORE INTO file_refs (file_id, save_id)
                SELECT files.id, saves.id FROM files, saves
                WHERE files.relative_path = ? AND saves.id = ?
            """
        ) {
            try $0.bind(1, path)
            try $0.bind(2, uuid: saveID)
        }
    }

    /// Drops one save's claim on `path`. When it was the last claim the schema's
    /// trigger queues the file for deletion.
    static func detach(path: String, from saveID: UUID, in db: SavesDatabase) throws {
        try db.run(
            """
            DELETE FROM file_refs WHERE save_id = ?
                AND file_id IN (SELECT id FROM files WHERE relative_path = ?)
            """
        ) {
            try $0.bind(1, uuid: saveID)
            try $0.bind(2, path)
        }
    }

    // MARK: - Holder ownership (preloaded pages)

    /// Makes `holderKey`'s holdings exactly `paths`. The holder is a preloaded
    /// page's URL hash; its files are always downloaded images.
    static func reconcileHolder(
        holderKey: String, paths: [String], in db: SavesDatabase
    ) throws {
        let wanted = Set(paths)
        for held in try holderPaths(holderKey: holderKey, in: db) where !wanted.contains(held) {
            try detachHolder(path: held, holderKey: holderKey, in: db)
        }
        for path in wanted {
            try insertFile(path: path, kind: .image, in: db)
            try db.run(
                """
                INSERT OR IGNORE INTO file_holders (file_id, holder_key)
                    SELECT id, ? FROM files WHERE relative_path = ?
                """
            ) {
                try $0.bind(1, holderKey)
                try $0.bind(2, path)
            }
        }
    }

    /// Drops every claim `holderKey` holds — a preloaded page leaving the cache.
    static func releaseHolder(holderKey: String, in db: SavesDatabase) throws {
        try db.run("DELETE FROM file_holders WHERE holder_key = ?") { try $0.bind(1, holderKey) }
    }

    static func holderPaths(holderKey: String, in db: SavesDatabase) throws -> [String] {
        var paths: [String] = []
        try db.query(
            """
            SELECT files.relative_path FROM file_holders
            JOIN files ON files.id = file_holders.file_id
            WHERE file_holders.holder_key = ?
            """,
            { try $0.bind(1, holderKey) }
        ) { row in
            if let path = row.string(0) { paths.append(path) }
        }
        return paths
    }

    private static func detachHolder(
        path: String, holderKey: String, in db: SavesDatabase
    ) throws {
        try db.run(
            """
            DELETE FROM file_holders WHERE holder_key = ?
                AND file_id IN (SELECT id FROM files WHERE relative_path = ?)
            """
        ) {
            try $0.bind(1, holderKey)
            try $0.bind(2, path)
        }
    }

    // MARK: - Files

    private static func insertFile(
        path: String, kind: OwnedFileKind?, in db: SavesDatabase
    ) throws {
        try db.run(
            """
            INSERT INTO files (relative_path, kind) VALUES (?, ?)
                ON CONFLICT (relative_path) DO NOTHING
            """
        ) {
            try $0.bind(1, path)
            try $0.bind(2, kind?.rawValue)
        }
    }
}
