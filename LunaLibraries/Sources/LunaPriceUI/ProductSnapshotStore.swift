//
//  ProductSnapshotStore.swift
//  LunaPriceUI
//

import LunaAppConfig
import LunaHTMLClassification
import Foundation

/// Reads the passive product snapshots a product-handling Safari extension
/// writes to the shared App Group container. `LunaSafari` links no package, so
/// the extension's own copy (`SharedProductSnapshots`) hand-rolls the same
/// path/keys/prune policy — pinned together by `SharedProductSnapshotsTests`,
/// which also exercises the validation/prune logic here directly (equivalent
/// Swift to the extension's copy, real execution instead of a source-text
/// check for the numbers that matter: round-trip, same-day overwrite, age/
/// count pruning, invalid-payload rejection).
///
/// Only the extension WRITES this file; the app only ever reads it (to seed a
/// freshly saved tracker's history, and to answer the history-pill query from
/// the compact index it writes separately — see `PriceHistoryIndexWriter`).
public final class ProductSnapshotStore {
    public static let shared = ProductSnapshotStore()

    /// Mirror `LunaSafari/SharedProductSnapshots.swift`'s constants exactly —
    /// `SharedProductSnapshotsTests` pins both copies to these literal values.
    public static let relativeDirectory = "Library/ProductSnapshots"
    public static let fileName = "productSnapshots.json"
    public static let maxAgeDays = 365
    public static let maxCount = 2000

    private let fileURL: URL?

    public init(fileURL: URL? = ProductSnapshotStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent(relativeDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// All currently-persisted snapshots (already pruned by the writer — this
    /// is a passive read, it does not re-prune or rewrite the file).
    public func load() -> [ProductSnapshot] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ProductSnapshot].self, from: data)) ?? []
    }

    /// Test/tooling seam: writes the file directly (production writes only
    /// ever happen from the Safari extension).
    public func write(_ snapshots: [ProductSnapshot]) {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Pure logic (mirrored verbatim by the extension's own copy)

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public static func dayString(for date: Date) -> String { dayFormatter.string(from: date) }

    /// Validates one `productSnapshot` message payload into a `ProductSnapshot`,
    /// or nil when it's not a real product page: no http(s) URL, no non-empty
    /// name, or no positive decimal price. Mirrors `SharedProductSnapshots
    /// .makeRecord(from:now:)` field-for-field.
    public static func makeSnapshot(fromPayload payload: [String: Any], now: Date) -> ProductSnapshot? {
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
            name: name, price: priceString, currency: currency, url: urlString, host: host,
            day: dayString(for: now),
            capturedAt: ISO8601DateFormatter().string(from: now),
            gtin: field("gtin"), mpn: field("mpn"), sku: field("sku"),
            productID: field("productID"), retailerItemID: field("retailerItemID"),
            brand: field("brand"))
    }

    private static func decimalString(from raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// The payload's price as a bare decimal string, or nil when no digits
    /// survive. The meta/microdata capture tiers hand over the page's RAW price
    /// text ("$1,299.00"), which `Decimal(string:)` refuses outright — so every
    /// such visit used to be dropped, silently, while the pill still rendered.
    /// Mirrors `content.js`'s `parsePriceNumber` (strip currency symbols, then
    /// drop the thousands commas) — except the SIGN survives, so a negative
    /// payload still fails the `amount > 0` gate rather than being laundered
    /// into a positive price. The SANITIZED string is what gets persisted.
    public static func sanitizedDecimalString(_ raw: String) -> String? {
        let stripped = raw.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
            .replacingOccurrences(of: ",", with: "")
        return stripped.isEmpty ? nil : stripped
    }

    /// Folds a freshly-validated snapshot into an existing list: one record per
    /// (canonical url, day) — a same-day revisit overwrites price/date rather
    /// than accumulating duplicates.
    public static func merging(_ entry: ProductSnapshot, into existing: [ProductSnapshot]) -> [ProductSnapshot] {
        var merged = existing
        if let index = merged.firstIndex(where: { $0.url == entry.url && $0.day == entry.day }) {
            merged[index] = entry
        } else {
            merged.append(entry)
        }
        return merged
    }

    /// Drops records older than `maxAgeDays` and caps the total at `maxCount`,
    /// evicting the oldest first. `day` strings sort lexicographically the same
    /// as chronologically (`yyyy-MM-dd`), so no date parsing is needed to order
    /// or cap them.
    public static func pruned(_ snapshots: [ProductSnapshot], now: Date) -> [ProductSnapshot] {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let cutoffDate = utcCalendar.date(byAdding: .day, value: -maxAgeDays, to: now) ?? now
        let cutoff = dayString(for: cutoffDate)

        var kept = snapshots.filter { $0.day >= cutoff }
        kept.sort { $0.day < $1.day }
        if kept.count > maxCount {
            kept.removeFirst(kept.count - maxCount)
        }
        return kept
    }
}
