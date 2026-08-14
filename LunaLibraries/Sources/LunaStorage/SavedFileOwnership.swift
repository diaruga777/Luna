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
    /// `Articles/img-<UUID>.<ext>` — a downloaded article image. A live copy can
    /// be shared, but a path queued for deletion is never reused.
    case image
    /// `Preloads/page-<UUID>.json` — one preloaded page's cached article. A page
    /// that caches no content reserves this name without writing it, so every
    /// page is counted the same way.
    case preloadPage
}

/// A path the ownership tables may hold, and only this file can make one — the
/// queue at the far end of a released path unlinks whatever it is handed.
struct OwnedFilePath: Hashable {
    let relativePath: String

    init(_ relativePath: String) { self.relativePath = relativePath }

    /// The file's own name, without the directory the ownership tables record it
    /// under. Every constructor builds the path from a plain name, so this is the
    /// name that went in.
    var lastPathComponent: String {
        String(relativePath.split(separator: "/").last ?? "")
    }
}

/// The writes to `files` / `file_refs` / `file_holders` / `preload_pages`: which
/// saves and preloaded pages hold which files on disk.
///
/// Every call here runs INSIDE the caller's transaction, alongside the row write
/// that made the artifact set what it is. That is the point of moving ownership
/// into SQL: a save's row and the files it holds commit together, so a crash
/// cannot leave one without the other. Freeing a file is not done here at all —
/// the schema's triggers do it, and `PendingDeleteReaper` performs the unlink.
enum SavedFileOwnership {

    // MARK: - Paths

    /// The container-relative path of a file in `Articles/`, or nil when the name
    /// is not a plain file name.
    static func articlesPath(_ fileName: String) -> OwnedFilePath? {
        path("Articles", fileName)
    }

    /// The container-relative path of a file in `OriginalArchives/`.
    static func archivesPath(_ fileName: String) -> OwnedFilePath? {
        path("OriginalArchives", fileName)
    }

    /// The path of a downloaded article image, or nil for any name the image
    /// downloader would not have produced. Image names come out of article
    /// content, which came off the web, so they must look like the downloader's
    /// own (`img-…`). Image names are generated independently of their source URL.
    static func imagePath(_ fileName: String) -> OwnedFilePath? {
        guard fileName.hasPrefix("img-") else { return nil }
        return articlesPath(fileName)
    }

    /// The path of a preloaded page's file, or nil for a name the preload cache
    /// would not have produced. The cache's own index is excluded by name: a
    /// corrupt entry must not be able to queue `preloads.json` for deletion.
    static func preloadsPath(_ fileName: String) -> OwnedFilePath? {
        guard fileName != PreloadStore.indexFileName else { return nil }
        return path("Preloads", fileName)
    }

    /// A fresh name for a preloaded page. Independent of the page's URL, because
    /// the path this becomes is retired the moment the page is released and a
    /// later preload of the same URL has to land somewhere else.
    static func newPreloadPageName() -> String { "page-\(UUID().uuidString).json" }

    /// A file name is only ever a name: one carrying a path separator produces
    /// no path at all.
    private static func path(_ directory: String, _ fileName: String) -> OwnedFilePath? {
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent
        else { return nil }
        return OwnedFilePath("\(directory)/\(fileName)")
    }

    /// A path read back out of `files`, which one of the constructors above put
    /// there in the first place.
    private static func recorded(_ relativePath: String) -> OwnedFilePath {
        OwnedFilePath(relativePath)
    }

    /// The artifacts a save's own columns name, with the kind each one is.
    ///
    /// Read at every row write, so a file whose name arrives through a column —
    /// a thumbnail the platform ingestor wrote, a product photo the price
    /// ingestor wrote — is owned from the moment the column points at it, without
    /// every writer having to remember.
    static func columnDerivedPaths(of item: SavedItem) -> [(OwnedFileKind, OwnedFilePath)] {
        var paths: [(OwnedFileKind, OwnedFilePath)] = []
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
    static func readerSourcePath(for itemID: UUID) -> OwnedFilePath? {
        archivesPath("\(itemID.uuidString)-reader-source.html")
    }

    // MARK: - Save ownership

    /// Makes `saveID`'s holdings in `kinds` exactly `artifacts`. Edges it held in
    /// those kinds and no longer wants are dropped — which is what frees a
    /// replaced thumbnail or an image an edited article no longer shows. Kinds
    /// outside the set are left alone, so a thumbnail write does not touch the
    /// save's images.
    static func reconcile(
        saveID: UUID, kinds: Set<OwnedFileKind>, artifacts: [(OwnedFileKind, OwnedFilePath)],
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

    /// Whether `path` can be claimed in this transaction. A path that has reached
    /// `retired_paths` is a permanent tombstone: it must never gain another owner,
    /// even after the reaper has cleared its queue row.
    static func canAttach(path: OwnedFilePath, in db: SavesDatabase) throws -> Bool {
        try db.scalarInt(
            "SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM retired_paths WHERE relative_path = ?)",
            { try $0.bind(1, path.relativePath) }
        ) != nil
    }

    /// The paths `saveID` holds in `kinds`.
    static func heldPaths(
        saveID: UUID, kinds: Set<OwnedFileKind>, in db: SavesDatabase
    ) throws -> [OwnedFilePath] {
        let list = kinds.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var paths: [OwnedFilePath] = []
        try db.query(
            """
            SELECT files.relative_path FROM file_refs
            JOIN files ON files.id = file_refs.file_id
            WHERE file_refs.save_id = ? AND files.kind IN (\(list))
            """,
            { try $0.bind(1, uuid: saveID) }
        ) { row in
            if let path = row.string(0) { paths.append(recorded(path)) }
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
        path: OwnedFilePath, kind: OwnedFileKind, to saveID: UUID, in db: SavesDatabase
    ) throws {
        try db.run(
            """
            INSERT INTO files (relative_path, kind)
                SELECT ?, ? WHERE EXISTS (SELECT 1 FROM saves WHERE id = ?)
                    AND NOT EXISTS (
                        SELECT 1 FROM retired_paths WHERE relative_path = ?
                    )
                ON CONFLICT (relative_path) DO NOTHING
            """
        ) {
            try $0.bind(1, path.relativePath)
            try $0.bind(2, kind.rawValue)
            try $0.bind(3, uuid: saveID)
            try $0.bind(4, path.relativePath)
        }
        try db.run(
            """
            INSERT OR IGNORE INTO file_refs (file_id, save_id)
                SELECT files.id, saves.id FROM files, saves
                WHERE files.relative_path = ? AND saves.id = ?
                    AND NOT EXISTS (
                        SELECT 1 FROM retired_paths
                        WHERE relative_path = files.relative_path
                    )
            """
        ) {
            try $0.bind(1, path.relativePath)
            try $0.bind(2, uuid: saveID)
        }
    }

    /// Records the current live copy for an image URL. A concurrent downloader
    /// may have registered another live copy first; keeping that mapping is fine
    /// because both paths are independently owned and neither can be resurrected.
    static func registerImageSource(
        _ sourceURL: String, for path: OwnedFilePath, in db: SavesDatabase
    ) throws {
        try db.run(
            """
            INSERT OR IGNORE INTO image_sources (source_url, file_id)
                SELECT ?, id FROM files
                WHERE relative_path = ?
                    AND NOT EXISTS (
                        SELECT 1 FROM retired_paths
                        WHERE relative_path = files.relative_path
                    )
            """
        ) {
            try $0.bind(1, sourceURL)
            try $0.bind(2, path.relativePath)
        }
    }

    /// Drops one save's claim on `path`. When it was the last claim the schema's
    /// trigger queues the file for deletion.
    static func detach(path: OwnedFilePath, from saveID: UUID, in db: SavesDatabase) throws {
        try db.run(
            """
            DELETE FROM file_refs WHERE save_id = ?
                AND file_id IN (SELECT id FROM files WHERE relative_path = ?)
            """
        ) {
            try $0.bind(1, uuid: saveID)
            try $0.bind(2, path.relativePath)
        }
    }

    // MARK: - Holder ownership (preloaded pages)

    /// Makes `holderKey`'s holdings exactly `paths`. The holder is a preloaded
    /// page's URL hash; its files are always downloaded images.
    static func reconcileHolder(
        holderKey: String, paths: [OwnedFilePath], in db: SavesDatabase
    ) throws {
        let wanted = Set(paths)
        for held in try holderPaths(holderKey: holderKey, in: db) where !wanted.contains(held) {
            try detachHolder(path: held, holderKey: holderKey, in: db)
        }
        for path in wanted {
            try attachHolder(path: path, kind: .image, holderKey: holderKey, in: db)
        }
    }

    /// Records that `holderKey` holds `path`, inserting the file row when it is
    /// new. Like `attach`, a retired path is refused rather than resurrected.
    static func attachHolder(
        path: OwnedFilePath, kind: OwnedFileKind, holderKey: String, in db: SavesDatabase
    ) throws {
        try insertFile(path: path, kind: kind, in: db)
        try db.run(
            """
            INSERT OR IGNORE INTO file_holders (file_id, holder_key)
                SELECT id, ? FROM files WHERE relative_path = ?
                    AND NOT EXISTS (
                        SELECT 1 FROM retired_paths
                        WHERE relative_path = files.relative_path
                    )
            """
        ) {
            try $0.bind(1, holderKey)
            try $0.bind(2, path.relativePath)
        }
    }

    /// Drops every claim `holderKey` holds — a preloaded page leaving the cache.
    static func releaseHolder(holderKey: String, in db: SavesDatabase) throws {
        try db.run("DELETE FROM file_holders WHERE holder_key = ?") { try $0.bind(1, holderKey) }
    }

    static func holderPaths(holderKey: String, in db: SavesDatabase) throws -> [OwnedFilePath] {
        var paths: [OwnedFilePath] = []
        try db.query(
            """
            SELECT files.relative_path FROM file_holders
            JOIN files ON files.id = file_holders.file_id
            WHERE file_holders.holder_key = ?
            """,
            { try $0.bind(1, holderKey) }
        ) { row in
            if let path = row.string(0) { paths.append(recorded(path)) }
        }
        return paths
    }

    private static func detachHolder(
        path: OwnedFilePath, holderKey: String, in db: SavesDatabase
    ) throws {
        try db.run(
            """
            DELETE FROM file_holders WHERE holder_key = ?
                AND file_id IN (SELECT id FROM files WHERE relative_path = ?)
            """
        ) {
            try $0.bind(1, holderKey)
            try $0.bind(2, path.relativePath)
        }
    }

    // MARK: - Preloaded pages

    /// The live file of the preloaded page `urlKey`, or nil when the cache holds
    /// no page for it.
    static func preloadPagePath(urlKey: String, in db: SavesDatabase) throws -> OwnedFilePath? {
        var path: String?
        try db.query(
            """
            SELECT files.relative_path FROM preload_pages
            JOIN files ON files.id = preload_pages.file_id
            WHERE preload_pages.url_key = ?
            """,
            { try $0.bind(1, urlKey) }
        ) { row in path = row.string(0) }
        return path.map(recorded)
    }

    /// Points `urlKey` at `path`, inserting the file row when it is new.
    ///
    /// The caller must take an ownership edge on the same path in this
    /// transaction: a `files` row nothing holds is never freed, because the
    /// triggers that free one fire on an edge being deleted.
    static func registerPreloadPage(
        urlKey: String, path: OwnedFilePath, in db: SavesDatabase
    ) throws {
        try insertFile(path: path, kind: .preloadPage, in: db)
        try db.run(
            """
            INSERT OR IGNORE INTO preload_pages (url_key, file_id)
                SELECT ?, id FROM files
                WHERE relative_path = ?
                    AND NOT EXISTS (
                        SELECT 1 FROM retired_paths
                        WHERE relative_path = files.relative_path
                    )
            """
        ) {
            try $0.bind(1, urlKey)
            try $0.bind(2, path.relativePath)
        }
    }

    /// Drops one save's claim on every page it holds, leaving its other artifacts
    /// alone. The mapping table is what scopes the delete to preloaded pages.
    static func detachPreloadPages(saveID: UUID, in db: SavesDatabase) throws {
        try db.run(
            """
            DELETE FROM file_refs WHERE save_id = ?
                AND file_id IN (SELECT file_id FROM preload_pages)
            """
        ) { try $0.bind(1, uuid: saveID) }
    }

    /// The same, for an owner that is not a save. Its image claims, which are
    /// keyed by page rather than by owner, are released separately.
    static func detachPreloadPages(holderKey: String, in db: SavesDatabase) throws {
        try db.run(
            """
            DELETE FROM file_holders WHERE holder_key = ?
                AND file_id IN (SELECT file_id FROM preload_pages)
            """
        ) { try $0.bind(1, holderKey) }
    }

    // MARK: - Files

    private static func insertFile(
        path: OwnedFilePath, kind: OwnedFileKind, in db: SavesDatabase
    ) throws {
        try db.run(
            """
            INSERT INTO files (relative_path, kind)
                SELECT ?, ? WHERE NOT EXISTS (
                    SELECT 1 FROM retired_paths WHERE relative_path = ?
                )
                ON CONFLICT (relative_path) DO NOTHING
            """
        ) {
            try $0.bind(1, path.relativePath)
            try $0.bind(2, kind.rawValue)
            try $0.bind(3, path.relativePath)
        }
    }
}
