//
//  FreshComparablePrices.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// One other retailer's price for the same product, as it is known RIGHT NOW —
/// either read back from something already stored (a tracked store's history
/// point, a passive page snapshot) or just fetched by a fan-out.
///
/// It exists so the "is there a better price than the one on this page?"
/// decision is a pure function over a list, independent of where each price came
/// from. The Safari appex has three sources with three different shapes; the
/// rule below must not know that.
public struct ComparablePricePoint: Equatable, Sendable {
    /// Display name — a directory retailer's, else its registrable domain.
    public let sellerName: String
    /// Registrable domain: what makes one retailer different from another.
    public let domain: String
    /// Where to send someone who taps the answer.
    public let urlString: String
    public let price: Decimal
    public let currency: String
    /// When this price was observed. For a source that only records a DAY, the
    /// day's UTC start is the honest reading — see `FreshComparablePrices`.
    public let capturedAt: Date

    public init(
        sellerName: String, domain: String, urlString: String,
        price: Decimal, currency: String, capturedAt: Date
    ) {
        self.sellerName = sellerName
        self.domain = domain
        self.urlString = urlString
        self.price = price
        self.currency = currency
        self.capturedAt = capturedAt
    }
}

/// The rule that decides whether a stored price is still worth showing, and
/// which of several is the answer.
///
/// Separate from both the fan-out and the appex because it is the one piece of
/// this feature a test can pin exactly: everything around it is network or
/// container I/O.
public enum FreshComparablePrices {

    /// How recent a comparable price must be to be shown as a CURRENT one.
    ///
    /// The passive snapshot store keeps 365 days and the history index keeps a
    /// year of daily points — plenty of material for the "Was $X on <date>"
    /// pill, which is explicitly about the past. An alternative-seller pill
    /// makes the opposite claim ("it costs less over there, now"), so a price
    /// from last week is not evidence for it; 24h is the same window
    /// `SafariURLStore.isFresh` already uses for "recent enough to act on".
    public static let freshnessWindow: TimeInterval = 24 * 60 * 60

    /// Whether a price observed at `capturedAt` is still current.
    ///
    /// A future timestamp (clock skew between the app and the extension, or a
    /// device whose clock moved) is treated as fresh rather than discarded: it
    /// is certainly not older than a day.
    public static func isFresh(_ capturedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(capturedAt) < freshnessWindow
    }

    /// The best answer among `points` for a page currently showing
    /// `pagePrice` `pageCurrency` on `pageDomain`, or nil when there is none.
    ///
    /// Four conditions, all of them refusals rather than preferences:
    ///
    /// - **Fresh** (`isFresh`) — a stale price is not a claim about today.
    /// - **Same currency.** There is no FX source anywhere in Luna (see
    ///   `PriceDaySnapshot.fxRate`, which nothing populates), so comparing
    ///   across currencies would be inventing a rate.
    /// - **Strictly cheaper** than the page. "The same price somewhere else" is
    ///   not worth a pill, and a dearer one is worth less than nothing.
    /// - **A different retailer.** The page's own domain is not an alternative
    ///   to itself, and a second URL on the same host is the same shop.
    ///
    /// Ties break on the domain so the same inputs always name the same seller.
    public static func lowestCheaper(
        among points: [ComparablePricePoint],
        pagePrice: Decimal,
        pageCurrency: String,
        pageDomain: String,
        now: Date
    ) -> ComparablePricePoint? {
        let currency = pageCurrency.uppercased()
        let domain = pageDomain.lowercased()
        return points
            .filter { point in
                point.price > 0
                    && point.price < pagePrice
                    && point.currency.uppercased() == currency
                    && point.domain.lowercased() != domain
                    && isFresh(point.capturedAt, now: now)
            }
            .min { lhs, rhs in
                lhs.price != rhs.price ? lhs.price < rhs.price : lhs.domain < rhs.domain
            }
    }
}

extension ComparableSellerResult {

    /// This result as a passive product-snapshot payload — the SAME key shape
    /// `content.js`'s `extractProductSnapshot()` sends for a page the user
    /// actually visited.
    ///
    /// A fan-out result is exactly what a snapshot is: a named product, at a
    /// price, in a currency, on one retailer's page, with whatever identifiers
    /// that page declared. Writing them through the same door means a price
    /// found for the pill also feeds the "Was $X" history and a later save's
    /// seeded history, with no second store and no second record shape to keep
    /// in sync.
    public var snapshotPayload: [String: String] {
        var payload: [String: String] = [
            "name": productName,
            "price": NSDecimalNumber(decimal: price).stringValue,
            "currency": currency,
            "url": url.absoluteString,
        ]
        if let gtin = identifiers.gtin { payload["gtin"] = gtin }
        if let mpn = identifiers.mpn { payload["mpn"] = mpn }
        if let sku = identifiers.sku { payload["sku"] = sku }
        if let brand = identifiers.brand { payload["brand"] = brand }
        return payload
    }

    /// This result as a comparison point, for `FreshComparablePrices` — fetched
    /// now, so `capturedAt` is now.
    public func pricePoint(now: Date) -> ComparablePricePoint {
        ComparablePricePoint(
            sellerName: sellerName, domain: domain, urlString: url.absoluteString,
            price: price, currency: currency, capturedAt: now)
    }
}
