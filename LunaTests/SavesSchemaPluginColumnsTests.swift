import LunaModels
import LunaStorage
import SQLite3
import XCTest

/// The plugin columns and tables schemas 12 and 13 add, and the migration onto
/// an existing file. It asks SQLite directly, because the point is what is IN the database
/// rather than what a Swift mapper believes.
final class SavesSchemaPluginColumnsTests: XCTestCase {

    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavesSchemaPlugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private var databaseURL: URL { container.appendingPathComponent("saves.sqlite") }

    /// Opens the file with its own connection and runs `body`, so a test reads
    /// what a sibling process would see rather than a store's cache.
    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func columns(of table: String, in db: OpaquePointer) -> Set<String> {
        var names: Set<String> = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK
        else { return names }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1) { names.insert(String(cString: raw)) }
        }
        return names
    }

    private func objectNames(in db: OpaquePointer) -> Set<String> {
        var names: Set<String> = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT name FROM sqlite_master", -1, &statement, nil) == SQLITE_OK
        else { return names }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { names.insert(String(cString: raw)) }
        }
        return names
    }

    private func execute(_ sql: String, in db: OpaquePointer) {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) } ?? ""
        sqlite3_free(message)
        XCTAssertEqual(status, SQLITE_OK, "\(sql) — \(detail)")
    }

    private func userVersion(in db: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK
        else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
    }

    // MARK: - A fresh file

    func testAFreshDatabaseHasThePluginColumnsAndTables() throws {
        let store = SavesStore(containerURL: container)
        _ = store.add(urlString: "https://example.com/one")

        try withDatabase { db in
            XCTAssertTrue(columns(of: "saves", in: db).contains("plugin_id"))
            XCTAssertTrue(columns(of: "tracker_stores", in: db).contains("plugin_id"))
            let jobs = columns(of: "media_download_jobs", in: db)
            XCTAssertTrue(jobs.isSuperset(
                of: ["plugin_id", "request_headers_json", "expires_at", "quality"]))

            let names = objectNames(in: db)
            XCTAssertTrue(names.isSuperset(of: [
                "plugin_kv", "plugin_collections",
                "plugin_browser_requests", "pending_plugin_models",
                "plugin_collections_k1", "plugin_collections_k2",
            ]))
        }
    }

    /// The tables carry no CHECK constraint and no unexpected NOT NULL, so a
    /// sibling app that never heard of plugins still writes and reads the file.
    func testPluginTablesAcceptTheRowsTheirStoresWillWrite() throws {
        let store = SavesStore(containerURL: container)
        let save = store.add(urlString: "https://example.com/locked")

        try withDatabase { db in
            execute(
                "INSERT INTO plugin_kv (plugin_id, key, json, updated_at) "
                    + "VALUES ('app.luna.x', 'settings.address', '\"a@b.c\"', 1.0)", in: db)
            execute(
                "INSERT INTO plugin_collections "
                    + "(plugin_id, collection, id, k1, k2, json, updated_at) "
                    + "VALUES ('app.luna.x', 'books', 'b1', 'sent', NULL, '{}', 1.0)", in: db)
            execute(
                "INSERT INTO plugin_browser_requests "
                    + "(save_id, plugin_id, request_json, created_at) "
                    + "VALUES ('\(save.id.uuidString)', 'app.luna.x', '{}', 1.0)", in: db)
            execute(
                "INSERT INTO pending_plugin_models "
                    + "(id, url, model_json, plugin_id, created_at) "
                    + "VALUES ('m1', 'https://example.com/p', '{}', 'app.luna.x', 1.0)", in: db)
        }

        // The browser request hangs off the save: deleting the save takes it.
        store.delete(save)
        try withDatabase { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(
                db, "SELECT count(*) FROM plugin_browser_requests", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        }
    }

    // MARK: - The mappers

    func testASavesPluginOwnerSurvivesAWriteAndRead() {
        let store = SavesStore(containerURL: container)
        var item = store.add(urlString: "https://example.com/owned")
        item.pluginID = "app.luna.instagram"
        store.upsertForTesting([item])

        let reread = SavesStore(containerURL: container).items()
        XCTAssertEqual(reread.first?.pluginID, "app.luna.instagram")
    }

    func testADownloadJobKeepsItsPluginHeadersExpiryAndQuality() throws {
        let store = SavesStore(containerURL: container)
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        let inserted = store.insertMediaDownloadJob(
            forSourceURLString: "https://example.com/reel"
        ) { _ in
            LiveMediaDownloadJob(
                id: "job-1", sourceURLString: "https://example.com/reel",
                assetURLString: "https://cdn.example/v.mp4", title: "Reel",
                phase: .downloading, progress: 0, resolveAttempts: 0, mediaAttempts: 0,
                pluginID: "app.luna.instagram",
                requestHeadersJSON: #"{"Referer":"https://example.com"}"#,
                expiresAt: expiry, quality: "1080p")
        }
        XCTAssertNotNil(inserted)

        let reread = try XCTUnwrap(
            SavesStore(containerURL: container).mediaDownloadJob(id: "job-1"))
        XCTAssertEqual(reread.pluginID, "app.luna.instagram")
        XCTAssertEqual(reread.requestHeadersJSON, #"{"Referer":"https://example.com"}"#)
        XCTAssertEqual(reread.expiresAt, expiry)
        XCTAssertEqual(reread.quality, "1080p")
    }

    // MARK: - Migration

    /// A database written by a schema-11 build: the plugin columns and tables
    /// removed and the stamp put back. Reopening must migrate it in place and
    /// leave every existing row where it was.
    func testASchema11DatabaseMigratesToTheCurrentSchemaAndKeepsItsRows() throws {
        var store: SavesStore? = SavesStore(containerURL: container)
        let kept = store!.add(urlString: "https://example.com/kept")
        store = nil

        try withDatabase { db in
            execute("ALTER TABLE saves DROP COLUMN plugin_id", in: db)
            execute("ALTER TABLE tracker_stores DROP COLUMN plugin_id", in: db)
            execute("ALTER TABLE media_download_jobs DROP COLUMN plugin_id", in: db)
            execute("ALTER TABLE media_download_jobs DROP COLUMN request_headers_json", in: db)
            execute("ALTER TABLE media_download_jobs DROP COLUMN expires_at", in: db)
            execute("ALTER TABLE media_download_jobs DROP COLUMN quality", in: db)
            execute("DROP TABLE plugin_kv", in: db)
            execute("DROP TABLE plugin_collections", in: db)
            execute("DROP TABLE plugin_browser_requests", in: db)
            execute("DROP TABLE pending_plugin_models", in: db)
            execute("PRAGMA user_version = 11", in: db)
        }
        try withDatabase { db in
            XCTAssertEqual(userVersion(in: db), 11, "the fixture must look like schema 11")
            XCTAssertFalse(columns(of: "saves", in: db).contains("plugin_id"))
        }

        let migrated = SavesStore(containerURL: container)
        XCTAssertEqual(migrated.items().map(\.id), [kept.id])
        XCTAssertNil(migrated.items().first?.pluginID)

        try withDatabase { db in
            XCTAssertEqual(userVersion(in: db), 13)
            XCTAssertTrue(columns(of: "saves", in: db).contains("plugin_id"))
            XCTAssertTrue(columns(of: "tracker_stores", in: db).contains("plugin_id"))
            XCTAssertTrue(columns(of: "media_download_jobs", in: db)
                .isSuperset(of: ["plugin_id", "request_headers_json", "expires_at", "quality"]))
            XCTAssertTrue(objectNames(in: db).isSuperset(of: [
                "plugin_kv", "plugin_collections",
                "plugin_browser_requests", "pending_plugin_models",
            ]))
        }

        // The migrated file is writable through the new column too.
        var item = try XCTUnwrap(migrated.items().first)
        item.pluginID = "app.luna.x"
        migrated.upsertForTesting([item])
        XCTAssertEqual(
            SavesStore(containerURL: container).items().first?.pluginID, "app.luna.x")
    }
}
