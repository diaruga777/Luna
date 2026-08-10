//
//  SharedProductSnapshots.swift
//  LunaSafari
//

import Foundation

/// Persists passive product-page snapshots into the App Group container, one
/// JSON file (snapshots are too big for `UserDefaults` hygiene). NOT saves: no
/// reading-list row, no refresh, no alert — see `SafariWebExtensionHandler`'s
/// `productSnapshot` case, which is the one write path.
///
/// The app reads the SAME file through its own mirrored copy,
/// `LunaPriceUI.ProductSnapshotStore` (this target links no package, so the
/// path/keys/prune policy are duplicated by hand) — parity between the two is
/// pinned by `SharedProductSnapshotsTests`.
enum SharedProductSnapshots {
    static let appGroupID = SafariAppGroup.id
    static let relativeDirectory = "Library/ProductSnapshots"
    static let fileName = "productSnapshots.json"
    static let maxAgeDays = 365
    static let maxCount = 2000

    /// One page visit's extracted product data — the wire format. Keys mirror
    /// `LunaHTMLClassification.ProductSnapshot` field-for-field.
    struct Record: Codable, Equatable {
        var name: String
        var price: String
        var currency: String
        var url: String
        var host: String
        var day: String
        var capturedAt: String
        var gtin: String?
        var mpn: String?
        var sku: String?
        var productID: String?
        var retailerItemID: String?
        var brand: String?
    }

    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(relativeDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func load() -> [Record] {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func save(_ records: [Record]) {
        guard let url = fileURL() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func dayString(for date: Date) -> String { dayFormatter.string(from: date) }

    /// Validates and persists one snapshot from the extension's
    /// `productSnapshot` message payload. Silently drops an invalid payload
    /// (no http(s) URL, no positive decimal price, or an empty name). Returns
    /// whether it recorded.
    @discardableResult
    static func record(_ payload: [String: Any], now: Date = Date()) -> Bool {
        guard let entry = makeRecord(from: payload, now: now) else { return false }
        var records = load()
        if let index = records.firstIndex(where: { $0.url == entry.url && $0.day == entry.day }) {
            records[index] = entry
        } else {
            records.append(entry)
        }
        save(prune(records, now: now))
        return true
    }

    static func makeRecord(from payload: [String: Any], now: Date) -> Record? {
        guard let urlString = payload["url"] as? String, urlString.hasPrefix("http"),
              let url = URL(string: urlString), let host = url.host, !host.isEmpty
        else { return nil }
        guard let rawName = payload["name"] as? String,
              case let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        guard let priceString = decimalString(from: payload["price"])
            .flatMap(sanitizedDecimalString),
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

        return Record(
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
    /// Mirrors `content.js`'s `parsePriceNumber` (strip everything outside
    /// `[0-9.,]`, then drop the commas), so the two sides agree about which
    /// prices are recordable. The SANITIZED string is what gets persisted.
    /// Mirror of `ProductSnapshotStore.sanitizedDecimalString` — keep in sync.
    static func sanitizedDecimalString(_ raw: String) -> String? {
        let stripped = raw.filter { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
        return stripped.isEmpty ? nil : stripped
    }

    /// Drops records older than `maxAgeDays` and caps the total at `maxCount`,
    /// evicting the oldest first (`day` strings sort lexicographically the same
    /// as chronologically).
    static func prune(_ records: [Record], now: Date) -> [Record] {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let cutoffDate = utcCalendar.date(byAdding: .day, value: -maxAgeDays, to: now) ?? now
        let cutoff = dayString(for: cutoffDate)

        var kept = records.filter { $0.day >= cutoff }
        kept.sort { $0.day < $1.day }
        if kept.count > maxCount {
            kept.removeFirst(kept.count - maxCount)
        }
        return kept
    }
}
