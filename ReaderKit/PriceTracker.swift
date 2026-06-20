//
//  PriceTracker.swift
//  Clip
//

import Foundation

/// One store's listing of a tracked product: where to fetch it and the last
/// price seen there. A tracker always has at least one of these.
struct PriceTrackerStore: Codable, Equatable, Identifiable {
    /// The store page URL (stable identity within a tracker).
    var urlString: String
    /// The most recently fetched price at this store, if a refresh has succeeded.
    var lastPrice: Decimal?
    /// ISO 4217 currency for `lastPrice`.
    var currency: String
    /// When this store was last refreshed (nil = never since creation).
    var lastRefreshed: Date?

    var id: String { urlString }
    var url: URL? { URL(string: urlString) }

    init(urlString: String, lastPrice: Decimal?, currency: String, lastRefreshed: Date? = nil) {
        self.urlString = urlString
        self.lastPrice = lastPrice
        self.currency = currency
        self.lastRefreshed = lastRefreshed
    }
}

/// The portable representation of a price tracker for friend sharing — carries
/// everything needed to recreate the tracker on the recipient's device. Prices
/// are encoded as strings so the Decimal value round-trips exactly across the
/// JSON wire.
struct PriceTrackerShare: Codable, Equatable {
    var productName: String
    var storeURLStrings: [String]
    /// The best fetched price at share time (the recipient's baseline).
    var initialPriceString: String
    var initialCurrency: String
    var alertThresholdFraction: Double
    var brand: String?
    var productID: String?

    /// Builds a share payload from a live tracker.
    init(tracker: PriceTracker) {
        productName = tracker.productName
        storeURLStrings = tracker.stores.map(\.urlString).filter { !$0.isEmpty }
        initialPriceString = NSDecimalNumber(decimal: tracker.currentBestPrice).stringValue
        initialCurrency = tracker.displayCurrency
        alertThresholdFraction = tracker.alertThresholdFraction
        brand = tracker.brand
        productID = tracker.productID
    }

    /// Reconstructs a tracker on the recipient side, seeding each shared URL with
    /// the shared baseline price (a real refresh updates them after). Returns nil
    /// when the payload carries no usable store URL (the ≥1 invariant).
    func makeTracker(now: Date = Date()) -> PriceTracker? {
        guard let firstURL = storeURLStrings.first,
              let price = ProductPageDetector.parsePrice(initialPriceString) else { return nil }
        let currency = ProductPageDetector.normalizeCurrency(initialCurrency) ?? "USD"
        var tracker = PriceTracker(
            productName: productName, firstStoreURL: firstURL, price: price, currency: currency,
            brand: brand, productID: productID,
            alertThresholdFraction: alertThresholdFraction, now: now)
        for url in storeURLStrings.dropFirst() {
            tracker.upsertStore(PriceTrackerStore(
                urlString: url, lastPrice: price, currency: currency, lastRefreshed: now))
        }
        return tracker
    }
}

/// A price-tracking payload attached to a `ReadingListItem`. Represents a product
/// the user wants to watch across one or more store URLs.
///
/// Invariants enforced by construction:
/// - `stores` is never empty (a tracker always has ≥1 URL).
/// - every store and `initialPrice` carry a currency.
struct PriceTracker: Codable, Equatable {
    /// Product display name.
    var productName: String
    /// The store listings being watched (≥1).
    private(set) var stores: [PriceTrackerStore]
    /// Brand, if known (used for fuzzy product matching).
    var brand: String?
    /// Stable product id (GTIN/SKU/…), the strongest matching signal.
    var productID: String?
    /// Downloaded product image file name (inside the Articles directory).
    var imageFileName: String?
    /// The best (lowest) price across stores at creation time — the baseline the
    /// drop threshold is measured against.
    var initialPrice: Decimal
    /// Currency of `initialPrice` (also the tracker's display currency).
    var initialCurrency: String
    /// Fractional price drop (vs `initialPrice`) that triggers an alert. Default 0.10.
    var alertThresholdFraction: Double
    /// Whether the user archived this tracker (excluded from background refresh).
    var isArchived: Bool
    /// When the user last viewed this tracker's alert (opened the tracker while it
    /// was alerting). Nil means the current alert, if any, is still UNVIEWED — which
    /// is what floats the row to the very top of the reading list. Set the moment
    /// the user opens an alerting tracker; cleared on a fresh drop (see
    /// `markAlertViewed`).
    var alertAcknowledgedAt: Date?

    /// The current best (lowest) price across all stores that have a fetched price,
    /// falling back to `initialPrice` when none has refreshed yet.
    var currentBestPrice: Decimal {
        let prices = stores.compactMap { $0.lastPrice }
        return prices.min() ?? initialPrice
    }

    /// The currency to display the best price in — the currency of whichever store
    /// holds the current best price, else the initial currency.
    var displayCurrency: String {
        if let cheapest = stores.filter({ $0.lastPrice != nil })
            .min(by: { ($0.lastPrice ?? 0) < ($1.lastPrice ?? 0) }) {
            return cheapest.currency
        }
        return initialCurrency
    }

    /// The current discount as a fraction of `initialPrice` (0 when not cheaper, or
    /// when the baseline is zero). 0.25 = 25% off.
    var discountFraction: Double {
        guard initialPrice > 0 else { return 0 }
        let best = currentBestPrice
        guard best < initialPrice else { return 0 }
        let drop = (initialPrice - best) / initialPrice
        return NSDecimalNumber(decimal: drop).doubleValue
    }

    /// Whether the current best price has dropped at or past the alert threshold.
    var isAlerting: Bool {
        !isArchived && discountFraction >= alertThresholdFraction
    }

    /// Whether this tracker has an alert the user hasn't seen yet: it's alerting AND
    /// the user hasn't acknowledged the current alert. This is the condition that
    /// floats the row to the very TOP of the whole reading list (badged red). Once
    /// the user opens the alerting tracker (`markAlertViewed`), this becomes false and
    /// the row rejoins the price-tracking section below Reading.
    var hasUnviewedAlert: Bool {
        isAlerting && alertAcknowledgedAt == nil
    }

    /// The absolute price drop (in `initialCurrency`) the threshold corresponds to.
    var thresholdAbsoluteDrop: Decimal {
        let fraction = Decimal(alertThresholdFraction)
        return initialPrice * fraction
    }

    /// Creates a tracker from a freshly detected product, seeding its first store
    /// with the detected price. A tracker cannot exist without a real numeric price:
    /// `price` is required, fetched up front by the `PriceFetcher` before the tracker
    /// is created (see `claudedocs/price-tracking.md`).
    init(
        productName: String,
        firstStoreURL: String,
        price: Decimal,
        currency: String,
        brand: String? = nil,
        productID: String? = nil,
        imageFileName: String? = nil,
        alertThresholdFraction: Double = 0.10,
        now: Date = Date()
    ) {
        self.productName = productName
        self.stores = [PriceTrackerStore(
            urlString: firstStoreURL, lastPrice: price, currency: currency, lastRefreshed: now)]
        self.brand = brand
        self.productID = productID
        self.imageFileName = imageFileName
        self.initialPrice = price
        self.initialCurrency = currency
        self.alertThresholdFraction = alertThresholdFraction
        self.isArchived = false
        self.alertAcknowledgedAt = nil
    }

    /// Marks the current alert as viewed (the user opened the alerting tracker), so
    /// the row stops floating to the top of the list and rejoins the price-tracking
    /// section. No-op when not alerting (nothing to acknowledge).
    mutating func markAlertViewed(at date: Date = Date()) {
        guard isAlerting else { return }
        alertAcknowledgedAt = date
    }

    /// Whether a URL is already one of this tracker's stores.
    func hasStore(urlString: String) -> Bool {
        stores.contains { $0.urlString == urlString }
    }

    /// Adds (or updates) a store URL. If the new price beats the baseline taken at
    /// creation, the baseline is NOT lowered — `initialPrice` is the reference point
    /// for alerts; merging a cheaper store simply surfaces as a current discount.
    mutating func upsertStore(_ store: PriceTrackerStore) {
        if let index = stores.firstIndex(where: { $0.urlString == store.urlString }) {
            stores[index] = store
        } else {
            stores.append(store)
        }
    }

    /// Removes a store URL; no-ops if it would empty the tracker (the ≥1 invariant).
    @discardableResult
    mutating func removeStore(urlString: String) -> Bool {
        guard stores.count > 1, stores.contains(where: { $0.urlString == urlString }) else {
            return false
        }
        stores.removeAll { $0.urlString == urlString }
        return true
    }

    /// Updates the fetched price for an existing store (background refresh). A price
    /// that drops the store strictly lower than its previously seen value clears any
    /// prior alert acknowledgement, so a genuinely fresh drop re-floats to the top of
    /// the list as an unviewed alert.
    mutating func setPrice(_ price: Decimal?, currency: String?, urlString: String, at date: Date) {
        guard let index = stores.firstIndex(where: { $0.urlString == urlString }) else { return }
        if let newPrice = price, let oldPrice = stores[index].lastPrice, newPrice < oldPrice {
            alertAcknowledgedAt = nil
        }
        stores[index].lastPrice = price
        if let currency { stores[index].currency = currency }
        stores[index].lastRefreshed = date
    }

    // MARK: - Migration-safe decoding

    private enum CodingKeys: String, CodingKey {
        case productName, stores, brand, productID, imageFileName
        case initialPrice, initialCurrency, alertThresholdFraction, isArchived
        case alertAcknowledgedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productName = try container.decodeIfPresent(String.self, forKey: .productName) ?? "Product"
        let decodedStores = try container.decodeIfPresent([PriceTrackerStore].self, forKey: .stores) ?? []
        brand = try container.decodeIfPresent(String.self, forKey: .brand)
        productID = try container.decodeIfPresent(String.self, forKey: .productID)
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        initialCurrency = try container.decodeIfPresent(String.self, forKey: .initialCurrency) ?? "USD"
        // Defaulted to keep old JSON decodable; clamps a malformed value into range.
        let fraction = try container.decodeIfPresent(Double.self, forKey: .alertThresholdFraction) ?? 0.10
        alertThresholdFraction = min(max(fraction, 0.01), 0.95)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        // Defaulted to nil so old payloads (no key) read as "alert not yet viewed".
        alertAcknowledgedAt = try container.decodeIfPresent(Date.self, forKey: .alertAcknowledgedAt)
        let decodedInitial = try container.decodeIfPresent(Decimal.self, forKey: .initialPrice)
        // Repair the ≥1-store invariant for any malformed persisted payload.
        if decodedStores.isEmpty {
            let fallbackPrice = decodedInitial ?? 0
            stores = [PriceTrackerStore(
                urlString: "", lastPrice: fallbackPrice, currency: initialCurrency)]
        } else {
            stores = decodedStores
        }
        initialPrice = decodedInitial ?? (stores.compactMap { $0.lastPrice }.min() ?? 0)
    }
}
