//
//  SharedProductMatching.swift
//  LunaSafari
//

import Foundation

/// Answers the "Was $X on <date>" history-pill query entirely inside the
/// extension process: matches the current page's extracted product data
/// against (a) the app-written compact tracked-product index and (b) the
/// passive snapshot file, using the SAME identifier precedence
/// `LunaHTMLClassification.SnapshotMatcher` uses on the app side. `LunaSafari`
/// links no package, so this is a THIRD hand-written copy of that matching
/// logic — `SharedProductMatchingParityTests` runs a fixture matrix through
/// this copy and through `SnapshotMatcher`/`ProductMatcher` to keep them
/// agreeing.
enum SharedProductMatching {

    /// One tracked product, as `PriceHistoryIndexWriter` writes it — mirror
    /// field-for-field.
    struct IndexEntry: Codable {
        struct Point: Codable {
            var day: String
            var price: String
            var currency: String
        }
        struct StorePoints: Codable {
            var url: String
            var host: String
            var points: [Point]
        }
        var name: String
        var brand: String?
        var productID: String?
        var stores: [StorePoints]
    }

    struct HistoryAnswer {
        var isTracked: Bool
        var hasHistory: Bool
        var amount: String?
        var currency: String?
        var day: String?
    }

    private static let indexRelativeDirectory = "Library/ProductSnapshots"
    private static let indexFileName = "priceHistoryIndex.json"

    private static func indexFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SafariAppGroup.id)?
            .appendingPathComponent(indexRelativeDirectory, isDirectory: true)
            .appendingPathComponent(indexFileName)
    }

    static func loadIndex() -> [IndexEntry] {
        guard let url = indexFileURL(), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([IndexEntry].self, from: data)) ?? []
    }

    /// The full answer for a page's extracted snapshot payload (the same shape
    /// `extractProductSnapshot()` sends as `productSnapshot`).
    static func historyAnswer(forPageSnapshot page: SharedProductSnapshots.Record) -> HistoryAnswer {
        let index = loadIndex()
        let trackedMatch = index.first { matches(page: page, indexEntry: $0) }

        var points: [(price: Decimal, currency: String, day: String)] = []
        if let trackedMatch {
            for store in trackedMatch.stores {
                for point in store.points {
                    if let amount = Decimal(string: point.price) {
                        points.append((amount, point.currency, point.day))
                    }
                }
            }
        }
        let otherSnapshots = SharedProductSnapshots.load().filter { $0.url != page.url }
        for snapshot in otherSnapshots where matches(page: page, snapshot: snapshot) {
            if let amount = Decimal(string: snapshot.price) {
                points.append((amount, snapshot.currency, snapshot.day))
            }
        }

        guard let pageAmount = Decimal(string: page.price) else {
            return HistoryAnswer(
                isTracked: trackedMatch != nil, hasHistory: false, amount: nil, currency: nil, day: nil)
        }
        let cheaper = points.filter { $0.currency == page.currency && $0.price < pageAmount }
        guard let lowest = cheaper.min(by: {
            $0.price != $1.price ? $0.price < $1.price : $0.day < $1.day
        }) else {
            return HistoryAnswer(
                isTracked: trackedMatch != nil, hasHistory: false, amount: nil, currency: nil, day: nil)
        }
        return HistoryAnswer(
            isTracked: trackedMatch != nil, hasHistory: true,
            amount: NSDecimalNumber(decimal: lowest.price).stringValue,
            currency: lowest.currency, day: lowest.day)
    }

    // MARK: - Matching (mirrors LunaHTMLClassification.SnapshotMatcher)

    /// Page vs. a tracked index entry, whose only identifier is ONE flattened
    /// `productID` string (exactly `ProductInfo.productID`'s shape) — so the
    /// page's own KEYED fields are compared against it in precedence order,
    /// same as `ProductTrackerIngestor`'s tracker side participates in
    /// `SnapshotMatcher` via `ProductMatcher.normalizedID`.
    static func matches(page: SharedProductSnapshots.Record, indexEntry entry: IndexEntry) -> Bool {
        let entryID = normalizedID(entry.productID)
        let storeHosts = entry.stores.map(\.host)
        let storeURLs = entry.stores.map(\.url)

        if let entryGTIN = normalizedGTIN(entryID), let pageGTIN = normalizedGTIN(normalizedID(page.gtin)),
           entryGTIN == pageGTIN {
            return true
        }
        if let entryID, let pageRetailerID = normalizedID(page.retailerItemID), entryID == pageRetailerID,
           storeHosts.contains(where: { hostFamilyMatches($0, page.host) }) {
            return true
        }
        if let entryID, let pageMPN = normalizedID(page.mpn), entryID == pageMPN,
           brandsCompatible(page.brand, entry.brand) {
            return true
        }
        if let entryID, let pageSKU = normalizedID(page.sku), entryID == pageSKU,
           storeHosts.contains(where: { $0.lowercased() == page.host.lowercased() }) {
            return true
        }
        let strippedPageURL = strippedTrackingURL(page.url)
        if storeURLs.contains(where: { strippedTrackingURL($0) == strippedPageURL }) {
            return true
        }
        if brandsCompatible(page.brand, entry.brand),
           nameSimilarity(page.name, entry.name) >= nameThreshold {
            return true
        }
        return false
    }

    /// Page vs. another passive snapshot — both sides carry the same keyed
    /// identifiers, so each tier compares the matching field directly.
    static func matches(page: SharedProductSnapshots.Record, snapshot: SharedProductSnapshots.Record) -> Bool {
        if let pageGTIN = normalizedGTIN(normalizedID(page.gtin)),
           let otherGTIN = normalizedGTIN(normalizedID(snapshot.gtin)), pageGTIN == otherGTIN {
            return true
        }
        if let pageRetailerID = normalizedID(page.retailerItemID),
           let otherRetailerID = normalizedID(snapshot.retailerItemID), pageRetailerID == otherRetailerID,
           hostFamilyMatches(page.host, snapshot.host) {
            return true
        }
        if let pageMPN = normalizedID(page.mpn), let otherMPN = normalizedID(snapshot.mpn), pageMPN == otherMPN,
           brandsCompatible(page.brand, snapshot.brand) {
            return true
        }
        if let pageSKU = normalizedID(page.sku), let otherSKU = normalizedID(snapshot.sku), pageSKU == otherSKU,
           page.host.lowercased() == snapshot.host.lowercased() {
            return true
        }
        if strippedTrackingURL(page.url) == strippedTrackingURL(snapshot.url) {
            return true
        }
        if brandsCompatible(page.brand, snapshot.brand),
           nameSimilarity(page.name, snapshot.name) >= nameThreshold {
            return true
        }
        return false
    }

    // MARK: - Pure helpers (mirror LunaHTMLClassification.ProductMatcher / SnapshotMatcher)

    static let nameThreshold = 0.6

    static func normalizedID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? nil : cleaned
    }

    static func normalizedGTIN(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.allSatisfy(\.isNumber), raw.count <= 14 else { return raw }
        return String(repeating: "0", count: 14 - raw.count) + raw
    }

    static func brandsCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let cleaned = value.lowercased().filter { $0.isLetter || $0.isNumber }
            return cleaned.isEmpty ? nil : cleaned
        }
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return true }
        return lhs == rhs
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "with", "for", "new", "of", "in", "to",
        "buy", "shop", "online", "official", "store",
    ]

    private static func tokens(_ name: String) -> Set<String> {
        Set(name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) })
    }

    static func nameSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = tokens(lhs)
        let rhsTokens = tokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens)
        let union = lhsTokens.union(rhsTokens)
        return Double(intersection.count) / Double(union.count)
    }

    private static let compoundSuffixes: Set<String> = [
        "co.uk", "co.jp", "co.nz", "co.in", "com.au", "com.br", "com.mx", "com.tr",
    ]

    static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host.lowercased() }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if labels.count >= 3, compoundSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    static func hostFamilyMatches(_ lhs: String, _ rhs: String) -> Bool {
        registrableDomain(lhs) == registrableDomain(rhs)
    }

    static func strippedTrackingURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        let host = (components.host ?? "").lowercased()
        components.queryItems = components.queryItems?.filter { item in
            let lower = item.name.lowercased()
            if ["srsltid", "gclid", "ref"].contains(lower) { return false }
            if lower.hasPrefix("utm_") { return false }
            if lower == "tag", host.contains("amazon.") { return false }
            return true
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString ?? urlString
    }
}
