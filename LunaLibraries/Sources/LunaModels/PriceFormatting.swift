//
//  PriceFormatting.swift
//  Luna
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

    /// The currency marker drawn once at the top of a price axis. Axis tick
    /// labels deliberately omit it: repeating `$` down a narrow graph spends
    /// scarce horizontal room without adding information.
    public static func axisCurrencySymbol(currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = currency
        return formatter.currencySymbol ?? currency
    }

    /// A price-axis tick without a currency symbol.
    ///
    /// Values from ten thousand upward are compacted to a whole `k`/`m`, while
    /// four-digit prices remain expanded. When a host cannot afford fractional
    /// digits it asks for `showsFractionalDigits: false`; the half boundary is
    /// intentionally conservative (`10.50` → `10`, `10.51` → `11`) so a tick at
    /// exactly half a unit does not claim the next whole price.
    public static func axisString(
        amount: Decimal, currency: String, showsFractionalDigits: Bool = true
    ) -> String {
        let value = (amount as NSDecimalNumber).doubleValue
        let magnitude = abs(value)
        if magnitude >= 1_000_000 {
            return signedCompact(value / 1_000_000, suffix: "m")
        }
        if magnitude >= 10_000 {
            return signedCompact(value / 1_000, suffix: "k")
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = showsFractionalDigits ? 2 : 0
        formatter.maximumFractionDigits = showsFractionalDigits ? 2 : 0
        let displayed = showsFractionalDigits ? value : roundedWholeHalfDown(value)
        return formatter.string(from: NSNumber(value: displayed))
            ?? NSDecimalNumber(decimal: amount).stringValue
    }

    private static func signedCompact(_ value: Double, suffix: String) -> String {
        let rounded = roundedWholeHalfDown(value)
        return "\(Int(rounded))\(suffix)"
    }

    private static func roundedWholeHalfDown(_ value: Double) -> Double {
        let sign = value < 0 ? -1.0 : 1.0
        let magnitude = abs(value)
        let whole = floor(magnitude)
        let rounded = magnitude - whole > 0.50 ? whole + 1 : whole
        return sign * rounded
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
