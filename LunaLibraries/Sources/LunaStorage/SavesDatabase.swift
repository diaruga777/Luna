//
//  SavesDatabase.swift
//  LunaStorage
//

import Foundation
import SQLite3

/// A SQLite failure carrying the library's own message, so a log line says what
/// went wrong rather than just "the write failed".
struct SavesDatabaseError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    let sql: String?

    var description: String {
        let suffix = sql.map { " — \($0)" } ?? ""
        return "sqlite(\(code)): \(message)\(suffix)"
    }

    /// Whether SQLite refused because someone else holds the file. The primary
    /// code is the low byte — the extended codes (`SQLITE_BUSY_SNAPSHOT` and
    /// friends) carry it in the same place.
    var isBusy: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_BUSY || primary == SQLITE_LOCKED
    }
}

/// This process's one connection to the shared saves database.
///
/// Every Luna process — the four apps, their share / action / Safari extensions,
/// the App Intents — opens its own connection to the same file in the App Group
/// container. WAL is what lets them read while one of them writes; `busy_timeout`
/// is what makes a second writer wait its turn instead of failing outright.
///
/// One connection per process, behind one serial queue: SQLite would tolerate
/// concurrent use of the handle, but the prepared-statement cache below would
/// not, and serialising also gives the store a single place to hold its
/// in-memory list. Call `perform` / `transaction` from anywhere; call `execute`
/// / `prepare` / `commitDataVersion` only from inside one of them.
final class SavesDatabase {

    /// Schema revision written to `PRAGMA user_version`. Bump it when the tables
    /// change and add the migration next to `SavesSchema.create`.
    static let schemaVersion: Int32 = 16

    /// The database file. Its `-wal` / `-shm` siblings live beside it — the
    /// standard cross-process arrangement, and the reason the App Group
    /// directory (not just this file) is what other processes need access to.
    let fileURL: URL

    private var handle: OpaquePointer?
    private let queue: DispatchQueue
    /// Prepared statements kept alive between calls, keyed by their SQL. The hot
    /// paths (a point read of one save, a resume-position update) re-prepare
    /// nothing.
    private var statements: [String: OpaquePointer] = [:]

    /// Opens (creating if needed) the database at `fileURL` and applies the
    /// cross-process configuration. Throws when the file cannot be opened at
    /// all — the caller has no store in that case and says so.
    init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.queue = DispatchQueue(label: "com.hsanabria.luna.savesDatabase")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var opened: OpaquePointer?
        // `FULLMUTEX` is belt-and-braces against a stray call from another
        // thread; `FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION` is what
        // lets the extensions and the mail-fetch background task write while the
        // device is locked, and it applies to the `-wal`/`-shm` siblings too.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            | Self.openFileProtectionCompleteUntilFirstUserAuthentication
        let status = sqlite3_open_v2(fileURL.path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened { sqlite3_close_v2(opened) }
            throw SavesDatabaseError(code: status, message: message, sql: nil)
        }
        self.handle = opened
        try queue.sync {
            try configure()
            try SavesSchema.create(in: self)
        }
        applyFileProtection()
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close_v2(handle) }
    }

    /// `SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION` from the
    /// platform's `sqlite3.h`, spelled out because the macro is not imported into
    /// Swift.
    static let openFileProtectionCompleteUntilFirstUserAuthentication: Int32 = 0x0030_0000

    // MARK: - Configuration

    /// Journal mode, timeouts and per-connection flags. `journal_mode` is
    /// persistent in the file; the rest are per connection and so are re-applied
    /// by every process that opens it.
    private func configure() throws {
        // A second writer waits up to five seconds for the first to commit
        // instead of returning SQLITE_BUSY. Set before anything else can block.
        sqlite3_busy_timeout(handle, 5000)
        // Switching journal mode takes a lock the busy TIMEOUT does not cover, and
        // every process racing to be the first to open a new file attempts the
        // switch at once — so this one is retried by hand. A file already in WAL
        // answers without locking anything.
        try retryingWhileBusy { try execute("PRAGMA journal_mode = WAL") }
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    /// Runs `body`, retrying while SQLite says the file is busy.
    ///
    /// `busy_timeout` covers a writer waiting for the write lock, which is the
    /// common case and needs nothing here. It does NOT cover the two places this
    /// wraps: the journal-mode switch above, and a transaction that loses its
    /// lock race outright rather than being made to wait. A save must not
    /// disappear because two processes reached the file in the same millisecond.
    func retryingWhileBusy<T>(attempts: Int = 6, _ body: () throws -> T) throws -> T {
        var attempt = 1
        while true {
            do {
                return try body()
            } catch let error as SavesDatabaseError where error.isBusy && attempt < attempts {
                // Back off a little further each time, so a queue of writers
                // spreads out instead of colliding again immediately.
                Thread.sleep(forTimeInterval: 0.02 * Double(attempt))
                attempt += 1
            }
        }
    }

    /// Marks the database — and, once WAL has made them, its siblings — as
    /// readable after the first unlock following a boot. The open flag above
    /// already asks for this; a file left behind by an older build (or created
    /// before the flag was passed) is fixed here.
    private func applyFileProtection() {
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        let fileManager = FileManager.default
        for path in [fileURL.path, fileURL.path + "-wal", fileURL.path + "-shm"]
        where fileManager.fileExists(atPath: path) {
            try? fileManager.setAttributes(attributes, ofItemAtPath: path)
        }
    }

    // MARK: - Serialised access

    /// Runs `body` with exclusive use of the connection.
    func perform<T>(_ body: (SavesDatabase) throws -> T) throws -> T {
        try queue.sync { try body(self) }
    }

    /// Runs `body` inside one immediate transaction: everything it writes lands
    /// together or not at all, and a second process writing at the same moment
    /// takes its turn rather than interleaving.
    ///
    /// `BEGIN IMMEDIATE` (not deferred) because every caller here intends to
    /// write: taking the write lock up front means the wait happens before any
    /// work, instead of a mid-transaction `SQLITE_BUSY`. `body` may therefore run
    /// twice — once for a lock race it lost, once for the attempt that commits —
    /// so anything it does outside SQL must be idempotent (the file writes inside
    /// `saveContent` and `setThumbnail` are: same bytes, same path).
    func transaction<T>(_ body: (SavesDatabase) throws -> T) throws -> T {
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

    /// Runs `body` inside one deferred transaction, so several statements see ONE
    /// snapshot of the file even while another process is committing. A save is
    /// assembled from five tables; read without this, the tables could come from
    /// either side of a sibling's write.
    ///
    /// Call it from inside `perform` — it does not take the queue itself.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN DEFERRED")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Statements

    /// Runs one statement with no results.
    func execute(_ sql: String) throws {
        assertOnQueue()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw SavesDatabaseError(code: status, message: message, sql: sql)
        }
        sqlite3_free(errorMessage)
    }

    /// A cached, reset statement ready to bind. Cached because the store runs the
    /// same handful of statements over and over; `SQLITE_PREPARE_PERSISTENT` tells
    /// SQLite to keep its own allocations around for exactly that pattern.
    func prepare(_ sql: String) throws -> SavesStatement {
        assertOnQueue()
        if let existing = statements[sql] {
            sqlite3_reset(existing)
            sqlite3_clear_bindings(existing)
            return SavesStatement(handle: existing, sql: sql, database: self)
        }
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v3(
            handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil)
        guard status == SQLITE_OK, let prepared else {
            throw SavesDatabaseError(
                code: status, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        statements[sql] = prepared
        return SavesStatement(handle: prepared, sql: sql, database: self)
    }

    /// Binds, runs and resets a statement that returns no rows.
    func run(_ sql: String, _ bind: (SavesStatement) throws -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { statement.reset() }
        try bind(statement)
        while try statement.step() {}
    }

    /// Binds, runs and resets a statement, handing each result row to `row`.
    func query(
        _ sql: String, _ bind: (SavesStatement) throws -> Void = { _ in },
        row: (SavesStatement) throws -> Void
    ) throws {
        let statement = try prepare(sql)
        defer { statement.reset() }
        try bind(statement)
        while try statement.step() { try row(statement) }
    }

    /// The single scalar of a one-row query, or nil when the query returned no row.
    func scalarInt(_ sql: String, _ bind: (SavesStatement) throws -> Void = { _ in }) throws -> Int64? {
        var result: Int64?
        try query(sql, bind) { row in
            if result == nil { result = row.int64(0) }
        }
        return result
    }

    // MARK: - Cross-process change detection

    /// `PRAGMA data_version`, which changes only when ANOTHER connection commits
    /// to this file. That is exactly the question an in-memory cache has to ask:
    /// this process's own writes refresh the cache directly, so a value that
    /// still matches means nothing has happened elsewhere.
    var dataVersion: Int64 {
        ((try? scalarInt("PRAGMA data_version")) ?? nil) ?? 0
    }

    /// Total rows this connection has inserted, updated or deleted since it was
    /// opened. Lets a test prove a no-op mutation wrote nothing at all.
    var totalChanges: Int {
        Int(sqlite3_total_changes(handle))
    }

    /// The message for the last failure on this connection.
    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func assertOnQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }
}

/// One prepared statement: typed binds by 1-based parameter index, typed column
/// reads by 0-based column index.
///
/// Dates are `REAL` seconds since the reference date and `Decimal`s are `TEXT`.
/// A date has to round-trip to the same `Date` a caller passed in (items compare
/// by value, and the deck sorts on them), which a double does exactly and a
/// formatted day string does not; a decimal price must not be rounded, which
/// `TEXT` guarantees and `REAL` does not.
struct SavesStatement {
    fileprivate let handle: OpaquePointer
    fileprivate let sql: String
    fileprivate let database: SavesDatabase

    // MARK: - Bind

    func bind(_ index: Int32, _ value: String?) throws {
        guard let value else { try check(sqlite3_bind_null(handle, index)); return }
        try check(sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT))
    }

    func bind(_ index: Int32, _ value: Int?) throws {
        guard let value else { try check(sqlite3_bind_null(handle, index)); return }
        try check(sqlite3_bind_int64(handle, index, Int64(value)))
    }

    func bind(_ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    /// Named rather than a nullable overload of the above, so a call passing a
    /// non-optional `Int64` cannot become ambiguous.
    func bind(_ index: Int32, int64 value: Int64?) throws {
        guard let value else { try check(sqlite3_bind_null(handle, index)); return }
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

    func bind(_ index: Int32, decimal: Decimal?) throws {
        try bind(index, decimal.map { SavesStatement.text(for: $0) })
    }

    func bind(_ index: Int32, uuid: UUID) throws {
        try bind(index, uuid.uuidString)
    }

    /// A decimal's exact digits, with a `.` separator whatever the locale is.
    static func text(for decimal: Decimal) -> String {
        NSDecimalNumber(decimal: decimal)
            .description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Step

    /// Advances to the next row; false once the statement is done.
    @discardableResult
    func step() throws -> Bool {
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SavesDatabaseError(code: status, message: database.lastErrorMessage, sql: sql)
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

    func int(_ column: Int32) -> Int? {
        isNull(column) ? nil : Int(sqlite3_column_int64(handle, column))
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func int64OrNil(_ column: Int32) -> Int64? {
        isNull(column) ? nil : sqlite3_column_int64(handle, column)
    }

    func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(handle, column)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(handle, column) != 0
    }

    func date(_ column: Int32) -> Date? {
        double(column).map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    func decimal(_ column: Int32) -> Decimal? {
        guard let text = string(column) else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func check(_ status: Int32) throws {
        guard status != SQLITE_OK else { return }
        throw SavesDatabaseError(code: status, message: database.lastErrorMessage, sql: sql)
    }
}

/// `SQLITE_TRANSIENT`: SQLite copies the bound bytes, so a Swift string does not
/// have to outlive the bind call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
