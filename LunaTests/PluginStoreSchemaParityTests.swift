//
//  PluginStoreSchemaParityTests.swift
//  LunaTests
//

import LunaPluginKit
import LunaStorage
import SQLite3
import XCTest

/// `LunaPluginKit` opens its own connection to `saves.sqlite` — the Safari
/// appex links it and opens no `SavesStore` — and creates the plugin tables if
/// they are absent. Two places therefore hold DDL for the same tables.
///
/// This is the pin between them: a database created by `SavesSchema` and one
/// created by the plugin tier alone must hold the SAME table definitions, so a
/// column added to one and not the other fails here rather than in a process
/// that reads a row it cannot write.
final class PluginStoreSchemaParityTests: XCTestCase {

    private var directoryURL: URL!

    override func setUp() {
        super.setUp()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-schema-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directoryURL)
        super.tearDown()
    }

    /// The tables both tiers declare.
    private static let sharedTables = [
        "plugin_kv", "plugin_collections", "plugin_browser_requests",
    ]

    /// `sqlite_master.sql` for each table, read through a plain connection.
    private func definitions(in fileURL: URL) -> [String: String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else { return [:] }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') "
            + "AND name LIKE 'plugin_%'"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }
        var found: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: namePointer)
            let definition = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            found[name] = Self.normalized(definition)
        }
        return found
    }

    /// Whitespace is not part of a definition; the columns and constraints are.
    private static func normalized(_ sql: String) -> String {
        sql.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "IF NOT EXISTS ", with: "")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    func testTheTwoTiersDeclareTheSamePluginTables() {
        // One database made by the saves schema.
        let savesURL = directoryURL.appendingPathComponent("saves-tier")
        try? FileManager.default.createDirectory(at: savesURL, withIntermediateDirectories: true)
        _ = SavesStore(containerURL: savesURL).items()
        let fromSaves = definitions(in: savesURL.appendingPathComponent("saves.sqlite"))

        // One made by the plugin tier alone, the way the Safari appex would.
        let pluginURL = directoryURL.appendingPathComponent("plugin-tier")
        try? FileManager.default.createDirectory(at: pluginURL, withIntermediateDirectories: true)
        let kvFile = pluginURL.appendingPathComponent("saves.sqlite")
        _ = PluginKVStore(fileURL: kvFile).keys(pluginID: "probe")
        let fromPlugin = definitions(in: kvFile)

        XCTAssertFalse(fromSaves.isEmpty, "the saves schema created no plugin tables")
        XCTAssertFalse(fromPlugin.isEmpty, "the plugin tier created no plugin tables")
        for table in Self.sharedTables {
            XCTAssertEqual(
                fromPlugin[table], fromSaves[table],
                "\(table) is declared differently by the two tiers")
        }
        for index in ["plugin_collections_k1", "plugin_collections_k2"] {
            XCTAssertEqual(fromPlugin[index], fromSaves[index], index)
        }
    }

    func testThePluginTierWritesRowsTheSavesTierCanRead() {
        let containerURL = directoryURL.appendingPathComponent("shared")
        try? FileManager.default.createDirectory(
            at: containerURL, withIntermediateDirectories: true)
        let fileURL = containerURL.appendingPathComponent("saves.sqlite")
        // The saves tier opens first, the way an app launch does.
        _ = SavesStore(containerURL: containerURL).items()

        let store = PluginKVStore(fileURL: fileURL)
        XCTAssertTrue(store.setValueJSON("{\"a\":1}", pluginID: "p", key: "k", now: Date()))
        XCTAssertEqual(store.valueJSON(pluginID: "p", key: "k"), "{\"a\":1}")

        // A second connection sees the committed row, which is what the four
        // processes rely on.
        XCTAssertEqual(
            PluginKVStore(fileURL: fileURL).valueJSON(pluginID: "p", key: "k"), "{\"a\":1}")
    }

    func testKVQuotaIsAtomicAndReplacingAValueChargesOnlyTheDelta() throws {
        let fileURL = directoryURL.appendingPathComponent("quota.sqlite")
        let store = PluginKVStore(
            fileURL: fileURL,
            quotas: PluginStorageQuotas(
                maxKVKeys: 2, maxKVBytes: 8,
                maxCollectionRows: 1, maxCollectionBytes: 8))

        try store.setValueJSONChecked("1234", pluginID: "p", key: "a", now: Date())
        try store.setValueJSONChecked("12", pluginID: "p", key: "a", now: Date())
        try store.setValueJSONChecked("123456", pluginID: "p", key: "b", now: Date())
        XCTAssertThrowsError(
            try store.setValueJSONChecked("1", pluginID: "p", key: "c", now: Date())
        ) { XCTAssertEqual($0 as? PluginStorageError, .quotaExceeded) }
        XCTAssertNil(store.valueJSON(pluginID: "p", key: "c"))
    }

    func testCollectionQuotaDoesNotPartiallyInsertTheRejectedRow() throws {
        let store = PluginKVStore(
            fileURL: directoryURL.appendingPathComponent("collection-quota.sqlite"),
            quotas: PluginStorageQuotas(
                maxKVKeys: 1, maxKVBytes: 8,
                maxCollectionRows: 1, maxCollectionBytes: 8))
        try store.putDocumentChecked(
            PluginCollectionDocument(id: "a", json: "1234"),
            collection: "items", pluginID: "p")

        XCTAssertThrowsError(try store.putDocumentChecked(
            PluginCollectionDocument(id: "b", json: "1"),
            collection: "items", pluginID: "p")) {
                XCTAssertEqual($0 as? PluginStorageError, .quotaExceeded)
            }
        XCTAssertEqual(store.count(collection: "items", pluginID: "p"), 1)
    }

    func testCheckedStorageReportsAnUnavailableRootInsteadOfMissingData() throws {
        let blocker = directoryURL.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let store = PluginKVStore(fileURL: blocker.appendingPathComponent("saves.sqlite"))

        XCTAssertThrowsError(try store.keysChecked(pluginID: "p")) {
            guard case .storageUnavailable = $0 as? PluginStorageError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }
}
