import Foundation

public enum PremiumHappyHour {
    /// A fixed Saturday/Sunday promotion, independent of locale-specific weekends.
    public static func isActive(at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        return [1, 7].contains(parts.weekday ?? 0) && parts.hour == 14
    }

    /// Apple price tiers and currency conversions need not be exactly proportional.
    /// Never advertise 25% off unless the actual StoreKit price saves at least that.
    public static func isEligiblePrice(regular: Decimal, discounted: Decimal,
                                       regularCurrency: String, discountedCurrency: String) -> Bool {
        regularCurrency == discountedCurrency && regular > 0 && discounted > 0 &&
            discounted <= regular * Decimal(string: "0.75")!
    }
}
