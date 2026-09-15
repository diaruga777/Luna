import Foundation
import SQLite3

public enum CompanionIndexError: Error, Equatable {
    case sqlite(String)
    case corruptRow(String)
    case unknownPeer(String)
}

/// One SQLite connection. Every call runs on the owner's serial queue; the
/// owner (`CompanionIndex`) never hands the handle out.
final class CompanionSQLite {
    enum Value {
        case null
        case int(Int64)
        case text(String)
        case blob(Data)
    }

    struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: pointer)
        }
        func blob(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: count)
        }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    }

    private let handle: OpaquePointer

    init(path: String) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open"
            if let opened { sqlite3_close_v2(opened) }
            throw CompanionIndexError.sqlite(message)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? sql
            sqlite3_free(message)
            throw CompanionIndexError.sqlite(text)
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        try query(sql, values) { _ in }
    }

    func query(_ sql: String, _ values: [Value] = [], _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CompanionIndexError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                try body(Row(statement: statement))
            } else if step == SQLITE_DONE {
                return
            } else {
                throw CompanionIndexError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let column = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, column)
            case .int(let number):
                result = sqlite3_bind_int64(statement, column, number)
            case .text(let string):
                result = sqlite3_bind_text(statement, column, string, -1, transient)
            case .blob(let data):
                result = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, column, raw.baseAddress, Int32(raw.count), transient)
                }
            }
            guard result == SQLITE_OK else {
                throw CompanionIndexError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
