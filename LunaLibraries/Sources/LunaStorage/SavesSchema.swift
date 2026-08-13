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
enum SavesSchema {

    /// Creates the tables and indexes if they are absent, and stamps the schema
    /// revision. Idempotent: every process runs it at open, and the first one to
    /// reach a brand-new file is the one that builds it.
    static func create(in database: SavesDatabase) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.execute(tables)
            try database.execute(indexes)
            try database.execute("PRAGMA user_version = \(SavesDatabase.schemaVersion)")
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
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
        """

    private static let indexes = """
        -- items(): the whole list in its own order, newest first.
        CREATE INDEX IF NOT EXISTS saves_seq ON saves(seq DESC);

        -- The date order every deck sorts by, and the intent matcher's
        -- "saves from the last N days" filter.
        CREATE INDEX IF NOT EXISTS saves_date_added ON saves(date_added DESC);

        -- item(forURLString:) — the ingest dedup, and the insert paths' own
        -- "is this URL already saved?" check.
        CREATE INDEX IF NOT EXISTS saves_url_string ON saves(url_string);

        -- Platform-item lookups (a tweet id / post shortcode already saved).
        CREATE INDEX IF NOT EXISTS saves_platform_item
            ON saves(platform, platform_item_id) WHERE platform IS NOT NULL;

        -- The launch sweep's re-ingest scan: every save still pending or failed.
        CREATE INDEX IF NOT EXISTS saves_unfinished
            ON saves(date_added) WHERE state IN ('pending', 'failed');

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
        """
}
