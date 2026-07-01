//
//  PriceParsing.swift
//  LunaModels
//

import Foundation

/// Pure price/currency string parsing shared by the price models and the HTML
/// product detectors, so neither has to depend on the other. Moved down here so
/// `PriceTracker` (a base model) can parse a shared price string without an
/// upward dependency on the HTML-classification layer.
public enum PriceParsing {
    /// Parses a human price string ("$1,234.56", "1.234,56", "23,50 €") into a
    /// `Decimal`, inferring the decimal vs thousands separator. Returns nil when
    /// no numeric value is present.
    public static func parsePrice(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Keep digits and separators only.
        let allowed = Set("0123456789.,")
        let filtered = String(trimmed.filter { allowed.contains($0) })
        guard !filtered.isEmpty, filtered.contains(where: \.isNumber) else { return nil }

        let lastDot = filtered.lastIndex(of: ".")
        let lastComma = filtered.lastIndex(of: ",")
        var normalized = filtered

        switch (lastDot, lastComma) {
        case let (dot?, comma?):
            // Both present: the later one is the decimal separator.
            if dot > comma {
                normalized = filtered.replacingOccurrences(of: ",", with: "")
            } else {
                normalized = filtered.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            }
        case (_?, nil):
            normalized = filtered   // dot already the decimal point
        case let (nil, comma?):
            // Only a comma: decimal separator if followed by 1–2 digits, else a
            // thousands grouping (e.g. "1,234").
            let afterComma = filtered.distance(from: comma, to: filtered.endIndex) - 1
            if afterComma == 1 || afterComma == 2 {
                normalized = filtered.replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = filtered.replacingOccurrences(of: ",", with: "")
            }
        case (nil, nil):
            break
        }
        return Decimal(string: normalized)
    }

    /// Normalizes a currency code or symbol to an ISO code ("$"→"USD"), or nil.
    public static func normalizeCurrency(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let upper = raw.uppercased()
        if upper.count == 3, upper.allSatisfy(\.isLetter) { return upper }
        switch raw {
        case "$": return "USD"
        case "£": return "GBP"
        case "€": return "EUR"
        case "¥": return "JPY"
        default: return nil
        }
    }
}
