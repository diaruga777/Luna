import Foundation
import SQLite3

/// A SQLite failure carrying the library's own message, so a log line says what
/// went wrong rather than just "the write failed".
public struct WriterDatabaseError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        let suffix = sql.map { " — \($0)" } ?? ""
        return "sqlite(\(code)): \(message)\(suffix)"
    }

    /// Whether SQLite refused because someone else holds the file. The primary
    /// code is the low byte; the extended codes carry it in the same place.
    var isBusy: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_BUSY || primary == SQLITE_LOCKED
    }
}

/// This process's one connection to `writer.sqlite`.
///
/// Luna Writer is a single app with no extensions, so the file has one writer
/// at a time. It still runs WAL with a `busy_timeout`: the folder watcher and
/// the note index write from background queues while the editor reads, and WAL
/// is what lets those overlap. One connection behind one serial queue, because
/// the prepared-statement cache below is not thread-safe.
///
/// Call `perform` / `transaction` from anywhere; call `execute` / `prepare` /
/// `run` / `query` only from inside one of them.
public final class WriterDatabase {

    /// Schema revision in `PRAGMA user_version`. Bump it and add a step to
    /// `WriterSchema.migrations` when the tables change.
    public static let schemaVersion: Int32 = 1

    public let fileURL: URL

    private var handle: OpaquePointer?
    private let queue: DispatchQueue
    private var statements: [String: OpaquePointer] = [:]

    /// Opens (creating if needed) the database at `fileURL`, applies the
    /// connection settings and brings the schema up to `schemaVersion`.
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.queue = DispatchQueue(label: "com.hsanabria.luna.writerDatabase")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(fileURL.path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened { sqlite3_close_v2(opened) }
            throw WriterDatabaseError(code: status, message: message, sql: nil)
        }
        self.handle = opened
        try queue.sync {
            try configure()
            try WriterSchema.migrate(self)
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close_v2(handle) }
    }

    private func configure() throws {
        sqlite3_busy_timeout(handle, 5000)
        // The journal-mode switch takes a lock that `busy_timeout` does not
        // cover, so it is the one statement retried by hand.
        try retryingWhileBusy { try execute("PRAGMA journal_mode = WAL") }
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    func retryingWhileBusy<T>(attempts: Int = 6, _ body: () throws -> T) throws -> T {
        var attempt = 1
        while true {
            do {
                return try body()
            } catch let error as WriterDatabaseError where error.isBusy && attempt < attempts {
                Thread.sleep(forTimeInterval: 0.02 * Double(attempt))
                attempt += 1
            }
        }
    }

    // MARK: - Serialised access

    /// Runs `body` with exclusive use of the connection.
    public func perform<T>(_ body: (WriterDatabase) throws -> T) throws -> T {
        try queue.sync { try body(self) }
    }

    /// Runs `body` inside one immediate transaction. `body` may run twice when
    /// a lock race is retried, so anything it does outside SQL must be
    /// idempotent.
    public func transaction<T>(_ body: (WriterDatabase) throws -> T) throws -> T {
        try queue.sync {
            try retryingWhileBusy {
                try execute("BEGIN IMMEDIATE")
                do {
                    let result = try body(self)
                    try execute("COMMIT")
                    return result
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
        }
    }

    // MARK: - Statements

    func execute(_ sql: String) throws {
        assertOnQueue()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw WriterDatabaseError(code: status, message: message, sql: sql)
        }
        sqlite3_free(errorMessage)
    }

    /// A cached, reset statement ready to bind. `SQLITE_PREPARE_PERSISTENT`
    /// suits the handful of statements this store runs over and over.
    func prepare(_ sql: String) throws -> WriterStatement {
        assertOnQueue()
        if let existing = statements[sql] {
            sqlite3_reset(existing)
            sqlite3_clear_bindings(existing)
            return WriterStatement(handle: existing, sql: sql, database: self)
        }
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v3(
            handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil)
        guard status == SQLITE_OK, let prepared else {
            throw WriterDatabaseError(
                code: status, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        statements[sql] = prepared
        return WriterStatement(handle: prepared, sql: sql, database: self)
    }

    func run(_ sql: String, _ bind: (WriterStatement) throws -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { statement.reset() }
        try bind(statement)
        while try statement.step() {}
    }

    func query(
        _ sql: String, _ bind: (WriterStatement) throws -> Void = { _ in },
        row: (WriterStatement) throws -> Void
    ) throws {
        let statement = try prepare(sql)
        defer { statement.reset() }
        try bind(statement)
        while try statement.step() { try row(statement) }
    }

    func scalarInt(_ sql: String, _ bind: (WriterStatement) throws -> Void = { _ in }) throws -> Int64? {
        var result: Int64?
        try query(sql, bind) { row in
            if result == nil { result = row.int64(0) }
        }
        return result
    }

    /// The row id SQLite gave the last insert on this connection. The two FTS
    /// tables key off `documents.rowid` / `notes.rowid`, which is how a
    /// contentless index reaches the row it describes.
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// The schema revision recorded in the file.
    public var userVersion: Int32 {
        (try? perform { try $0.readUserVersion() }) ?? 0
    }

    func readUserVersion() throws -> Int32 {
        Int32((try scalarInt("PRAGMA user_version")) ?? 0)
    }

    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private func assertOnQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }
}

/// One prepared statement: typed binds by 1-based parameter index, typed column
/// reads by 0-based column index. Dates are `REAL` seconds since the reference
/// date, so a date round-trips to the value the caller passed.
struct WriterStatement {
    fileprivate let handle: OpaquePointer
    fileprivate let sql: String
    fileprivate let database: WriterDatabase

    // MARK: - Bind

    func bind(_ index: Int32, _ value: String?) throws {
        guard let value else { try check(sqlite3_bind_null(handle, index)); return }
        try check(sqlite3_bind_text(handle, index, value, -1, writerSQLiteTransient))
    }

    func bind(_ index: Int32, _ value: Int) throws {
        try check(sqlite3_bind_int64(handle, index, Int64(value)))
    }

    func bind(_ index: Int32, int value: Int?) throws {
        guard let value else { try check(sqlite3_bind_null(handle, index)); return }
        try check(sqlite3_bind_int64(handle, index, Int64(value)))
    }

    func bind(_ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    func bind(_ index: Int32, _ value: Double?) throws {
        guard let value else { try check(sqlite3_bind_null(handle, index)); return }
        try check(sqlite3_bind_double(handle, index, value))
    }

    func bind(_ index: Int32, _ value: Bool) throws {
        try check(sqlite3_bind_int64(handle, index, value ? 1 : 0))
    }

    func bind(_ index: Int32, date: Date?) throws {
        try bind(index, date?.timeIntervalSinceReferenceDate)
    }

    func bind(_ index: Int32, blob value: Data) throws {
        try check(value.withUnsafeBytes {
            sqlite3_bind_blob(handle, index, $0.baseAddress, Int32(value.count), writerSQLiteTransient)
        })
    }

    // MARK: - Step

    @discardableResult
    func step() throws -> Bool {
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw WriterDatabaseError(code: status, message: database.lastErrorMessage, sql: sql)
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    // MARK: - Read

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: text)
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }

    func intOrNil(_ column: Int32) -> Int? {
        isNull(column) ? nil : Int(sqlite3_column_int64(handle, column))
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }

    func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(handle, column)
    }

    func bool(_ column: Int32) -> Bool { sqlite3_column_int64(handle, column) != 0 }

    func date(_ column: Int32) -> Date? {
        double(column).map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    func blob(_ column: Int32) -> Data? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }

    func uuid(_ column: Int32) -> UUID? {
        string(column).flatMap(UUID.init(uuidString:))
    }

    private func check(_ status: Int32) throws {
        guard status != SQLITE_OK else { return }
        throw WriterDatabaseError(code: status, message: database.lastErrorMessage, sql: sql)
    }
}

/// `SQLITE_TRANSIENT`: SQLite copies the bound bytes, so a Swift value does not
/// have to outlive the bind call.
private let writerSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
