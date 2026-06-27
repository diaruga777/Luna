//
//  PriceFormatting.swift
//  Clip
//

import Foundation

/// Pure currency + threshold formatting for price trackers, so the display rules
/// are unit-testable without UIKit. Uses a fixed POSIX locale for currency-symbol
/// placement determinism in tests, while honoring the currency code.
public enum PriceFormatting {
    /// A currency-formatted price string (e.g. "$45.99", "€23.50").
    public static func string(amount: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        // en_US places known symbols ($, €, £) tight against the amount; an
        // unknown code falls back to the code itself ("AUD 89.00").
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        if let formatted = formatter.string(from: amount as NSDecimalNumber) {
            return formatted
        }
        return "\(currency) \(NSDecimalNumber(decimal: amount).stringValue)"
    }

    /// The alert-threshold description shown under the slider, BOTH as a percent
    /// and as the absolute drop (relative to the initial best price), e.g.
    /// "10% off — alert below $90.00".
    public static func thresholdDescription(
        fraction: Double, initialPrice: Decimal, currency: String
    ) -> String {
        let percent = Int((fraction * 100).rounded())
        let absoluteDrop = initialPrice * Decimal(fraction)
        let alertBelow = initialPrice - absoluteDrop
        return "\(percent)% off — alert below \(string(amount: alertBelow, currency: currency))"
    }
}
