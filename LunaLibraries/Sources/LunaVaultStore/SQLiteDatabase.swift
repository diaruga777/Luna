import Foundation
import SQLite3

public enum VaultStoreError: Error, Equatable {
    case sqlite(String)
    case containerUnavailable
    case notPaired
    case invalidRecord(String)
}

/// One serialized SQLite connection. WAL, `busy_timeout`, foreign keys on.
/// On iOS the file opens with Data Protection
/// (`SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION`).
final class SQLiteDatabase: @unchecked Sendable {
    enum Value {
        case null
        case integer(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    struct Row {
        let statement: OpaquePointer

        func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
        func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
        func text(_ index: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: pointer)
        }
        func optionalText(_ index: Int32) -> String? { isNull(index) ? nil : text(index) }
        func blob(_ index: Int32) -> Data {
            let length = Int(sqlite3_column_bytes(statement, index))
            guard length > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
            return Data(bytes: pointer, count: length)
        }
        func optionalDouble(_ index: Int32) -> Double? { isNull(index) ? nil : double(index) }
        func optionalInt64(_ index: Int32) -> Int64? { isNull(index) ? nil : int64(index) }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "luna.vault.store.sqlite")

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        #if os(iOS)
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        #endif
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open"
            throw VaultStoreError.sqlite(message)
        }
        db = opened
        sqlite3_busy_timeout(opened, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    func sync<T>(_ body: () throws -> T) throws -> T {
        try queue.sync(execute: body)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try queue.sync {
            try executeUnlocked("BEGIN IMMEDIATE")
            do {
                let value = try body()
                try executeUnlocked("COMMIT")
                return value
            } catch {
                try? executeUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        try queue.sync { try executeUnlocked(sql, values) }
    }

    /// Callers already inside `sync`/`transaction` use the unlocked forms.
    func executeUnlocked(_ sql: String, _ values: [Value] = []) throws {
        try statement(sql, values) { stmt in
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE || status == SQLITE_ROW else { throw errorNow() }
        }
    }

    func queryUnlocked(_ sql: String, _ values: [Value] = [], _ body: (Row) throws -> Void) throws {
        try statement(sql, values) { stmt in
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return }
                guard status == SQLITE_ROW else { throw errorNow() }
                try body(Row(statement: stmt))
            }
        }
    }

    func scalarUnlocked(_ sql: String, _ values: [Value] = []) throws -> Int64 {
        var result: Int64 = 0
        try queryUnlocked(sql, values) { result = $0.int64(0) }
        return result
    }

    var changes: Int { Int(sqlite3_changes(db)) }

    private func errorNow() -> VaultStoreError {
        .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }

    private func statement(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw errorNow() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .integer(let v): sqlite3_bind_int64(stmt, index, v)
            case .double(let v): sqlite3_bind_double(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, transient)
            case .blob(let v):
                if v.isEmpty {
                    sqlite3_bind_zeroblob(stmt, index, 0)
                } else {
                    v.withUnsafeBytes { raw in _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), transient) }
                }
            }
        }
        try body(stmt)
    }
}
