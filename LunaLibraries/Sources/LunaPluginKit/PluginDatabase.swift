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

    init?(fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            | Self.openFileProtectionCompleteUntilFirstUserAuthentication
        guard sqlite3_open_v2(fileURL.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            return nil
        }
        handle = opened
        queue.sync {
            sqlite3_busy_timeout(opened, 5000)
            exec("PRAGMA journal_mode = WAL")
            exec("PRAGMA synchronous = NORMAL")
            exec("PRAGMA foreign_keys = ON")
            for statement in Self.tableStatements { exec(statement) }
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// `SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION`, spelled
    /// out because the macro is not imported into Swift. It is what lets the
    /// extensions write while the device is locked.
    private static let openFileProtectionCompleteUntilFirstUserAuthentication: Int32 = 0x0040_0000

    // MARK: - Running statements

    /// Binds `parameters` in order and steps the statement to completion.
    @discardableResult
    func run(_ sql: String, _ parameters: [PluginSQLValue] = []) -> Bool {
        queue.sync {
            guard let statement = prepare(sql, parameters) else { return false }
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            return status == SQLITE_DONE || status == SQLITE_ROW
        }
    }

    /// Steps the statement and hands each row to `read`.
    func query<T>(
        _ sql: String, _ parameters: [PluginSQLValue] = [],
        read: (OpaquePointer) -> T
    ) -> [T] {
        queue.sync {
            guard let statement = prepare(sql, parameters) else { return [] }
            defer { sqlite3_finalize(statement) }
            var rows: [T] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(read(statement))
            }
            return rows
        }
    }

    private func prepare(_ sql: String, _ parameters: [PluginSQLValue]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
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

    private func exec(_ sql: String) {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    /// The `saves.sqlite` every Luna process shares.
    static func sharedFileURL(fileManager: FileManager = .default) -> URL? {
        AppConfig.sharedContainerURL(fileManager)?.appendingPathComponent("saves.sqlite")
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
