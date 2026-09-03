//
//  PluginDatabase.swift
//  LunaPluginKit
//

import Foundation
import LunaAppConfig
import SQLite3

/// This process's connection to the plugin tables in `saves.sqlite`.
///
/// `LunaStorage` keeps its own connection private to that module, and
/// `LunaPluginKit` is linked by the Safari appex, which opens no `SavesStore` at
/// all. So the plugin tier opens its own connection to the SAME file, with the
/// same cross-process configuration: WAL, a busy timeout, foreign keys on, one
/// serial queue.
///
/// It creates the plugin tables it uses if they are absent, so a process that
/// reaches the file before any `SavesStore` still has somewhere to write. The
/// statements match `SavesSchema` exactly; `PluginSchemaParityTests` compares
/// the two against a real database.
enum PluginDatabaseError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)
    case sqlite(code: Int32, message: String, sql: String?)

    var description: String {
        switch self {
        case .unavailable(let detail): return "storage unavailable: \(detail)"
        case .sqlite(let code, let message, let sql):
            return "sqlite(\(code)): \(message)\(sql.map { " — \($0)" } ?? "")"
        }
    }
}

final class PluginDatabase {

    static let tableStatements = [
        """
        CREATE TABLE IF NOT EXISTS plugin_kv (
            plugin_id  TEXT NOT NULL,
            key        TEXT NOT NULL,
            json       TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (plugin_id, key)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS plugin_collections (
            plugin_id  TEXT NOT NULL,
            collection TEXT NOT NULL,
            id         TEXT NOT NULL,
            k1         TEXT,
            k2         TEXT,
            json       TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (plugin_id, collection, id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS plugin_browser_requests (
            save_id      TEXT PRIMARY KEY NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
            plugin_id    TEXT NOT NULL,
            request_json TEXT NOT NULL,
            result_json  TEXT,
            created_at   REAL NOT NULL,
            completed_at REAL
        ) WITHOUT ROWID
        """,
        """
        CREATE INDEX IF NOT EXISTS plugin_collections_k1
            ON plugin_collections(plugin_id, collection, k1)
        """,
        """
        CREATE INDEX IF NOT EXISTS plugin_collections_k2
            ON plugin_collections(plugin_id, collection, k2)
        """,
    ]

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.hsanabria.luna.pluginDatabase")

    init(fileURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw PluginDatabaseError.unavailable(error.localizedDescription)
        }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            | Self.openFileProtectionCompleteUntilFirstUserAuthentication
        let status = sqlite3_open_v2(fileURL.path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened { sqlite3_close_v2(opened) }
            throw PluginDatabaseError.sqlite(code: status, message: message, sql: nil)
        }
        handle = opened
        do {
            try queue.sync {
                sqlite3_busy_timeout(opened, 5000)
                try execChecked("PRAGMA journal_mode = WAL")
                try execChecked("PRAGMA synchronous = NORMAL")
                try execChecked("PRAGMA foreign_keys = ON")
                for statement in Self.tableStatements { try execChecked(statement) }
            }
        } catch {
            sqlite3_close_v2(opened)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// `SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION`, spelled
    /// out because the macro is not imported into Swift. It is what lets the
    /// extensions write while the device is locked.
    static let openFileProtectionCompleteUntilFirstUserAuthentication: Int32 = 0x0030_0000

    // MARK: - Running statements

    /// Binds `parameters` in order and steps the statement to completion.
    @discardableResult
    func run(_ sql: String, _ parameters: [PluginSQLValue] = []) -> Bool {
        (try? runChecked(sql, parameters)) ?? false
    }

    @discardableResult
    func runChecked(_ sql: String, _ parameters: [PluginSQLValue] = []) throws -> Bool {
        try queue.sync { try runLocked(sql, parameters) }
    }

    fileprivate func runLocked(_ sql: String, _ parameters: [PluginSQLValue]) throws -> Bool {
        guard let statement = try prepareChecked(sql, parameters) else { return false }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw sqliteError(status, sql: sql)
        }
        return true
    }

    /// Executes several reads and writes under one SQLite transaction. Quota
    /// checks use this boundary so two processes cannot each pass a check and
    /// then exceed the same plugin's aggregate limit.
    func transaction<T>(_ body: (PluginDatabaseTransaction) throws -> T) throws -> T {
        try queue.sync {
            try execChecked("BEGIN IMMEDIATE")
            do {
                let result = try body(PluginDatabaseTransaction(database: self))
                try execChecked("COMMIT")
                return result
            } catch {
                _ = try? execChecked("ROLLBACK")
                throw error
            }
        }
    }

    func query<T>(
        _ sql: String, _ parameters: [PluginSQLValue] = [],
        read: (OpaquePointer) -> T
    ) -> [T] {
        (try? queryChecked(sql, parameters, read: read)) ?? []
    }

    func queryChecked<T>(
        _ sql: String, _ parameters: [PluginSQLValue] = [],
        read: (OpaquePointer) -> T
    ) throws -> [T] {
        try queue.sync { try queryLocked(sql, parameters, read: read) }
    }

    fileprivate func queryLocked<T>(
        _ sql: String, _ parameters: [PluginSQLValue] = [],
        read: (OpaquePointer) -> T
    ) throws -> [T] {
        guard let statement = try prepareChecked(sql, parameters) else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { rows.append(read(statement)); continue }
            if status == SQLITE_DONE { return rows }
            throw sqliteError(status, sql: sql)
        }
    }

    private func prepareChecked(_ sql: String, _ parameters: [PluginSQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw sqliteError(status, sql: sql)
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .double(let number):
                sqlite3_bind_double(statement, index, number)
            case .int(let number):
                sqlite3_bind_int64(statement, index, Int64(number))
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    /// `SQLITE_TRANSIENT`: SQLite copies the bytes, so a Swift string does not
    /// have to outlive the bind.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    private func execChecked(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw sqliteError(status, sql: sql) }
    }

    private func sqliteError(_ status: Int32, sql: String?) -> PluginDatabaseError {
        PluginDatabaseError.sqlite(
            code: status, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error",
            sql: sql)
    }

    /// The `saves.sqlite` every Luna process shares.
    static func sharedFileURL(fileManager: FileManager = .default) -> URL? {
        AppConfig.sharedContainerURL(fileManager)?.appendingPathComponent("saves.sqlite")
    }
}

/// A transaction-scoped view used by stores that need an atomic read/check/write.
final class PluginDatabaseTransaction {
    fileprivate let database: PluginDatabase
    fileprivate init(database: PluginDatabase) { self.database = database }

    func query<T>(
        _ sql: String, _ parameters: [PluginSQLValue] = [], read: (OpaquePointer) -> T
    ) throws -> [T] { try database.queryLocked(sql, parameters, read: read) }

    @discardableResult
    func run(_ sql: String, _ parameters: [PluginSQLValue] = []) throws -> Bool {
        try database.runLocked(sql, parameters)
    }
}

/// The four column types the plugin tables use.
enum PluginSQLValue {
    case text(String)
    case double(Double)
    case int(Int)
    case null
}

/// Reads one column of a stepped row.
enum PluginSQLRow {
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    static func int(_ statement: OpaquePointer, _ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    static func double(_ statement: OpaquePointer, _ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    static func isNull(_ statement: OpaquePointer, _ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }
}
