//
//  SavesDatabaseTests.swift
//  LunaTests
//
//  The saves database as a cross-process store: two connections on one file, a
//  writer that never commits, the enum tolerance four independently-updated apps
//  depend on, and the foreign keys that make deleting a save delete everything
//  hanging off it.
//

import LunaModels
@testable import LunaStorage
import SQLite3
import XCTest

final class SavesDatabaseTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavesDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore() -> SavesStore {
        SavesStore(containerURL: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent("saves.sqlite") }

    private func openDatabase() throws -> SavesDatabase {
        try SavesDatabase(fileURL: databaseURL)
    }

    /// Creates a fixture without passing through `SavesSchema.create`, so an
    /// upgrade test can reproduce a genuinely shipped old shape rather than a
    /// current database whose version stamp was merely lowered.
    private func createRawDatabase(_ sql: String) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open(databaseURL.path, &database)
        guard openStatus == SQLITE_OK, let database else {
            throw NSError(domain: "SavesDatabaseTests.SQLite", code: Int(openStatus))
        }
        defer { sqlite3_close(database) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let executeStatus = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard executeStatus == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite fixture failed"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "SavesDatabaseTests.SQLite", code: Int(executeStatus),
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    // MARK: - Configuration

    /// The configuration every process depends on: WAL (so a reader is never
    /// blocked by the writer), the schema stamp, and foreign keys on — without
    /// which the cascades below silently do nothing.
    func testConnectionIsConfiguredForCrossProcessUse() throws {
        let database = try openDatabase()
        try database.perform { db in
            var journalMode: String?
            try db.query("PRAGMA journal_mode") { row in journalMode = row.string(0)?.lowercased() }
            XCTAssertEqual(journalMode, "wal")
            XCTAssertEqual(try db.scalarInt("PRAGMA foreign_keys"), 1)
            XCTAssertEqual(try SavesSchema.userVersion(in: db), SavesDatabase.schemaVersion)
        }
    }

    /// Two different layouts were shipped with the version-6 stamp. Opening the
    /// earlier, two-column layout detects it by shape, releases its page file, and
    /// creates the complete table rather than trusting the ambiguous stamp.
    func testAmbiguousVersionSixPreloadTableIsRebuiltByShape() throws {
        try createRawDatabase("""
            PRAGMA foreign_keys = ON;
            CREATE TABLE saves (
                id TEXT PRIMARY KEY NOT NULL, seq INTEGER NOT NULL,
                url_string TEXT NOT NULL, pending_archive_at REAL
            ) WITHOUT ROWID;
            CREATE TABLE files (
                id INTEGER PRIMARY KEY, relative_path TEXT NOT NULL UNIQUE, kind TEXT
            );
            CREATE TABLE file_refs (
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                save_id TEXT NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
                PRIMARY KEY (file_id, save_id)
            ) WITHOUT ROWID;
            CREATE TABLE file_holders (
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                holder_key TEXT NOT NULL, PRIMARY KEY (file_id, holder_key)
            ) WITHOUT ROWID;
            CREATE TABLE preload_pages (
                url_key TEXT PRIMARY KEY NOT NULL,
                file_id INTEGER NOT NULL UNIQUE REFERENCES files(id) ON DELETE CASCADE
            ) WITHOUT ROWID;
            CREATE TABLE pending_deletes (
                relative_path TEXT PRIMARY KEY NOT NULL, enqueued_at REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0
            ) WITHOUT ROWID;
            CREATE TABLE retired_paths (
                relative_path TEXT PRIMARY KEY NOT NULL, retired_at REAL NOT NULL
            ) WITHOUT ROWID;
            INSERT INTO saves (id, seq, url_string)
                VALUES ('11111111-1111-1111-1111-111111111111', 1,
                        'https://example.com/root');
            INSERT INTO files (id, relative_path, kind)
                VALUES (41, 'Preloads/legacy-page.json', 'preloadPage');
            INSERT INTO file_refs (file_id, save_id)
                VALUES (41, '11111111-1111-1111-1111-111111111111');
            INSERT INTO file_holders (file_id, holder_key)
                VALUES (41, 'preload-owner:legacy-session');
            INSERT INTO preload_pages (url_key, file_id) VALUES ('legacy-key', 41);
            PRAGMA user_version = 6;
            """)

        let reopened = try openDatabase()
        try reopened.perform { db in
            XCTAssertEqual(try SavesSchema.userVersion(in: db), SavesDatabase.schemaVersion)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM preload_pages"), 0)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM files WHERE id = 41"), 0)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM file_refs WHERE file_id = 41"), 0)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM file_holders WHERE file_id = 41"), 0)
            XCTAssertEqual(
                try db.scalarInt(
                    "SELECT COUNT(*) FROM pending_deletes WHERE relative_path = 'Preloads/legacy-page.json'"),
                1)
            XCTAssertEqual(
                try db.scalarInt(
                    "SELECT COUNT(*) FROM retired_paths WHERE relative_path = 'Preloads/legacy-page.json'"),
                1)

            var columns: Set<String> = []
            try db.query("PRAGMA table_info(preload_pages)") { row in
                if let name = row.string(1) { columns.insert(name) }
            }
            XCTAssertTrue([
                "url_key", "file_id", "url_string", "kind", "last_loaded_at", "has_content",
            ].allSatisfy(columns.contains))
        }
    }

    /// The other version-6 layout already has the current columns. Its rows must
    /// survive the current-schema open; shape detection makes the repair
    /// idempotent instead of deleting a valid cache solely because its stamp is old.
    func testCompleteVersionSixPreloadTableIsPreserved() throws {
        let root = makeStore().add(urlString: "https://example.com/current-root")
        let preload = PreloadStore(containerURL: directory)
        let pageURL = URL(string: "https://example.com/current-page")!
        XCTAssertNotNil(preload.record(
            url: pageURL, rootID: root.id, kind: .article,
            content: ArticleContent(title: "Current", blocks: [
                .init(kind: .paragraph, text: String(repeating: "x", count: 1500), links: []),
            ])))

        try autoreleasepool {
            let database = try openDatabase()
            try database.perform { db in try db.execute("PRAGMA user_version = 6") }
        }

        let reopened = try openDatabase()
        try reopened.perform { db in
            XCTAssertEqual(try SavesSchema.userVersion(in: db), SavesDatabase.schemaVersion)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM preload_pages"), 1)
        }
        XCTAssertEqual(PreloadStore(containerURL: directory).entry(for: pageURL)?.kind, .article)
    }

    // MARK: - Per-app Spotlight bookkeeping

    func testSpotlightBookkeepingIsIndependentForTheTwoArticleApps() {
        let store = makeStore()
        store.setSpotlightIndexedIDs(
            ["core-only", "shared"], for: .luna,
            completingLegacyReconciliation: true)
        store.setSpotlightIndexedIDs(
            ["reader-only", "shared"], for: .reader,
            completingLegacyReconciliation: true)

        XCTAssertEqual(store.spotlightIndexState(for: .luna).indexedIDs, ["core-only", "shared"])
        XCTAssertEqual(
            store.spotlightIndexState(for: .reader).indexedIDs, ["reader-only", "shared"])

        store.setSpotlightIndexedIDs(["core-next"], for: .luna)

        XCTAssertEqual(store.spotlightIndexState(for: .luna).indexedIDs, ["core-next"])
        XCTAssertEqual(
            store.spotlightIndexState(for: .reader).indexedIDs, ["reader-only", "shared"],
            "a Luna sweep must not consume Reader's bundle-specific index state")
    }

    func testSchemaNineSpotlightIDsAreOfferedToEachArticleAppOnce() throws {
        try createRawDatabase("""
            CREATE TABLE spotlight_index (
                save_id TEXT PRIMARY KEY NOT NULL
            ) WITHOUT ROWID;
            INSERT INTO spotlight_index (save_id) VALUES ('still-live'), ('now-deleted');
            PRAGMA user_version = 9;
            """)

        let store = makeStore()
        for app in [LunaApp.luna, .reader] {
            let state = store.spotlightIndexState(for: app)
            XCTAssertTrue(state.needsLegacyReconciliation)
            XCTAssertEqual(state.legacyIndexedIDs, ["still-live", "now-deleted"])
        }

        store.setSpotlightIndexedIDs(
            ["still-live"], for: .luna, completingLegacyReconciliation: true)

        XCTAssertEqual(
            store.spotlightIndexState(for: .luna),
            SpotlightIndexState(
                indexedIDs: ["still-live"], legacyIndexedIDs: [],
                needsLegacyReconciliation: false))
        XCTAssertEqual(
            store.spotlightIndexState(for: .reader).legacyIndexedIDs,
            ["still-live", "now-deleted"],
            "one app's reconciliation must not consume the other app's legacy cleanup")
    }

    // MARK: - Two connections, one file

    /// The cross-process case, with two `SavesStore` instances standing in
    /// for two processes: neither knows about the other, and each sees the other's
    /// committed writes on its next read with no notification in between.
    func testTwoStoreInstancesSeeEachOthersCommittedWrites() {
        let first = makeStore()
        let second = makeStore()

        let fromFirst = first.add(urlString: "https://example.com/from-first")
        XCTAssertEqual(second.items().map(\.id), [fromFirst.id])

        let fromSecond = second.add(urlString: "https://example.com/from-second")
        XCTAssertEqual(first.items().map(\.id), [fromSecond.id, fromFirst.id])

        // A mutation through one instance is visible through the other, field for
        // field — the point of one shared file rather than one cache each.
        second.markReadState(.read, for: fromFirst.id)
        XCTAssertEqual(first.item(withID: fromFirst.id)?.readState, .read)
    }

    /// Interleaved writers on separate connections: every write lands, and none of
    /// them fails with SQLITE_BUSY — that is what `busy_timeout` buys.
    func testInterleavedWritersOnSeparateConnectionsAllLand() {
        let stores = (0..<4).map { _ in makeStore() }
        let finished = expectation(description: "writers finished")
        finished.expectedFulfillmentCount = stores.count

        for (index, store) in stores.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async {
                for round in 0..<10 {
                    store.add(urlString: "https://example.com/\(index)-\(round)")
                }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 30)

        XCTAssertEqual(makeStore().items().count, 40)
        // Drain the change notifications this test posted.
        let drained = expectation(description: "notifications drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// A writer that never commits — the shape a killed process leaves behind. The
    /// abandoned transaction rolls back with its connection, and the store reads a
    /// consistent list either way: the uncommitted row was never there.
    func testAnAbandonedTransactionLeavesTheStoreReadable() throws {
        let store = makeStore()
        let survivor = store.add(urlString: "https://example.com/committed")

        try autoreleasepool {
            let abandoned = try openDatabase()
            try abandoned.perform { db in
                try db.execute("BEGIN IMMEDIATE")
                try db.run(
                    "INSERT INTO saves (id, seq, url_string, date_added, state, read_state) "
                        + "VALUES (?, 99, 'https://example.com/never-committed', 0, 'pending', 'unopened')"
                ) { try $0.bind(1, uuid: UUID()) }
                // No COMMIT: the connection is dropped mid-transaction.
            }
        }

        let reread = makeStore()
        XCTAssertEqual(reread.items().map(\.id), [survivor.id])
        XCTAssertEqual(reread.items().first?.urlString, "https://example.com/committed")
    }

    // MARK: - Enum tolerance

    /// The version-skew case: a newer sibling app writes an enum case this binary
    /// has never heard of. The row still reads, at its safe default — an unknown
    /// state means "re-ingest it", never "ready".
    func testUnknownEnumRawValuesReadBackAsSafeDefaults() throws {
        let store = makeStore()
        let item = store.add(urlString: "https://example.com/from-the-future")

        let database = try openDatabase()
        try database.perform { db in
            try db.run(
                """
                UPDATE saves SET state = 'quantum', read_state = 'skimmed',
                    last_reader_mode = 'hologram', platform = 'newnetwork',
                    capture_source = 'telepathy'
                WHERE id = ?
                """
            ) { try $0.bind(1, uuid: item.id) }
            try db.run(
                "INSERT INTO send_states (save_id, destination, state, failure_count) "
                    + "VALUES (?, 'kindle', 'teleported', 3)"
            ) { try $0.bind(1, uuid: item.id) }
        }

        let stored = try XCTUnwrap(makeStore().item(withID: item.id))
        XCTAssertEqual(stored.state, .pending)
        XCTAssertEqual(stored.readState, .unopened)
        XCTAssertNil(stored.lastReaderMode)
        XCTAssertNil(stored.platform)
        XCTAssertNil(stored.captureSource)
        XCTAssertNil(stored.sendStates["kindle"],
                     "an unrecognised send state is absent rather than guessed at")
        XCTAssertEqual(stored.sendFailureCounts["kindle"], 3,
                       "the destination's other bookkeeping still reads")
    }

    /// Every known enum case round-trips through its column unchanged.
    func testEveryKnownEnumCaseRoundTrips() throws {
        let store = makeStore()
        for mode in [SavedItem.ReaderMode.scroll, .highlight, .rsvp, .original] {
            let item = store.add(urlString: "https://example.com/mode-\(mode.rawValue)")
            store.setReaderMode(mode, for: item.id)
            XCTAssertEqual(store.item(withID: item.id)?.lastReaderMode, mode)
        }
        for platform in ContentPlatform.allCases {
            let item = store.add(urlString: "https://example.com/platform-\(platform.rawValue)")
            _ = store.savePlatformMetadata(
                platform: platform, platformItemID: "id-\(platform.rawValue)", title: nil,
                thumbnailFileName: nil, for: item.id)
            XCTAssertEqual(store.item(withID: item.id)?.platform, platform)
            XCTAssertEqual(store.item(withID: item.id)?.state, .ready)
        }
        for source in CaptureSource.allCases {
            let item = store.add(
                urlString: "https://example.com/source-\(source.rawValue)", source: source)
            XCTAssertEqual(store.item(withID: item.id)?.captureSource, source)
        }
    }

    // MARK: - Send bookkeeping

    /// The five per-destination dictionaries are one row per destination, and each
    /// column is independently present: a delivered send keeps its date and drops
    /// its retry state, while another destination's retry state is untouched.
    func testSendBookkeepingRoundTripsPerDestination() throws {
        let store = makeStore()
        let item = store.add(urlString: "https://example.com/sendable")
        let retryAt = Date(timeIntervalSince1970: 1_700_000_500)

        store.scheduleSendRetry(
            for: item.id, destination: "kobo", failureCount: 2,
            nextAttemptDate: retryAt, errorMessage: "greylisted")
        store.setSendState(.sent, for: item.id, destination: "kindle")

        let stored = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertEqual(stored.sendStates, ["kobo": .queued, "kindle": .sent])
        XCTAssertEqual(stored.sendFailureCounts, ["kobo": 2])
        XCTAssertEqual(stored.sendNextAttemptDates, ["kobo": retryAt])
        XCTAssertEqual(stored.sendLastErrors, ["kobo": "greylisted"])
        XCTAssertNotNil(stored.datesSent["kindle"])
        XCTAssertNil(stored.datesSent["kobo"])

        // A terminal failure replaces that destination's state and error, and
        // leaves the other destination alone.
        store.markSendTerminalFailure(
            for: item.id, destination: "kobo", errorMessage: "mailbox full", failureCount: 5)
        let afterFailure = try XCTUnwrap(store.item(withID: item.id))
        XCTAssertEqual(afterFailure.sendStates["kobo"], .failed)
        XCTAssertEqual(afterFailure.sendFailureCounts["kobo"], 5)
        XCTAssertNil(afterFailure.sendNextAttemptDates["kobo"])
        XCTAssertEqual(afterFailure.sendLastErrors["kobo"], "mailbox full")
        XCTAssertEqual(afterFailure.sendStates["kindle"], .sent)
    }

    // MARK: - The tracker chain

    /// A tracker survives the round trip whole — its identifiers, its baseline,
    /// its pending fan-out, its rejected sellers, its sellers in display order,
    /// and each seller's day-bucketed history, oldest first.
    func testPriceTrackerRoundTripsWithItsStoresAndHistory() throws {
        let store = makeStore()
        let item = store.add(urlString: "https://shop.example.com/widget")
        var tracker = PriceTracker(
            productName: "Widget", firstStoreURL: "https://shop.example.com/widget",
            price: Decimal(string: "129.95")!, currency: "AUD",
            brand: "Acme", productID: "SKU-1",
            identifiers: ProductIdentifiers(gtin: "0123456789012", mpn: "MP-9", sku: "S-1", brand: "Acme"),
            imageFileName: "img-widget.jpg",
            alertThresholdFraction: 0.2,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://other.example.com/widget",
            lastPrice: Decimal(string: "119.00"), currency: "AUD",
            lastRefreshed: Date(timeIntervalSince1970: 1_700_100_000)))
        tracker.recordPriceSample(
            Decimal(string: "125.50")!, currency: "AUD",
            urlString: "https://shop.example.com/widget",
            at: Date(timeIntervalSince1970: 1_700_000_000))
        tracker.recordPriceSample(
            Decimal(string: "121.00")!, currency: "AUD",
            urlString: "https://shop.example.com/widget",
            at: Date(timeIntervalSince1970: 1_700_400_000))
        tracker.beginPendingComparison(
            sourceURLString: "https://shop.example.com/widget",
            at: Date(timeIntervalSince1970: 1_700_000_050))
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://rejected.example.com/widget", lastPrice: 1, currency: "AUD"))
        tracker.removeStore(urlString: "https://rejected.example.com/widget")

        store.savePriceTracker(tracker, for: item.id)

        let stored = try XCTUnwrap(makeStore().item(withID: item.id)?.priceTracker)
        XCTAssertEqual(stored, tracker)
        XCTAssertEqual(stored.stores.map(\.urlString), tracker.stores.map(\.urlString),
                       "sellers keep their display order")
        XCTAssertEqual(stored.stores[0].priceHistory.map(\.lowestPrice),
                       [Decimal(string: "125.50")!, Decimal(string: "121.00")!])
        XCTAssertEqual(stored.rejectedSellerHosts, ["rejected.example.com"])
        XCTAssertEqual(stored.pendingComparison?.startedAt, Date(timeIntervalSince1970: 1_700_000_050))
        XCTAssertEqual(stored.initialPrice, Decimal(string: "129.95"))
    }

    /// Deleting a save takes its send states, its tracker, its sellers and their
    /// price points with it. The chain is `ON DELETE CASCADE`, so nothing has to
    /// remember to clean up — and nothing is left pointing at a save that is gone.
    func testDeletingASaveCascadesThroughEverythingHangingOffIt() throws {
        let store = makeStore()
        let item = store.add(urlString: "https://shop.example.com/cascade")
        var tracker = PriceTracker(
            productName: "Cascade", firstStoreURL: "https://shop.example.com/cascade",
            price: 10, currency: "USD")
        tracker.recordPriceSample(
            9, currency: "USD", urlString: "https://shop.example.com/cascade",
            at: Date(timeIntervalSince1970: 1_700_000_000))
        store.savePriceTracker(tracker, for: item.id)
        store.setSendState(.sent, for: item.id, destination: "kindle")
        let survivor = store.add(urlString: "https://shop.example.com/survivor")
        store.setSendState(.queued, for: survivor.id, destination: "kindle")

        let counts = try rowCounts()
        XCTAssertEqual(counts.trackers, 1)
        XCTAssertEqual(counts.stores, 1)
        XCTAssertEqual(counts.points, 1)
        XCTAssertEqual(counts.sendStates, 2)

        store.delete(store.item(withID: item.id)!)

        let after = try rowCounts()
        XCTAssertEqual(after.saves, 1)
        XCTAssertEqual(after.trackers, 0)
        XCTAssertEqual(after.stores, 0)
        XCTAssertEqual(after.points, 0)
        XCTAssertEqual(after.sendStates, 1, "the surviving save keeps its own send state")
        XCTAssertEqual(store.item(withID: survivor.id)?.sendStates["kindle"], .queued)
    }

    private func rowCounts() throws -> (
        saves: Int64, sendStates: Int64, trackers: Int64, stores: Int64, points: Int64
    ) {
        let database = try openDatabase()
        return try database.perform { db in
            (
                try db.scalarInt("SELECT COUNT(*) FROM saves") ?? 0,
                try db.scalarInt("SELECT COUNT(*) FROM send_states") ?? 0,
                try db.scalarInt("SELECT COUNT(*) FROM price_trackers") ?? 0,
                try db.scalarInt("SELECT COUNT(*) FROM tracker_stores") ?? 0,
                try db.scalarInt("SELECT COUNT(*) FROM tracker_price_points") ?? 0
            )
        }
    }

    // MARK: - List order

    /// `items()` is the list's own order, not a date sort: a new save prepends, a
    /// bump moves an old one to the front, and an imported batch keeps the order
    /// of the file it came from.
    func testListOrderIsThePositionOrderAndSurvivesReopening() throws {
        let store = makeStore()
        let first = store.add(urlString: "https://example.com/1")
        let second = store.add(urlString: "https://example.com/2")
        XCTAssertEqual(store.items().map(\.id), [second.id, first.id])

        store.bump(first.id)
        XCTAssertEqual(store.items().map(\.id), [first.id, second.id])

        let placements = store.insertImported(
            [
                SavesStore.ImportedLink(urlString: "https://example.com/a", isArchived: false),
                SavesStore.ImportedLink(urlString: "https://example.com/b", isArchived: true),
                SavesStore.ImportedLink(urlString: "https://example.com/1", isArchived: false),
            ],
            startingAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(placements.map(\.wasInserted), [true, true, false])
        XCTAssertEqual(
            store.items().map(\.urlString),
            ["https://example.com/a", "https://example.com/b",
             "https://example.com/1", "https://example.com/2"])
        XCTAssertTrue(try XCTUnwrap(store.item(forURLString: "https://example.com/b")).isArchived)

        // A fresh connection reads the same order back.
        XCTAssertEqual(makeStore().items().map(\.urlString), store.items().map(\.urlString))
    }

    /// A few hundred saves is the size a real list reaches; reading it whole is
    /// what every deck does on every change, so it has to stay cheap.
    func testAFewHundredSavesReadBackWhole() {
        let store = makeStore()
        let links = (0..<300).map {
            SavesStore.ImportedLink(urlString: "https://example.com/bulk-\($0)", isArchived: false)
        }
        store.insertImported(links, startingAt: Date(timeIntervalSince1970: 1_700_000_000))

        let reread = makeStore()
        XCTAssertEqual(reread.items().count, 300)
        // Cached after the first read: the second is a pragma, not 300 rows.
        XCTAssertEqual(reread.items().count, 300)
        XCTAssertEqual(reread.items().first?.urlString, "https://example.com/bulk-0")
    }
}
