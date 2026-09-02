//
//  PluginKVStore.swift
//  LunaPluginKit
//

import Foundation

/// One document in a plugin's collection. `k1` and `k2` are the only queryable
/// fields: a plugin names them per document and finds by them, so the store
/// never parses `json`.
public struct PluginCollectionDocument: Equatable, Sendable {
    public let id: String
    public let json: String
    public let k1: String?
    public let k2: String?

    public init(id: String, json: String, k1: String? = nil, k2: String? = nil) {
        self.id = id
        self.json = json
        self.k1 = k1
        self.k2 = k2
    }
}

/// `luna.storage` on the shared database: a plugin-scoped key/value table and
/// plugin-scoped document collections.
///
/// Every row carries the plugin id, so two plugins may use the same key or
/// collection name and never see each other's rows. Plugin SETTINGS live in the
/// same table under `settings.<key>`, which is why this type is also the
/// `PluginSettingsStoring` witness — one table, one place that scopes it.
public final class PluginKVStore: PluginSettingsStoring, @unchecked Sendable {

    public static let shared = PluginKVStore()

    /// The largest value one key may hold (§6.5).
    public static let maxValueBytes = 256 * 1024
    /// The prefix a settings value is stored under.
    public static let settingsKeyPrefix = "settings."

    private let fileURL: URL?
    private let openLock = NSLock()
    private var openedDatabase: PluginDatabase?

    /// `fileURL` is the `saves.sqlite` to use; nil means the App Group's.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? PluginDatabase.sharedFileURL()
    }

    private func database() -> PluginDatabase? {
        openLock.lock()
        defer { openLock.unlock() }
        if let openedDatabase { return openedDatabase }
        guard let fileURL, let database = PluginDatabase(fileURL: fileURL) else { return nil }
        openedDatabase = database
        return database
    }

    // MARK: - Key/value

    /// The JSON one key holds, or nil when it holds nothing.
    public func valueJSON(pluginID: String, key: String) -> String? {
        database()?.query(
            "SELECT json FROM plugin_kv WHERE plugin_id = ? AND key = ?",
            [.text(pluginID), .text(key)]
        ) { PluginSQLRow.text($0, 0) }.first ?? nil
    }

    /// Writes `json`, or deletes the key when `json` is nil. A value over the
    /// cap is refused rather than truncated: half a JSON document is not a
    /// smaller one.
    @discardableResult
    public func setValueJSON(
        _ json: String?, pluginID: String, key: String, now: Date
    ) -> Bool {
        guard let database = database() else { return false }
        guard let json else {
            return database.run(
                "DELETE FROM plugin_kv WHERE plugin_id = ? AND key = ?",
                [.text(pluginID), .text(key)])
        }
        guard json.utf8.count <= Self.maxValueBytes else { return false }
        return database.run(
            """
            INSERT INTO plugin_kv (plugin_id, key, json, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(plugin_id, key) DO UPDATE SET json = excluded.json,
                updated_at = excluded.updated_at
            """,
            [.text(pluginID), .text(key), .text(json), .double(now.timeIntervalSince1970)])
    }

    /// The plugin's keys, optionally those under one prefix, in key order.
    public func keys(pluginID: String, prefix: String? = nil) -> [String] {
        guard let database = database() else { return [] }
        if let prefix, !prefix.isEmpty {
            return database.query(
                "SELECT key FROM plugin_kv WHERE plugin_id = ? AND key LIKE ? ESCAPE '\\' "
                    + "ORDER BY key",
                [.text(pluginID), .text(Self.likePattern(prefix))]
            ) { PluginSQLRow.text($0, 0) }.compactMap { $0 }
        }
        return database.query(
            "SELECT key FROM plugin_kv WHERE plugin_id = ? ORDER BY key", [.text(pluginID)]
        ) { PluginSQLRow.text($0, 0) }.compactMap { $0 }
    }

    /// Removes everything one plugin stored — its keys and every collection.
    /// A deleted plugin leaves no rows behind.
    public func removeAll(pluginID: String) {
        guard let database = database() else { return }
        database.run("DELETE FROM plugin_kv WHERE plugin_id = ?", [.text(pluginID)])
        database.run("DELETE FROM plugin_collections WHERE plugin_id = ?", [.text(pluginID)])
    }

    /// Escapes the LIKE wildcards, so a prefix holding `%` or `_` matches
    /// itself rather than everything.
    static func likePattern(_ prefix: String) -> String {
        var escaped = ""
        for character in prefix {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped + "%"
    }

    // MARK: - Collections

    @discardableResult
    public func putDocument(
        _ document: PluginCollectionDocument, collection: String, pluginID: String,
        now: Date = Date()
    ) -> Bool {
        guard let database = database(),
              document.json.utf8.count <= Self.maxValueBytes
        else { return false }
        return database.run(
            """
            INSERT INTO plugin_collections
                (plugin_id, collection, id, k1, k2, json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(plugin_id, collection, id) DO UPDATE SET
                k1 = excluded.k1, k2 = excluded.k2, json = excluded.json,
                updated_at = excluded.updated_at
            """,
            [
                .text(pluginID), .text(collection), .text(document.id),
                document.k1.map { PluginSQLValue.text($0) } ?? .null,
                document.k2.map { PluginSQLValue.text($0) } ?? .null,
                .text(document.json), .double(now.timeIntervalSince1970),
            ])
    }

    public func document(
        id: String, collection: String, pluginID: String
    ) -> PluginCollectionDocument? {
        database()?.query(
            "SELECT id, json, k1, k2 FROM plugin_collections "
                + "WHERE plugin_id = ? AND collection = ? AND id = ?",
            [.text(pluginID), .text(collection), .text(id)],
            read: Self.readDocument).first
    }

    @discardableResult
    public func removeDocument(id: String, collection: String, pluginID: String) -> Bool {
        database()?.run(
            "DELETE FROM plugin_collections WHERE plugin_id = ? AND collection = ? AND id = ?",
            [.text(pluginID), .text(collection), .text(id)]) ?? false
    }

    /// Documents matching the given index fields, newest write first.
    public func find(
        collection: String, pluginID: String, k1: String? = nil, k2: String? = nil,
        limit: Int? = nil, offset: Int = 0
    ) -> [PluginCollectionDocument] {
        guard let database = database() else { return [] }
        var sql = "SELECT id, json, k1, k2 FROM plugin_collections "
            + "WHERE plugin_id = ? AND collection = ?"
        var parameters: [PluginSQLValue] = [.text(pluginID), .text(collection)]
        if let k1 { sql += " AND k1 = ?"; parameters.append(.text(k1)) }
        if let k2 { sql += " AND k2 = ?"; parameters.append(.text(k2)) }
        sql += " ORDER BY updated_at DESC, id ASC"
        // SQLite needs a LIMIT before it will honour an OFFSET; -1 is "no limit".
        sql += " LIMIT ? OFFSET ?"
        parameters.append(.int(limit ?? -1))
        parameters.append(.int(max(0, offset)))
        return database.query(sql, parameters, read: Self.readDocument)
    }

    public func count(
        collection: String, pluginID: String, k1: String? = nil, k2: String? = nil
    ) -> Int {
        guard let database = database() else { return 0 }
        var sql = "SELECT COUNT(*) FROM plugin_collections "
            + "WHERE plugin_id = ? AND collection = ?"
        var parameters: [PluginSQLValue] = [.text(pluginID), .text(collection)]
        if let k1 { sql += " AND k1 = ?"; parameters.append(.text(k1)) }
        if let k2 { sql += " AND k2 = ?"; parameters.append(.text(k2)) }
        return database.query(sql, parameters) { PluginSQLRow.int($0, 0) }.first ?? 0
    }

    private static func readDocument(_ statement: OpaquePointer) -> PluginCollectionDocument {
        PluginCollectionDocument(
            id: PluginSQLRow.text(statement, 0) ?? "",
            json: PluginSQLRow.text(statement, 1) ?? "null",
            k1: PluginSQLRow.text(statement, 2),
            k2: PluginSQLRow.text(statement, 3))
    }
}

// MARK: - Settings

extension PluginKVStore {

    /// The settings half of the seam. A settings value is one `plugin_kv` row
    /// under `settings.<key>`; a SECRET field's value is in the Keychain, and
    /// the row holds only the marker that says one is set.
    public func settingsValueJSON(pluginID: String, key: String) -> String? {
        valueJSON(pluginID: pluginID, key: Self.settingsKeyPrefix + key)
    }

    public func setValueJSON(_ json: String?, pluginID: String, key: String) throws {
        guard setValueJSON(json, pluginID: pluginID, key: key, now: Date()) else {
            throw PluginStoreError.fileSystem(detail: "plugin_kv refused the write")
        }
    }

    public func allValuesJSON(pluginID: String) -> [String: String] {
        var values: [String: String] = [:]
        for key in keys(pluginID: pluginID) {
            guard let json = valueJSON(pluginID: pluginID, key: key) else { continue }
            values[key] = json
        }
        return values
    }

    public func isConfigured(pluginID: String, fields: [PluginSettingField]) -> Bool {
        let values = allValuesJSON(pluginID: pluginID)
        // The key a settings value is stored under is the field's own name:
        // both writers — `luna.settings.set` and the settings screen — go
        // through `setValueJSON`, which prefixes nothing.
        for field in fields where field.isRequired {
            guard let json = values[field.key],
                  !json.isEmpty, json != "null", json != "\"\"", json != "false"
            else { return false }
        }
        return true
    }
}
