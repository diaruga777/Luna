//
//  ProductSnapshotStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import LunaModels

/// The shared, indexed store of product observations in `saves.sqlite`.
///
/// A snapshot is unique for a page and UTC day. Its identifiers are stored in
/// `product_snapshot_keys`, so a lookup reads only the observations that its
/// candidate keys can match; it never scans the complete history.
public final class ProductSnapshotStore: @unchecked Sendable {
    public static let shared = ProductSnapshotStore()

    /// Observations older than this are dropped: a year of daily points is
    /// already more graph than any product needs.
    public static let maxAgeDays = 365
    /// Hard ceiling on stored observations, oldest evicted first.
    public static let maxCount = 5000

    private let directoryURL: URL?
    private let maxCount: Int
    private let openLock = NSLock()
    private var openedDatabase: SavesDatabase?

    /// `directoryURL` is the directory containing `saves.sqlite`. It remains a
    /// parameter so tests can use an isolated database without touching the App
    /// Group container.
    public init(
        directoryURL: URL? = ProductSnapshotStore.defaultDirectoryURL(),
        maxCount: Int = ProductSnapshotStore.maxCount
    ) {
        self.directoryURL = directoryURL
        self.maxCount = maxCount
    }

    public static func defaultDirectoryURL() -> URL? {
        AppConfig.sharedContainerURL()
    }

    private var databaseFileURL: URL? {
        directoryURL?.appendingPathComponent("saves.sqlite")
    }

    private func database() -> SavesDatabase? {
        openLock.lock()
        defer { openLock.unlock() }
        if let openedDatabase { return openedDatabase }
        guard let databaseFileURL, let database = try? SavesDatabase(fileURL: databaseFileURL) else {
            return nil
        }
        BackupPolicy.includeInBackups(databaseFileURL)
        openedDatabase = database
        return database
    }

    /// The stable id of the observation for `url` on `day`. It is retained as a
    /// compact primary key for the SQLite rows and for deterministic eviction.
    public static func recordID(url: String, day: UTCDay) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array("\(url)|\(day.text)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - Writing

    /// Records one observation. Unconditional by design: there is no setting
    /// that suppresses snapshot memory.
    @discardableResult
    public func record(_ snapshot: ProductSnapshot, now: Date = Date()) -> Bool {
        guard let database = database() else { return false }
        let id = Self.recordID(url: snapshot.url, day: snapshot.day)
        do {
            try database.transaction { db in
                try db.run("""
                    INSERT INTO product_snapshots (
                        id, name, price, currency, locale, url, host, day, captured_at,
                        gtin, mpn, sku, product_id, retailer_item_id, brand, image_url
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name, price = excluded.price,
                        currency = excluded.currency, locale = excluded.locale,
                        url = excluded.url, host = excluded.host, day = excluded.day,
                        captured_at = excluded.captured_at, gtin = excluded.gtin,
                        mpn = excluded.mpn, sku = excluded.sku,
                        product_id = excluded.product_id,
                        retailer_item_id = excluded.retailer_item_id,
                        brand = excluded.brand, image_url = excluded.image_url
                    """) { statement in
                    try statement.bind(1, id)
                    try Self.bind(snapshot, to: statement, startingAt: 2)
                }
                try db.run("DELETE FROM product_snapshot_keys WHERE snapshot_id = ?") {
                    try $0.bind(1, id)
                }
                for key in snapshot.indexKeys {
                    try db.run("""
                        INSERT INTO product_snapshot_keys (key, snapshot_id) VALUES (?, ?)
                        """) { statement in
                        try statement.bind(1, key)
                        try statement.bind(2, id)
                    }
                }
                try prune(in: db, now: now)
            }
            return true
        } catch {
            return false
        }
    }

    /// Validates and records one `productSnapshot` message payload.
    @discardableResult
    public func record(payload: [String: Any], now: Date = Date()) -> Bool {
        guard let snapshot = Self.makeSnapshot(fromPayload: payload, now: now) else { return false }
        return record(snapshot, now: now)
    }

    private func prune(in database: SavesDatabase, now: Date) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let cutoffDate = calendar.date(byAdding: .day, value: -Self.maxAgeDays, to: now) ?? now
        try database.run("DELETE FROM product_snapshots WHERE day < ?") {
            try $0.bind(1, UTCDay(cutoffDate).text)
        }
        let count = Int(try database.scalarInt("SELECT COUNT(*) FROM product_snapshots") ?? 0)
        guard count > maxCount else { return }
        try database.run("""
            DELETE FROM product_snapshots WHERE id IN (
                SELECT id FROM product_snapshots ORDER BY day ASC, id ASC LIMIT ?
            )
            """) {
            try $0.bind(1, count - maxCount)
        }
    }

    // MARK: - Reading

    /// Every stored observation filed under any of `keys`, oldest-day first.
    public func snapshots(forKeys keys: [String]) -> [ProductSnapshot] {
        snapshots(forKeys: keys, limit: nil)
    }

    /// A bounded key lookup. The limit is applied by SQLite before rows are read,
    /// keeping the newest days (ties by stable id).
    public func snapshots(forKeys keys: [String], limit: Int?) -> [ProductSnapshot] {
        var seen = Set<String>()
        let keys = keys.filter { seen.insert($0).inserted }
        guard !keys.isEmpty, let database = database() else { return [] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let limitClause = limit.map { _ in " LIMIT ?" } ?? ""
        let sql = """
            SELECT \(Self.snapshotColumns) FROM product_snapshots AS snapshots
            WHERE snapshots.id IN (
                SELECT snapshot_id FROM product_snapshot_keys
                WHERE key IN (\(placeholders))
            )
            ORDER BY snapshots.day DESC, snapshots.id ASC\(limitClause)
            """
        do {
            var results: [ProductSnapshot] = []
            try database.perform { db in
                try db.query(sql, { statement in
                    for (offset, key) in keys.enumerated() {
                        try statement.bind(Int32(offset + 1), key)
                    }
                    if let limit { try statement.bind(Int32(keys.count + 1), max(0, limit)) }
                }, row: { row in
                    if let snapshot = Self.snapshot(from: row) { results.append(snapshot) }
                })
            }
            return results.sorted { $0.day != $1.day ? $0.day < $1.day : $0.url < $1.url }
        } catch {
            return []
        }
    }

    /// Every observation of exactly this page, newest first.
    public func snapshots(forPageURLString urlString: String) -> [ProductSnapshot] {
        let target = ProductSnapshotKeys.strippedTrackingURL(urlString)
        return snapshots(forKeys: [ProductSnapshotKeys.urlKey(urlString)])
            .filter { ProductSnapshotKeys.strippedTrackingURL($0.url) == target }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Every observation in the store. Tooling, diagnostics and tests only.
    public func allSnapshots() -> [ProductSnapshot] {
        guard let database = database() else { return [] }
        do {
            var results: [ProductSnapshot] = []
            try database.perform { db in
                try db.query("SELECT \(Self.snapshotColumns) FROM product_snapshots ORDER BY day ASC, url ASC") {
                    if let snapshot = Self.snapshot(from: $0) { results.append(snapshot) }
                }
            }
            return results
        } catch {
            return []
        }
    }

    /// How many observations are stored.
    public func count() -> Int {
        guard let database = database() else { return 0 }
        return (try? database.perform { try $0.scalarInt("SELECT COUNT(*) FROM product_snapshots") })
            .flatMap(Int.init) ?? 0
    }

    private static let snapshotColumns = """
        name, price, currency, locale, url, host, day, captured_at,
        gtin, mpn, sku, product_id, retailer_item_id, brand, image_url
        """

    private static func bind(_ snapshot: ProductSnapshot, to statement: SavesStatement, startingAt index: Int32) throws {
        try statement.bind(index, snapshot.name)
        try statement.bind(index + 1, snapshot.price)
        try statement.bind(index + 2, snapshot.currency)
        try statement.bind(index + 3, snapshot.locale)
        try statement.bind(index + 4, snapshot.url)
        try statement.bind(index + 5, snapshot.host)
        try statement.bind(index + 6, snapshot.day.text)
        try statement.bind(index + 7, snapshot.capturedAt)
        try statement.bind(index + 8, snapshot.gtin)
        try statement.bind(index + 9, snapshot.mpn)
        try statement.bind(index + 10, snapshot.sku)
        try statement.bind(index + 11, snapshot.productID)
        try statement.bind(index + 12, snapshot.retailerItemID)
        try statement.bind(index + 13, snapshot.brand)
        try statement.bind(index + 14, snapshot.imageURL)
    }

    private static func snapshot(from row: SavesStatement) -> ProductSnapshot? {
        guard let name = row.string(0), let price = row.string(1),
              let currency = row.string(2), let url = row.string(4),
              let host = row.string(5), let dayText = row.string(6),
              let day = UTCDay(parsing: dayText), let capturedAt = row.string(7)
        else { return nil }
        return ProductSnapshot(
            name: name, price: price, currency: currency, locale: row.string(3),
            url: url, host: host, day: day, capturedAt: capturedAt,
            gtin: row.string(8), mpn: row.string(9), sku: row.string(10),
            productID: row.string(11), retailerItemID: row.string(12),
            brand: row.string(13), imageURL: row.string(14))
    }

    // MARK: - Payload validation

    /// Validates one snapshot payload, or nil when it is not a real product
    /// observation: no http(s) URL, non-empty name, positive decimal price, or
    /// ISO 4217 currency.
    public static func makeSnapshot(
        fromPayload payload: [String: Any], now: Date
    ) -> ProductSnapshot? {
        guard let urlString = payload["url"] as? String, urlString.hasPrefix("http"),
              let url = URL(string: urlString), let host = url.host, !host.isEmpty
        else { return nil }
        guard let rawName = payload["name"] as? String,
              case let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        guard let priceString = decimalString(from: payload["price"])
            .flatMap(Self.sanitizedDecimalString),
              let amount = Decimal(string: priceString), amount > 0
        else { return nil }
        guard let rawCurrency = payload["currency"] as? String else { return nil }
        let currency = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard currency.count == 3, currency.allSatisfy(\.isLetter) else { return nil }

        func field(_ key: String) -> String? {
            guard let raw = payload[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return ProductSnapshot(
            name: name, price: priceString, currency: currency,
            locale: field("locale") ?? Locale.current.identifier,
            url: urlString, host: host,
            day: UTCDay(now),
            capturedAt: ISO8601DateFormatter().string(from: now),
            gtin: field("gtin"), mpn: field("mpn"), sku: field("sku"),
            productID: field("productID"), retailerItemID: field("retailerItemID"),
            brand: field("brand"), imageURL: field("imageURL"))
    }

    private static func decimalString(from raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// Normalises page price text (for example, `$1,299.00`) to exact decimal
    /// digits. A minus sign is retained so the positive-price validation rejects
    /// negative amounts instead of laundering them to positive values.
    public static func sanitizedDecimalString(_ raw: String) -> String? {
        let stripped = raw.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
            .replacingOccurrences(of: ",", with: "")
        return stripped.isEmpty ? nil : stripped
    }
}
