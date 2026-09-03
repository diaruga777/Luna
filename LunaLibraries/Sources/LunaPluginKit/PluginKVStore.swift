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

/// Aggregate limits are per plugin, not shared by all installed plugins. Bytes
/// count the UTF-8 JSON payloads persisted in each table; replacing a row only
/// charges the delta. A transaction checks the current usage and writes the row
/// together, so concurrent processes cannot pass a stale quota check.
public struct PluginStorageQuotas: Equatable, Sendable {
    public var maxKVKeys: Int
    public var maxKVBytes: Int
    public var maxCollectionRows: Int
    public var maxCollectionBytes: Int

    public init(
        maxKVKeys: Int = 1_024, maxKVBytes: Int = 5 * 1024 * 1024,
        maxCollectionRows: Int = 10_000, maxCollectionBytes: Int = 10 * 1024 * 1024
    ) {
        self.maxKVKeys = max(0, maxKVKeys); self.maxKVBytes = max(0, maxKVBytes)
        self.maxCollectionRows = max(0, maxCollectionRows)
        self.maxCollectionBytes = max(0, maxCollectionBytes)
    }
}

public enum PluginStorageError: Error, Equatable, CustomStringConvertible {
    case storageUnavailable(String)
    case writeFailed(String)
    case quotaExceeded
    case valueTooLarge(limit: Int)

    public var code: String {
        switch self {
        case .storageUnavailable: return "storage-unavailable"
        case .writeFailed: return "write-failed"
        case .quotaExceeded: return "quota-exceeded"
        case .valueTooLarge: return "too-large"
        }
    }

    public var description: String {
        switch self {
        case .storageUnavailable(let detail): return "storage unavailable: \(detail)"
        case .writeFailed(let detail): return "storage write failed: \(detail)"
        case .quotaExceeded: return "plugin storage quota exceeded"
        case .valueTooLarge(let limit): return "value exceeds \(limit) byte limit"
        }
    }
}

/// `luna.storage` on the shared database: a plugin-scoped key/value table and
/// plugin-scoped document collections.
///
/// Every row carries the plugin id, so two plugins may use the same key or
/// collection name and never see each other's rows. A plugin SETTINGS value is
/// a row in the same table under the field's OWN bare key, which is why this
/// type is also the `PluginSettingsStoring` witness — one table, one place that
/// scopes it.
public final class PluginKVStore: PluginSettingsStoring, @unchecked Sendable {

    public static let shared = PluginKVStore()

    /// The largest value one key may hold (§6.5).
    public static let maxValueBytes = 256 * 1024

    private let fileURL: URL?
    public let quotas: PluginStorageQuotas
    private let openLock = NSLock()
    private var openedDatabase: PluginDatabase?

    /// `fileURL` is the `saves.sqlite` to use; nil means the App Group's.
    public init(fileURL: URL? = nil, quotas: PluginStorageQuotas = PluginStorageQuotas()) {
        self.fileURL = fileURL ?? PluginDatabase.sharedFileURL()
        self.quotas = quotas
    }

    private func database() throws -> PluginDatabase {
        openLock.lock()
        defer { openLock.unlock() }
        if let openedDatabase { return openedDatabase }
        guard let fileURL else {
            throw PluginStorageError.storageUnavailable("the App Group container is unavailable")
        }
        let database: PluginDatabase
        do { database = try PluginDatabase(fileURL: fileURL) }
        catch { throw Self.storageError(error) }
        openedDatabase = database
        return database
    }

    private static func storageError(_ error: Error) -> PluginStorageError {
        if let error = error as? PluginStorageError { return error }
        return .storageUnavailable(error.localizedDescription)
    }

    private static func writeError(_ error: Error) -> PluginStorageError {
        if let error = error as? PluginStorageError { return error }
        return .writeFailed(error.localizedDescription)
    }

    // MARK: - Key/value

    /// The JSON one key holds, or nil when it holds nothing.
    public func valueJSON(pluginID: String, key: String) -> String? {
        try? valueJSONChecked(pluginID: pluginID, key: key)
    }

    public func valueJSONChecked(pluginID: String, key: String) throws -> String? {
        try database().queryChecked(
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
        guard let json else {
            do { try removeValueJSONChecked(pluginID: pluginID, key: key); return true }
            catch { return false }
        }
        do { try setValueJSONChecked(json, pluginID: pluginID, key: key, now: now); return true }
        catch { return false }
    }

    public func setValueJSONChecked(
        _ json: String, pluginID: String, key: String, now: Date
    ) throws {
        guard json.utf8.count <= Self.maxValueBytes else {
            throw PluginStorageError.valueTooLarge(limit: Self.maxValueBytes)
        }
        do {
            try database().transaction { transaction in
                let old = try transaction.query(
                    "SELECT json FROM plugin_kv WHERE plugin_id = ? AND key = ?",
                    [.text(pluginID), .text(key)]) { PluginSQLRow.text($0, 0) }.first ?? nil
                let usage = try Self.usage(
                    transaction: transaction, table: "plugin_kv", pluginID: pluginID)
                let bytes = json.utf8.count - (old?.utf8.count ?? 0)
                let keys = usage.rows + (old == nil ? 1 : 0)
                guard keys <= quotas.maxKVKeys, usage.bytes + bytes <= quotas.maxKVBytes else {
                    throw PluginStorageError.quotaExceeded
                }
                try transaction.run(
                    """
                    INSERT INTO plugin_kv (plugin_id, key, json, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(plugin_id, key) DO UPDATE SET json = excluded.json,
                        updated_at = excluded.updated_at
                    """,
                    [.text(pluginID), .text(key), .text(json),
                     .double(now.timeIntervalSince1970)])
            }
        } catch let error as PluginStorageError { throw error }
        catch { throw Self.writeError(error) }
    }

    public func removeValueJSONChecked(pluginID: String, key: String) throws {
        do {
            guard try database().runChecked(
                "DELETE FROM plugin_kv WHERE plugin_id = ? AND key = ?",
                [.text(pluginID), .text(key)]) else {
                throw PluginStorageError.writeFailed("delete was refused")
            }
        } catch let error as PluginStorageError { throw error }
        catch { throw Self.writeError(error) }
    }

    /// The plugin's keys, optionally those under one prefix, in key order.
    public func keys(pluginID: String, prefix: String? = nil) -> [String] {
        (try? keysChecked(pluginID: pluginID, prefix: prefix)) ?? []
    }

    public func keysChecked(pluginID: String, prefix: String? = nil) throws -> [String] {
        let database = try database()
        if let prefix, !prefix.isEmpty {
            return try database.queryChecked(
                "SELECT key FROM plugin_kv WHERE plugin_id = ? AND key LIKE ? ESCAPE '\\' "
                    + "ORDER BY key",
                [.text(pluginID), .text(Self.likePattern(prefix))]
            ) { PluginSQLRow.text($0, 0) }.compactMap { $0 }
        }
        return try database.queryChecked(
            "SELECT key FROM plugin_kv WHERE plugin_id = ? ORDER BY key", [.text(pluginID)]
        ) { PluginSQLRow.text($0, 0) }.compactMap { $0 }
    }

    /// Removes everything one plugin stored — its keys and every collection.
    /// A deleted plugin leaves no rows behind.
    public func removeAll(pluginID: String) {
        try? removeAllChecked(pluginID: pluginID)
    }

    public func removeAllChecked(pluginID: String) throws {
        let database = try database()
        try database.transaction { transaction in
            try transaction.run("DELETE FROM plugin_kv WHERE plugin_id = ?", [.text(pluginID)])
            try transaction.run("DELETE FROM plugin_collections WHERE plugin_id = ?", [.text(pluginID)])
        }
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
        (try? putDocumentChecked(document, collection: collection, pluginID: pluginID, now: now)) != nil
    }

    public func putDocumentChecked(
        _ document: PluginCollectionDocument, collection: String, pluginID: String,
        now: Date = Date()
    ) throws {
        guard document.json.utf8.count <= Self.maxValueBytes else {
            throw PluginStorageError.valueTooLarge(limit: Self.maxValueBytes)
        }
        do {
            try database().transaction { transaction in
                let old = try transaction.query(
                    "SELECT json FROM plugin_collections WHERE plugin_id = ? AND collection = ? AND id = ?",
                    [.text(pluginID), .text(collection), .text(document.id)]) { PluginSQLRow.text($0, 0) }.first ?? nil
                let usage = try Self.usage(
                    transaction: transaction, table: "plugin_collections", pluginID: pluginID)
                let bytes = document.json.utf8.count - (old?.utf8.count ?? 0)
                let rows = usage.rows + (old == nil ? 1 : 0)
                guard rows <= quotas.maxCollectionRows,
                      usage.bytes + bytes <= quotas.maxCollectionBytes else {
                    throw PluginStorageError.quotaExceeded
                }
                try transaction.run(
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
        } catch let error as PluginStorageError { throw error }
        catch { throw Self.writeError(error) }
    }

    public func document(
        id: String, collection: String, pluginID: String
    ) -> PluginCollectionDocument? {
        try? documentChecked(id: id, collection: collection, pluginID: pluginID)
    }

    public func documentChecked(
        id: String, collection: String, pluginID: String
    ) throws -> PluginCollectionDocument? {
        try database().queryChecked(
            "SELECT id, json, k1, k2 FROM plugin_collections "
                + "WHERE plugin_id = ? AND collection = ? AND id = ?",
            [.text(pluginID), .text(collection), .text(id)],
            read: Self.readDocument).first
    }

    @discardableResult
    public func removeDocument(id: String, collection: String, pluginID: String) -> Bool {
        (try? removeDocumentChecked(id: id, collection: collection, pluginID: pluginID)) ?? false
    }

    public func removeDocumentChecked(id: String, collection: String, pluginID: String) throws -> Bool {
        try database().runChecked(
            "DELETE FROM plugin_collections WHERE plugin_id = ? AND collection = ? AND id = ?",
            [.text(pluginID), .text(collection), .text(id)])
    }

    /// Documents matching the given index fields, newest write first.
    public func find(
        collection: String, pluginID: String, k1: String? = nil, k2: String? = nil,
        limit: Int? = nil, offset: Int = 0
    ) -> [PluginCollectionDocument] {
        (try? findChecked(
            collection: collection, pluginID: pluginID, k1: k1, k2: k2,
            limit: limit, offset: offset)) ?? []
    }

    public func findChecked(
        collection: String, pluginID: String, k1: String? = nil, k2: String? = nil,
        limit: Int? = nil, offset: Int = 0
    ) throws -> [PluginCollectionDocument] {
        let database = try database()
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
        return try database.queryChecked(sql, parameters, read: Self.readDocument)
    }

    public func count(
        collection: String, pluginID: String, k1: String? = nil, k2: String? = nil
    ) -> Int {
        (try? countChecked(collection: collection, pluginID: pluginID, k1: k1, k2: k2)) ?? 0
    }

    public func countChecked(
        collection: String, pluginID: String, k1: String? = nil, k2: String? = nil
    ) throws -> Int {
        let database = try database()
        var sql = "SELECT COUNT(*) FROM plugin_collections "
            + "WHERE plugin_id = ? AND collection = ?"
        var parameters: [PluginSQLValue] = [.text(pluginID), .text(collection)]
        if let k1 { sql += " AND k1 = ?"; parameters.append(.text(k1)) }
        if let k2 { sql += " AND k2 = ?"; parameters.append(.text(k2)) }
        return try database.queryChecked(sql, parameters) { PluginSQLRow.int($0, 0) }.first ?? 0
    }

    private static func usage(
        transaction: PluginDatabaseTransaction, table: String, pluginID: String
    ) throws -> (rows: Int, bytes: Int) {
        let rows = try transaction.query(
            "SELECT COUNT(*), COALESCE(SUM(length(CAST(json AS BLOB))), 0) FROM \(table) "
                + "WHERE plugin_id = ?", [.text(pluginID)]) { (
                    PluginSQLRow.int($0, 0), PluginSQLRow.int($0, 1))
        }.first ?? (0, 0)
        return rows
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
    /// under the field's own key; a SECRET field's value is in the Keychain, and
    /// the row holds only the marker that says one is set.
    public func setValueJSON(_ json: String?, pluginID: String, key: String) throws {
        if let json {
            try setValueJSONChecked(json, pluginID: pluginID, key: key, now: Date())
        } else {
            try removeValueJSONChecked(pluginID: pluginID, key: key)
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
