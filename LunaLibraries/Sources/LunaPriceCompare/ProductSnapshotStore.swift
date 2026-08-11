//
//  ProductSnapshotStore.swift
//  LunaPriceCompare
//

import Foundation
import LunaAppConfig
import LunaModels

/// The shared, INDEXED store of product observations in the App Group
/// container — one implementation, written and read by every Luna process that
/// can see a product: the apps, the share/action extensions, and the four
/// Safari appexes.
///
/// **Why an index.** The store is read at the moment a price tracker is
/// created, synchronously, on the save path — the tracker's graph history IS
/// the answer to that read (`ProductTrackerMerge.seedHistoryFromSnapshots`).
/// Reading it must therefore stay cheap as the store grows, which rules out
/// decoding a single array of every observation ever taken and filtering it.
/// So the layout is:
///
/// ```
/// Library/ProductSnapshots/
///   snapshotIndex.json      identifier key -> record ids, plus id -> day
///   records/<record id>.json  one observation each
/// ```
///
/// A lookup decodes the index once (a flat string map, no observation bodies)
/// and then reads ONLY the record files its candidate's identifiers point at.
/// Cost is O(candidate identifiers + matched records), not O(store).
///
/// A record id is a hash of `<url>|<day>`, which is also the store's uniqueness
/// rule: revisiting a page the same day updates that day's observation instead
/// of accumulating duplicates. Records are individually addressable, so two
/// processes observing two different pages never write the same file; only the
/// index is read-modify-write, and it is written atomically.
public final class ProductSnapshotStore: @unchecked Sendable {
    public static let shared = ProductSnapshotStore()

    public static let relativeDirectory = "Library/ProductSnapshots"
    public static let indexFileName = "snapshotIndex.json"
    public static let recordsDirectoryName = "records"
    /// Observations older than this are dropped: a year of daily points is
    /// already more graph than any product needs.
    public static let maxAgeDays = 365
    /// Hard ceiling on stored observations, oldest evicted first.
    public static let maxCount = 5000

    private let directoryURL: URL?
    /// This instance's count ceiling. A parameter only so a test can drive
    /// eviction without writing five thousand records.
    private let maxCount: Int

    public init(
        directoryURL: URL? = ProductSnapshotStore.defaultDirectoryURL(),
        maxCount: Int = ProductSnapshotStore.maxCount
    ) {
        self.directoryURL = directoryURL
        self.maxCount = maxCount
    }

    public static func defaultDirectoryURL() -> URL? {
        AppConfig.sharedContainerURL()?
            .appendingPathComponent(relativeDirectory, isDirectory: true)
    }

    private var indexURL: URL? { directoryURL?.appendingPathComponent(Self.indexFileName) }
    private var recordsURL: URL? {
        directoryURL?.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
    }

    // MARK: - The index

    /// The on-disk index: which record ids answer a key, and how old each
    /// record is. Deliberately holds no observation bodies — it is decoded on
    /// every lookup, so it must stay small.
    struct Index: Codable {
        /// identifier key -> record ids filed under it.
        var keys: [String: [String]] = [:]
        /// record id -> its UTC day, for pruning and ordering.
        var days: [String: String] = [:]
    }

    func loadIndex() -> Index {
        guard let indexURL, let data = try? Data(contentsOf: indexURL) else { return Index() }
        return (try? JSONDecoder().decode(Index.self, from: data)) ?? Index()
    }

    private func writeIndex(_ index: Index) {
        guard let indexURL, let directoryURL else { return }
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// The stable id of the observation for `url` on `day` — a 64-bit FNV-1a
    /// hash, so a record is one filename rather than an encoded URL that would
    /// blow past the filesystem's name limit. A read verifies the record's own
    /// `url`/`day`, so a collision degrades to a miss and never to wrong data.
    public static func recordID(url: String, day: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array("\(url)|\(day)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private func recordURL(_ id: String) -> URL? {
        recordsURL?.appendingPathComponent("\(id).json")
    }

    private func loadRecord(_ id: String) -> ProductSnapshot? {
        guard let url = recordURL(id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProductSnapshot.self, from: data)
    }

    // MARK: - Writing

    /// Records one observation. Unconditional by design: there is no setting,
    /// anywhere, that suppresses this — a suggestion mode silences PILLS, and
    /// price tracking being off means no tracker, not no memory of a price.
    /// Returns whether it wrote.
    @discardableResult
    public func record(_ snapshot: ProductSnapshot, now: Date = Date()) -> Bool {
        guard let recordsURL else { return false }
        try? FileManager.default.createDirectory(
            at: recordsURL, withIntermediateDirectories: true)

        let id = Self.recordID(url: snapshot.url, day: snapshot.day)
        guard let recordURL = recordURL(id),
              let data = try? JSONEncoder().encode(snapshot)
        else { return false }
        try? data.write(to: recordURL, options: .atomic)

        var index = loadIndex()
        index.days[id] = snapshot.day
        for key in snapshot.indexKeys {
            var ids = index.keys[key] ?? []
            if !ids.contains(id) { ids.append(id) }
            index.keys[key] = ids
        }
        writeIndex(prune(index, now: now))
        return true
    }

    /// Validates and records one `productSnapshot` message payload (the shape
    /// `content.js`'s `extractProductSnapshot()` sends, and the shape
    /// `ComparableSellerResult.snapshotPayload` produces).
    @discardableResult
    public func record(payload: [String: Any], now: Date = Date()) -> Bool {
        guard let snapshot = Self.makeSnapshot(fromPayload: payload, now: now) else { return false }
        return record(snapshot, now: now)
    }

    /// Drops observations past `maxAgeDays`, then caps the total at `maxCount`
    /// evicting the oldest day first, deleting their record files and every
    /// key entry that pointed at them. `day` strings sort lexicographically the
    /// same as chronologically (`yyyy-MM-dd`), so no date parsing is needed.
    func prune(_ index: Index, now: Date) -> Index {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let cutoffDate = utcCalendar.date(byAdding: .day, value: -Self.maxAgeDays, to: now) ?? now
        let cutoff = Self.dayString(for: cutoffDate)

        var surviving = index.days.filter { $0.value >= cutoff }
        if surviving.count > maxCount {
            let ordered = surviving.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            for (id, _) in ordered.prefix(surviving.count - maxCount) {
                surviving.removeValue(forKey: id)
            }
        }
        guard surviving.count != index.days.count else { return index }

        for id in index.days.keys where surviving[id] == nil {
            if let url = recordURL(id) { try? FileManager.default.removeItem(at: url) }
        }
        var pruned = Index(keys: [:], days: surviving)
        for (key, ids) in index.keys {
            let kept = ids.filter { surviving[$0] != nil }
            if !kept.isEmpty { pruned.keys[key] = kept }
        }
        return pruned
    }

    // MARK: - Reading

    /// Every stored observation filed under any of `keys`, newest-day last and
    /// order-stable. This is the whole read path: the index says which record
    /// files to open, and no other file is touched.
    ///
    public func snapshots(forKeys keys: [String]) -> [ProductSnapshot] {
        snapshots(forKeys: keys, limit: nil)
    }

    /// `snapshots(forKeys:)` with a ceiling on how many RECORD FILES are
    /// opened, keeping the newest days (ties by record id, so the choice is
    /// deterministic). It exists for the name-bucket keys, whose pool is a
    /// narrowed guess rather than an identifier hit: a brand's most popular
    /// word must cost a bounded number of reads on the save path however many
    /// observations sit behind it. The decision is made from the index's `days`
    /// map alone — no record is read to find out how old it is.
    public func snapshots(forKeys keys: [String], limit: Int?) -> [ProductSnapshot] {
        guard !keys.isEmpty else { return [] }
        let index = loadIndex()
        var ids: [String] = []
        var seen = Set<String>()
        for key in keys {
            for id in index.keys[key] ?? [] where seen.insert(id).inserted { ids.append(id) }
        }
        if let limit, ids.count > limit {
            ids = ids
                .sorted {
                    let left = index.days[$0] ?? "", right = index.days[$1] ?? ""
                    return left != right ? left > right : $0 < $1
                }
                .prefix(limit)
                .map { $0 }
        }
        return ids.compactMap(loadRecord)
            .sorted { $0.day != $1.day ? $0.day < $1.day : $0.url < $1.url }
    }

    /// Every observation of exactly this page, newest first. Used by the
    /// bot-wall fallback, which wants the freshest reading of ONE url.
    public func snapshots(forPageURLString urlString: String) -> [ProductSnapshot] {
        let target = ProductSnapshotKeys.strippedTrackingURL(urlString)
        return snapshots(forKeys: [ProductSnapshotKeys.urlKey(urlString)])
            .filter { ProductSnapshotKeys.strippedTrackingURL($0.url) == target }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Every observation in the store. Tooling, diagnostics and tests only —
    /// production read paths go through the index.
    public func allSnapshots() -> [ProductSnapshot] {
        let index = loadIndex()
        return index.days.keys.compactMap(loadRecord)
            .sorted { $0.day != $1.day ? $0.day < $1.day : $0.url < $1.url }
    }

    /// How many observations are stored (index-only; opens no record).
    public func count() -> Int { loadIndex().days.count }

    // MARK: - Payload validation

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public static func dayString(for date: Date) -> String { dayFormatter.string(from: date) }

    /// A `yyyy-MM-dd` UTC day string back to that day's UTC midnight.
    public static func date(forDay day: String) -> Date? { dayFormatter.date(from: day) }

    /// Validates one snapshot payload, or nil when it is not a real product
    /// observation: no http(s) URL, no non-empty name, no positive decimal
    /// price, or no ISO 4217 currency.
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
            day: dayString(for: now),
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

    /// The payload's price as a bare decimal string, or nil when no digits
    /// survive. The meta/microdata capture tiers hand over the page's RAW price
    /// text ("$1,299.00"), which `Decimal(string:)` refuses outright — so every
    /// such visit used to be dropped, silently. Mirrors `content.js`'s
    /// `parsePriceNumber` (strip currency symbols, then drop the thousands
    /// commas) — except the SIGN survives, so a negative payload still fails
    /// the `amount > 0` gate rather than being laundered into a positive price.
    public static func sanitizedDecimalString(_ raw: String) -> String? {
        let stripped = raw.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
            .replacingOccurrences(of: ",", with: "")
        return stripped.isEmpty ? nil : stripped
    }
}
