//
//  PriceHistory.swift
//  ReaderKit
//

import Foundation

/// Time granularity the graph buckets into as the span grows.
public enum PriceGraphBucket: Equatable {
    case day, week, month, year

    public var calendarComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

/// One plotted point: the lowest price in its bucket, the bucket's start date, and
/// which store held that low (for the scrubber popover).
public struct PriceGraphPoint: Equatable {
    public let date: Date
    public let price: Decimal
    public let currency: String
    public let storeURLString: String

    public init(date: Date, price: Decimal, currency: String, storeURLString: String) {
        self.date = date
        self.price = price
        self.currency = currency
        self.storeURLString = storeURLString
    }
}

/// Pure aggregation of a tracker's per-store day-bucketed history into a single
/// display series. The base series is the lowest price across all stores per
/// calendar day; as the overall span grows the series re-buckets day → week →
/// month → year, taking the lowest within each larger bucket. Unit-tested.
///
/// Currency: v1 assumes a single display currency (the common case — one product
/// across stores in one region) and plots `lowestPrice` directly; a snapshot's
/// `fxRate` is applied when present so a future FX source needs no migration.
public enum PriceHistory {
    /// Below this many distinct days of data the view shows "Awaiting more data".
    public static let minimumDaysForGraph = 3

    /// Number of distinct calendar days that have a sample across all stores.
    public static func distinctDayCount(_ tracker: PriceTracker) -> Int {
        var days = Set<Date>()
        for store in tracker.stores {
            for sample in store.priceHistory { days.insert(sample.dayStart) }
        }
        return days.count
    }

    /// The bucket granularity for a span of `days`.
    public static func bucket(forSpanDays days: Int) -> PriceGraphBucket {
        switch days {
        case ..<61: return .day        // up to ~2 months: every day
        case ..<366: return .week      // up to ~1 year: weekly
        case ..<(366 * 3): return .month  // up to ~3 years: monthly
        default: return .year
        }
    }

    /// The display series for the tracker's graph (empty if no history).
    public static func series(
        for tracker: PriceTracker, now: Date = Date(), calendar: Calendar = .current
    ) -> [PriceGraphPoint] {
        // 1. Per-day lowest across all stores.
        var perDay: [Date: PriceGraphPoint] = [:]
        for store in tracker.stores {
            for sample in store.priceHistory {
                let value = convertedPrice(sample)
                if let existing = perDay[sample.dayStart], existing.price <= value { continue }
                perDay[sample.dayStart] = PriceGraphPoint(
                    date: sample.dayStart, price: value, currency: tracker.displayCurrency,
                    storeURLString: store.urlString)
            }
        }
        let daily = perDay.values.sorted { $0.date < $1.date }
        guard let first = daily.first?.date, let last = daily.last?.date else { return [] }

        let spanDays = max(0, calendar.dateComponents([.day], from: first, to: last).day ?? 0)
        let granularity = bucket(forSpanDays: spanDays)
        if granularity == .day { return daily }

        // 2. Re-bucket the daily lows into the coarser period, lowest per period.
        var perBucket: [Date: PriceGraphPoint] = [:]
        for point in daily {
            let start = calendar.dateInterval(of: granularity.calendarComponent, for: point.date)?.start
                ?? point.date
            if let existing = perBucket[start], existing.price <= point.price { continue }
            perBucket[start] = PriceGraphPoint(
                date: start, price: point.price, currency: point.currency,
                storeURLString: point.storeURLString)
        }
        return perBucket.values.sorted { $0.date < $1.date }
    }

    /// Price in the display currency: applies the snapshot's FX rate when present,
    /// else uses the value as-is (single-currency assumption — see type doc).
    private static func convertedPrice(_ sample: PriceDaySnapshot) -> Decimal {
        if let rate = sample.fxRate { return sample.lowestPrice * rate }
        return sample.lowestPrice
    }
}
