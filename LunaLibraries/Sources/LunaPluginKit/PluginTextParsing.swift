//
//  PluginTextParsing.swift
//  LunaPluginKit
//

import Foundation
import LunaModels
import SwiftSoup

/// The `luna.text` helpers, as pure functions over a string.
///
/// A generated plugin re-implements these three by hand more often than any
/// other part of an extractor, and gets them wrong: a European price reads as
/// a thousand times its value, a `datePublished` reaches Luna in a shape
/// nothing parses, and a scraped label keeps its `&nbsp;` runs.
///
/// Three backings answer the same questions: this one (JavaScriptCore, and the
/// Safari appex for a relayed call), `plugin_host.js` in the Safari
/// content-script world, and `bridge.mjs` in the node harness.
/// `LunaTests/Fixtures/Plugins/html-subset.spec.js` is the specification all
/// three run.
public enum PluginTextParsing {

    // MARK: - price

    /// A price and its currency, as a plugin Model spells them: the amount is
    /// digits and an optional dot, the currency an ISO 4217 code.
    public struct Price: Equatable, Sendable {
        public let amount: String
        public let currency: String?

        public init(amount: String, currency: String?) {
            self.amount = amount
            self.currency = currency
        }
    }

    /// The symbols `PriceParsing.normalizeCurrency` knows. The table is
    /// repeated in `plugin_host.js` and `bridge.mjs`; the spec file pins the
    /// three to each other.
    static let currencySymbols = ["$", "£", "€", "¥"]

    /// `"$1,299.00"` → `1299.00 USD`, `"1.299,00 €"` → `1299.00 EUR`.
    ///
    /// The amount comes from `PriceParsing`, so a plugin's price reads the way
    /// Luna's own product detectors read the same page. The currency is taken
    /// only from what touches the number — a symbol, or a three-letter code
    /// directly before or after it — so a sentence that happens to contain
    /// upper-case words does not name a currency.
    public static func price(_ raw: String) -> Price? {
        guard let run = numberRun(in: raw) else { return nil }
        guard let amount = PriceParsing.normalizedAmountText(String(raw[run])) else { return nil }
        let before = String(raw[raw.startIndex..<run.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let after = String(raw[run.upperBound...]).trimmingCharacters(in: .whitespaces)
        let currency = adjacentCurrency(before: before, after: after)
        return Price(amount: amount, currency: currency)
    }

    /// The first run of digits and separators. Everything outside it is prose.
    private static func numberRun(in raw: String) -> Range<String.Index>? {
        guard let first = raw.firstIndex(where: \.isNumber) else { return nil }
        var end = first
        while end < raw.endIndex, raw[end].isNumber || raw[end] == "." || raw[end] == "," {
            end = raw.index(after: end)
        }
        // A trailing separator belongs to the sentence, not to the number.
        while end > first, raw[raw.index(before: end)] == "." || raw[raw.index(before: end)] == "," {
            end = raw.index(before: end)
        }
        return first..<end
    }

    /// A symbol or ISO code touching the number, prefix first.
    private static func adjacentCurrency(before: String, after: String) -> String? {
        for symbol in currencySymbols where before.hasSuffix(symbol) || after.hasPrefix(symbol) {
            return PriceParsing.normalizeCurrency(symbol)
        }
        if let code = trailingCode(of: before) ?? leadingCode(of: after) {
            return PriceParsing.normalizeCurrency(code)
        }
        return nil
    }

    private static func trailingCode(of text: String) -> String? {
        let letters = text.reversed().prefix { $0.isLetter }
        let code = String(letters.reversed())
        return code.count == 3 && code == code.uppercased() ? code : nil
    }

    private static func leadingCode(of text: String) -> String? {
        let code = String(text.prefix { $0.isLetter })
        return code.count == 3 && code == code.uppercased() ? code : nil
    }

    // MARK: - date

    /// An absolute date as ISO 8601, or nil.
    ///
    /// A date with a time answers `2024-03-04T09:30:00Z` (converted to UTC; a
    /// time with no zone is read as UTC). A date with no time answers
    /// `2024-03-04`, which is what the page actually said. A relative phrase
    /// ("2 hours ago", "yesterday") answers nil rather than a guess at what
    /// "now" was when the page was written.
    public static func date(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let parsed = isoDate(text) { return parsed }
        if let parsed = numericDate(text) { return parsed }
        if let parsed = monthNameDate(text) { return parsed }
        if let parsed = rfc2822Date(text) { return parsed }
        return nil
    }

    /// `2024-03-04T09:30:00Z`, `…+01:00`, `…09:30:00.123Z`, or a bare
    /// `2024-03-04`.
    private static func isoDate(_ text: String) -> String? {
        guard let match = firstMatch(
            #"^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?"#
                + #"\s*(Z|z|[+-]\d{2}:?\d{2})?)?$"#, in: text)
        else { return nil }
        let year = Int(match[1]) ?? 0
        let month = Int(match[2]) ?? 0
        let day = Int(match[3]) ?? 0
        guard match[4].isEmpty else {
            return instant(
                year: year, month: month, day: day,
                hour: Int(match[4]) ?? 0, minute: Int(match[5]) ?? 0,
                second: Int(match[6]) ?? 0, zone: match[7])
        }
        return plainDate(year: year, month: month, day: day)
    }

    /// `04/03/2024` is ambiguous the world over, so only `YYYY/MM/DD` counts.
    private static func numericDate(_ text: String) -> String? {
        guard let match = firstMatch(#"^(\d{4})/(\d{1,2})/(\d{1,2})$"#, in: text) else {
            return nil
        }
        return plainDate(year: Int(match[1]) ?? 0, month: Int(match[2]) ?? 0, day: Int(match[3]) ?? 0)
    }

    /// `March 4, 2024`, `Mar 4 2024`, `4 March 2024`.
    private static func monthNameDate(_ text: String) -> String? {
        if let match = firstMatch(#"^([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})$"#,
                                  in: text),
           let month = monthNumber(match[1]) {
            return plainDate(year: Int(match[3]) ?? 0, month: month, day: Int(match[2]) ?? 0)
        }
        if let match = firstMatch(#"^(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})$"#,
                                  in: text),
           let month = monthNumber(match[2]) {
            return plainDate(year: Int(match[3]) ?? 0, month: month, day: Int(match[1]) ?? 0)
        }
        return nil
    }

    /// `Mon, 04 Mar 2024 09:30:00 GMT` — the shape an RSS feed and an HTTP
    /// `Last-Modified` header both use.
    private static func rfc2822Date(_ text: String) -> String? {
        guard let match = firstMatch(
            #"^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})"#
                + #"\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*(GMT|UTC|Z|[+-]\d{4})?$"#, in: text),
            let month = monthNumber(match[2])
        else { return nil }
        return instant(
            year: Int(match[3]) ?? 0, month: month, day: Int(match[1]) ?? 0,
            hour: Int(match[4]) ?? 0, minute: Int(match[5]) ?? 0, second: Int(match[6]) ?? 0,
            zone: match[7])
    }

    private static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    private static func monthNumber(_ name: String) -> Int? {
        let lower = name.lowercased()
        for (index, month) in monthNames.enumerated() {
            if month == lower || (lower.count == 3 && month.hasPrefix(lower)) { return index + 1 }
        }
        return nil
    }

    /// `YYYY-MM-DD`, or nil when the numbers are not a real day.
    private static func plainDate(year: Int, month: Int, day: Int) -> String? {
        guard isRealDay(year: year, month: month, day: day) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The same moment in UTC, as `YYYY-MM-DDTHH:MM:SSZ`.
    private static func instant(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, zone: String
    ) -> String? {
        guard isRealDay(year: year, month: month, day: day),
              hour < 24, minute < 60, second < 60
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let base = calendar.date(from: components) else { return nil }
        let shifted = base.addingTimeInterval(-Double(offsetSeconds(zone)))
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: shifted)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Seconds east of UTC. An absent or unrecognized zone reads as UTC — the
    /// page gave no offset, so none is invented.
    private static func offsetSeconds(_ zone: String) -> Int {
        let text = zone.trimmingCharacters(in: .whitespaces)
        guard let match = firstMatch(#"^([+-])(\d{2}):?(\d{2})$"#, in: text) else { return 0 }
        let magnitude = (Int(match[2]) ?? 0) * 3600 + (Int(match[3]) ?? 0) * 60
        return match[1] == "-" ? -magnitude : magnitude
    }

    private static func isRealDay(year: Int, month: Int, day: Int) -> Bool {
        guard year >= 1000, year <= 9999, month >= 1, month <= 12, day >= 1 else { return false }
        let lengths = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// The capture groups of the first match, index 0 the whole match. An
    /// absent optional group reads as an empty string, so a caller tests
    /// `isEmpty` rather than unwrapping.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }

    // MARK: - clean

    /// Entities decoded, tags dropped, every whitespace run — a `&nbsp;` run
    /// included — collapsed to one space, and the result trimmed.
    ///
    /// It reads the text out of an HTML parse, the same way `luna.html.text`
    /// does, so a scraped label carrying stray markup cleans up rather than
    /// showing its tags.
    public static func clean(_ raw: String) -> String {
        let stripped = (try? SwiftSoup.parse(raw))
            .flatMap { try? $0.text() } ?? raw
        return collapseWhitespace(stripped)
    }

    /// Any run of Unicode whitespace becomes one space. `Character
    /// .isWhitespace` follows the Unicode White_Space property, so a
    /// no-break space collapses like a plain one.
    public static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(character)
        }
        return out
    }
}
