//
//  SavesSchema.swift
//  LunaStorage
//

import Foundation

/// The saves database's tables and indexes, in one place.
///
/// One row per save, with the two nested structures the model carries — the
/// per-destination send bookkeeping and the price tracker's stores and price
/// points — as real child tables under `ON DELETE CASCADE`. Every field is a
/// typed column: there is no payload blob to decode, so a reader never has to
/// understand a writer's version of a struct to read a column it does know.
///
/// **No CHECK constraint on the enum columns.** Four apps and their extensions
/// share this one file and update independently, so a newer sibling WILL write a
/// case an older binary has never heard of. A constraint would turn that into a
/// failed insert for the newer app or a failed read for the older one; storing
/// raw TEXT and mapping an unrecognised value to a safe default in Swift (see
/// `SaveRow`) keeps both running. Closing a value set is a `user_version` bump
/// and a migration, not a constraint added quietly.
///
/// **Dates are REAL** (seconds since the reference date) so a value round-trips
/// to the same `Date` it was written from — items compare by value and the decks
/// sort on these. **Prices are TEXT** so a `Decimal` keeps its exact digits.
///
/// The file-ownership tables (`files` / `file_refs` / `file_holders` /
/// `image_sources` / `preload_pages` / `pending_deletes` / `retired_paths`) own
/// the FILES beside the database, with triggers that keep them honest. See
/// `SavedFileOwnership` for the writes and `PendingDeleteReaper` for the unlink.
enum SavesSchema {

    /// Creates the tables and indexes if they are absent, and stamps the schema
    /// revision. Idempotent: every process runs it at open, and the first one to
    /// reach a brand-new file is the one that builds it.
    ///
    /// A file already stamped NEWER than this binary is left at its own version —
    /// a sibling app that has been updated first owns that stamp, and every table
    /// this binary needs is there (they only ever gain columns).
    static func create(in database: SavesDatabase) throws {
        // Every process runs this at open, so on a fresh file they all run it at
        // once — the loser of that race is made to wait rather than left with no
        // database (see `SavesDatabase.retryingWhileBusy`).
        try database.retryingWhileBusy {
            try database.execute("BEGIN IMMEDIATE")
            do {
                let existing = try userVersion(in: database)
                try database.execute(tables)
                try database.execute(indexes)
                // A queue row created by an older build is already a permanent
                // retirement. Preserve that fact before a reaper clears it.
                try database.execute("""
                    INSERT OR IGNORE INTO retired_paths (relative_path, retired_at)
                        SELECT relative_path, enqueued_at FROM pending_deletes
                    """)
                // Version 2 created these rescue triggers. They must be dropped
                // explicitly because CREATE TRIGGER IF NOT EXISTS cannot replace
                // an already-installed trigger on an existing shared database.
                try database.execute("DROP TRIGGER IF EXISTS file_refs_rescue")
                try database.execute("DROP TRIGGER IF EXISTS file_holders_rescue")
                try database.execute(triggers)
                if existing > 0 && existing < 2 {
                    try backfillFileOwnership(in: database)
                }
                // Version 5 added `preload_pages`, and it starts empty. What fills
                // it for an existing install is the preload cache's own index,
                // which this has no business reading — see
                // `PreloadStore.migrateLegacyOwnersIfNeeded`.
                if existing < SavesDatabase.schemaVersion {
                    try database.execute("PRAGMA user_version = \(SavesDatabase.schemaVersion)")
                }
                try database.execute("COMMIT")
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Records the ownership edges for saves written before `files`/`file_refs`
    /// existed, so deleting one of them still frees its artifacts.
    ///
    /// It recovers what a COLUMN names: the content JSON, the captured archive, the
    /// thumbnail, the product photo. The two artifacts whose names are not in a
    /// column are left — a downloaded image (named inside the content JSON) and an
    /// imported document (named from the id and the document type) — so those stay
    /// on disk until the save writes its content again.
    private static func backfillFileOwnership(in database: SavesDatabase) throws {
        // (table, the id column pointing at `saves`, the file-name column, the
        // directory the name is relative to, the kind recorded). A name holding a
        // path separator is skipped: `SavedFileOwnership` refuses to record one,
        // and a stored row must not smuggle past that.
        let sources: [(String, String, String, String, OwnedFileKind)] = [
            ("saves", "id", "content_file_name", "Articles", .content),
            ("saves", "id", "original_archive_file_name", "OriginalArchives", .archive),
            ("saves", "id", "thumbnail_file_name", "Articles", .thumbnail),
            ("price_trackers", "save_id", "image_file_name", "Articles", .productImage),
        ]
        for (table, idColumn, nameColumn, directory, kind) in sources {
            let path = "'\(directory)/' || \(nameColumn)"
            try database.execute("""
                INSERT OR IGNORE INTO files (relative_path, kind)
                    SELECT \(path), '\(kind.rawValue)' FROM \(table)
                    WHERE \(nameColumn) IS NOT NULL AND instr(\(nameColumn), '/') = 0;
                INSERT OR IGNORE INTO file_refs (file_id, save_id)
                    SELECT files.id, \(table).\(idColumn) FROM \(table)
                    JOIN files ON files.relative_path = \(path);
                """)
        }
    }

    /// The schema revision recorded in the file.
    static func userVersion(in database: SavesDatabase) throws -> Int32 {
        Int32(try database.scalarInt("PRAGMA user_version") ?? 0)
    }

    private static let tables = """
        -- One row per save. `seq` is the list's own order (highest first): a new
        -- save goes to the front, and `bump` moves one there, independently of
        -- the dates a deck sorts by.
        CREATE TABLE IF NOT EXISTS saves (
            id                         TEXT    PRIMARY KEY NOT NULL,
            seq                        INTEGER NOT NULL,
            url_string                 TEXT    NOT NULL,
            title                      TEXT,
            date_added                 REAL    NOT NULL,
            archived_at                REAL,
            pending_archive_at         REAL,
            bump_date                  REAL,
            state                      TEXT    NOT NULL,
            read_state                 TEXT    NOT NULL,
            last_reader_mode           TEXT,
            content_file_name          TEXT,
            original_archive_file_name TEXT,
            thumbnail_file_name        TEXT,
            document_type              TEXT,
            last_word_index            INTEGER,
            last_scroll_offset         REAL,
            last_original_scroll_offset REAL,
            last_spoken_word_index     INTEGER,
            word_count                 INTEGER,
            reading_progress           REAL,
            sender_name                TEXT,
            incoming_sender_email      TEXT,
            shared_by_username         TEXT,
            last_save_attempt_date     REAL,
            platform                   TEXT,
            platform_item_id           TEXT,
            capture_source             TEXT
        ) WITHOUT ROWID;

        -- The five per-destination send dictionaries, normalised: one row per
        -- destination a save has any send bookkeeping for. Each column is
        -- independently absent, which is what the dictionaries express (a
        -- delivered send clears its retry columns but keeps its date).
        CREATE TABLE IF NOT EXISTS send_states (
            save_id           TEXT NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
            destination       TEXT NOT NULL,
            state             TEXT,
            date_sent         REAL,
            failure_count     INTEGER,
            next_attempt_date REAL,
            last_error        TEXT,
            PRIMARY KEY (save_id, destination)
        ) WITHOUT ROWID;

        -- The price-tracker payload of a save that is one. Absent for every other
        -- save, which is what makes the save an article or a video instead.
        -- `pending_comparison_*` is the 0-or-1 record of a save-time seller
        -- fan-out still in flight: present together or all null.
        CREATE TABLE IF NOT EXISTS price_trackers (
            save_id                  TEXT PRIMARY KEY NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
            product_name             TEXT NOT NULL,
            brand                    TEXT,
            product_id               TEXT,
            identifier_gtin          TEXT,
            identifier_mpn           TEXT,
            identifier_sku           TEXT,
            identifier_brand         TEXT,
            image_file_name          TEXT,
            initial_price            TEXT NOT NULL,
            initial_currency         TEXT NOT NULL,
            alert_threshold_fraction REAL,
            is_archived              INTEGER NOT NULL,
            alert_acknowledged_at    REAL,
            pending_comparison_source_url          TEXT,
            pending_comparison_started_at          REAL,
            pending_comparison_threshold_at_start  REAL
        ) WITHOUT ROWID;

        -- The downloaded-media payload of a save that is one, the twin of
        -- `price_trackers`. Absent for every other save. Under `ON DELETE
        -- CASCADE`, so deleting the save takes the row, and the row's
        -- `file_refs` edges go with it and queue the files.
        --
        -- `source_url_string` is deliberately its OWN column rather than a read
        -- of `saves.url_string`: the download keeps the pre-unwrap source URL, and
        -- matching a media row by URL has to use the URL it was downloaded from.
        --
        -- `storage_state` is `undownloaded` | `localFile` | `photosReference`,
        -- with `file_name` set for the first and `photos_identifier` for the
        -- second. No CHECK constraint, for the reason no enum column here has one.
        CREATE TABLE IF NOT EXISTS media_saves (
            save_id             TEXT PRIMARY KEY NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
            source_url_string   TEXT NOT NULL,
            title               TEXT,
            date_saved          REAL NOT NULL,
            archived_at         REAL,
            kind                TEXT,
            storage_state       TEXT NOT NULL,
            file_name           TEXT,
            photos_identifier   TEXT,
            thumbnail_file_name TEXT,
            platform            TEXT,
            platform_item_id    TEXT
        ) WITHOUT ROWID;

        -- The hosts the user took off a tracker's seller list. A passive writer
        -- checks this before adding a seller back.
        CREATE TABLE IF NOT EXISTS tracker_rejected_sellers (
            save_id TEXT NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
            host    TEXT NOT NULL,
            PRIMARY KEY (save_id, host)
        ) WITHOUT ROWID;

        -- One watched seller listing. `position` preserves the tracker's display
        -- order; the URL is the listing's identity within the tracker.
        CREATE TABLE IF NOT EXISTS tracker_stores (
            id             INTEGER PRIMARY KEY,
            save_id        TEXT    NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
            position       INTEGER NOT NULL,
            url_string     TEXT    NOT NULL,
            last_price     TEXT,
            currency       TEXT    NOT NULL,
            last_refreshed REAL,
            UNIQUE (save_id, url_string)
        );

        -- One day's lowest observed price at one seller. The PK is the day
        -- bucket: a second observation on the same day lowers the row rather
        -- than adding one.
        CREATE TABLE IF NOT EXISTS tracker_price_points (
            store_id     INTEGER NOT NULL REFERENCES tracker_stores(id) ON DELETE CASCADE,
            day          REAL    NOT NULL,
            lowest_price TEXT    NOT NULL,
            currency     TEXT    NOT NULL,
            fx_rate      TEXT,
            PRIMARY KEY (store_id, day)
        ) WITHOUT ROWID;

        -- One row per on-disk artifact the library owns: an article's content
        -- JSON, its captured archive, an imported document, a thumbnail, a
        -- product photo, a downloaded article image. The path is relative to the
        -- App Group container, and it is the file's identity — one image
        -- downloaded once is one row however many saves show it.
        CREATE TABLE IF NOT EXISTS files (
            id            INTEGER PRIMARY KEY,
            relative_path TEXT    NOT NULL UNIQUE,
            kind          TEXT
        );

        -- Which saves hold which files. The reference COUNT is the number of
        -- edges, so there is no counter to drift, and deleting a save cascades
        -- here — a delete cannot forget an artifact.
        CREATE TABLE IF NOT EXISTS file_refs (
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            save_id TEXT    NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
            PRIMARY KEY (file_id, save_id)
        ) WITHOUT ROWID;

        -- The same ownership for a holder that is NOT a save: a preloaded page
        -- (`PreloadStore`, keyed by the page's URL hash) downloads its images
        -- into the same shared `Articles/` cache a save reads from, so one table
        -- has to count both or a save's delete would take a live page's picture
        -- with it. No foreign key — the holder lives outside this database, and
        -- `PreloadStore` releases its own keys.
        CREATE TABLE IF NOT EXISTS file_holders (
            file_id    INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            holder_key TEXT    NOT NULL,
            PRIMARY KEY (file_id, holder_key)
        ) WITHOUT ROWID;

        -- The current, live local copy of an image URL. This is deliberately a
        -- mapping rather than a filename convention: once a path is queued for
        -- deletion it is retired forever, so a later download of the same URL
        -- must receive a different path. Deleting a `files` row cascades this
        -- mapping away with it.
        CREATE TABLE IF NOT EXISTS image_sources (
            source_url TEXT    PRIMARY KEY NOT NULL,
            file_id    INTEGER NOT NULL UNIQUE REFERENCES files(id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        -- One preloaded page's file, pointed at by the page's URL hash. The page
        -- itself lives in `PreloadStore`'s own `Preloads/` cache; this table is
        -- the pointer into it, so the page's owners are ordinary ownership edges
        -- on the `files` row — `file_refs` for the saves whose crawl reached the
        -- page, `file_holders` for the two owners that are not saves. Deleting a
        -- save therefore cascades to here, and the release trigger queues the
        -- page's file for the same reaper every other artifact uses.
        --
        -- A mapping rather than a filename convention, for the reason
        -- `image_sources` is one: a released path is retired forever, so a later
        -- preload of the same URL must receive a different file. A page that
        -- caches no content (a platform link, an unrepresentable one) still has a
        -- row, and its `files` row reserves a NAME that is never written — which
        -- is what lets one mechanism count every page. The reaper already clears
        -- a queued path whose file is absent.
        CREATE TABLE IF NOT EXISTS preload_pages (
            url_key TEXT    PRIMARY KEY NOT NULL,
            file_id INTEGER NOT NULL UNIQUE REFERENCES files(id) ON DELETE CASCADE
        ) WITHOUT ROWID;

        -- Files whose last holder is gone, waiting to be unlinked. A file system
        -- cannot join a transaction, so the COMMIT records the intent and
        -- `PendingDeleteReaper` does the unlink afterwards; a process killed in
        -- between finds the row still here and finishes the job.
        --
        -- `enqueued_at` is UNIX seconds, unlike every other date column in this
        -- file (which are seconds since the reference date): a TRIGGER writes it,
        -- and SQLite's own clock is the only one a trigger can read. Nothing
        -- queries it — the reaper attempts every row it finds — so it is a
        -- diagnostic, which is also why it gets no index.
        CREATE TABLE IF NOT EXISTS pending_deletes (
            relative_path TEXT    PRIMARY KEY NOT NULL,
            enqueued_at   REAL    NOT NULL,
            attempts      INTEGER NOT NULL DEFAULT 0
        ) WITHOUT ROWID;

        -- A path that has entered `pending_deletes` is permanently retired. The
        -- reaper clears its queue row after unlinking, but this tombstone remains
        -- so stale content can never recreate the same location later.
        CREATE TABLE IF NOT EXISTS retired_paths (
            relative_path TEXT PRIMARY KEY NOT NULL,
            retired_at    REAL NOT NULL
        ) WITHOUT ROWID;
        """

    /// One index per query that exists, and no others: an index nothing reads is
    /// paid for on every insert and update. The scans that still run in Swift over
    /// the whole list — the launch sweep's pending/failed re-ingest, the deck's
    /// date sort, the platform-item and tracker-merge checks — get their index the
    /// day they become a query.
    private static let indexes = """
        -- items(): the whole list in its own order, newest first.
        CREATE INDEX IF NOT EXISTS saves_seq ON saves(seq DESC);

        -- item(forURLString:) and the insert paths' own "is this URL already
        -- saved?" check — the URL dedup every save from every surface runs.
        CREATE INDEX IF NOT EXISTS saves_url_string ON saves(url_string);

        -- archivePendingFinishedItems(): the reader-completed saves waiting for
        -- the next lifecycle boundary.
        CREATE INDEX IF NOT EXISTS saves_pending_archive
            ON saves(pending_archive_at) WHERE pending_archive_at IS NOT NULL;

        -- priceTracker(containingStoreURL:): a re-save of an already-tracked
        -- seller page finds its tracker instead of detecting a second one.
        CREATE INDEX IF NOT EXISTS tracker_stores_url ON tracker_stores(url_string);

        -- The FK covering index for tracker_stores.save_id. The other four
        -- foreign keys lead their table's own primary key (send_states,
        -- price_trackers, tracker_rejected_sellers on save_id;
        -- tracker_price_points on store_id), so they are already covered.
        CREATE INDEX IF NOT EXISTS tracker_stores_save ON tracker_stores(save_id);

        -- mediaItem(forURLString:) — the "have I already downloaded this?" check
        -- every media start path runs, against the download's own source URL.
        -- The platform + item-id dedupe still runs in Swift over the whole list,
        -- so it gets its index the day it becomes a query.
        CREATE INDEX IF NOT EXISTS media_saves_url ON media_saves(source_url_string);

        -- The FK covering index for file_refs.save_id, which is what a save's
        -- delete cascade and its ownership reconciliation both scan.
        -- `file_id` leads the primary key, so the release trigger's "any edges
        -- left?" check is already covered.
        CREATE INDEX IF NOT EXISTS file_refs_save ON file_refs(save_id);

        -- The same, for releasing one preloaded page's images.
        CREATE INDEX IF NOT EXISTS file_holders_key ON file_holders(holder_key);
        """

    /// The invariant no Swift caller can be trusted with: **a `files` row never
    /// sits at zero holders.** Four apps and their extensions all write these
    /// tables, so the check that frees a file lives in the file rather than in
    /// each of them.
    ///
    /// The release trigger fires for a cascade-driven delete too — verified, and
    /// pinned by `SavedFileOwnershipTests` — so deleting a save is the whole
    /// operation: `ON DELETE CASCADE` removes its edges, and each removal that
    /// was some file's last one queues that file for the reaper.
    private static let triggers = """
        CREATE TRIGGER IF NOT EXISTS file_refs_release AFTER DELETE ON file_refs
        WHEN NOT EXISTS (SELECT 1 FROM file_refs WHERE file_id = OLD.file_id)
         AND NOT EXISTS (SELECT 1 FROM file_holders WHERE file_id = OLD.file_id)
        BEGIN
            INSERT OR IGNORE INTO retired_paths (relative_path, retired_at)
                SELECT relative_path, strftime('%s', 'now')
                FROM files WHERE id = OLD.file_id;
            INSERT OR REPLACE INTO pending_deletes (relative_path, enqueued_at, attempts)
                SELECT relative_path, strftime('%s', 'now'), 0
                FROM files WHERE id = OLD.file_id;
            DELETE FROM files WHERE id = OLD.file_id;
        END;

        CREATE TRIGGER IF NOT EXISTS file_holders_release AFTER DELETE ON file_holders
        WHEN NOT EXISTS (SELECT 1 FROM file_refs WHERE file_id = OLD.file_id)
         AND NOT EXISTS (SELECT 1 FROM file_holders WHERE file_id = OLD.file_id)
        BEGIN
            INSERT OR IGNORE INTO retired_paths (relative_path, retired_at)
                SELECT relative_path, strftime('%s', 'now')
                FROM files WHERE id = OLD.file_id;
            INSERT OR REPLACE INTO pending_deletes (relative_path, enqueued_at, attempts)
                SELECT relative_path, strftime('%s', 'now'), 0
                FROM files WHERE id = OLD.file_id;
            DELETE FROM files WHERE id = OLD.file_id;
        END;

        """
}
