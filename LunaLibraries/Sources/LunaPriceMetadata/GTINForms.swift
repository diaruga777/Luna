//
//  GTINForms.swift
//  LunaPriceMetadata
//

import Foundation

/// The same product number, written every way a retailer might write it.
///
/// A GTIN is one number, but the trade uses at least four renderings of it —
/// UPC-A (12), EAN/GTIN-13, GTIN-14, and, for books, the ISBN-10 that predates
/// all of them — and a retailer will happily print one on the page, another in
/// its URL and a third in its JSON. Comparing the digit strings directly means
/// the same book fails to match itself.
///
/// Lives in `LunaPriceMetadata` because it is pure Foundation arithmetic and
/// both tiers need it: the lean comparison engine tests a candidate page for
/// containment of any form, and the rich extraction path turns an Amazon ASIN
/// back into an ISBN-13.
public enum GTINForms {

    /// Just the digits (and a trailing ISBN check `X`), uppercased. Nil when
    /// there are none — a hyphenated ISBN and a spaced EAN both normalize here.
    public static func digits(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let kept = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        return kept.isEmpty ? nil : kept
    }

    /// Every digit form of `raw` a page might print, longest first, deduplicated.
    ///
    /// The order matters for the evidence check that uses this: a 13-digit
    /// string is a far stronger coincidence than a 10-digit one, so the strong
    /// forms are tested before a short one can produce a lucky hit.
    public static func variants(of raw: String?) -> [String] {
        guard let normalized = digits(raw), normalized.count >= 8 else { return [] }
        var forms: [String] = [normalized]

        // GTIN-14: the same number, zero-padded. Some wholesalers only print this.
        if normalized.count < 14, normalized.allSatisfy(\.isNumber) {
            forms.append(String(repeating: "0", count: 14 - normalized.count) + normalized)
            if normalized.count < 13 {
                forms.append(String(repeating: "0", count: 13 - normalized.count) + normalized)
            }
        }
        // UPC-A: a 13-digit number that is a zero-prefixed 12 is usually
        // printed as the 12.
        if normalized.count == 13, normalized.hasPrefix("0") {
            forms.append(String(normalized.dropFirst()))
        }
        // Books: an ISBN-13 and its ISBN-10 are the same book, and Amazon's
        // book ASINs are the ISBN-10.
        if let isbn10 = isbn10(fromISBN13: normalized) { forms.append(isbn10) }
        if let isbn13 = isbn13(fromISBN10: normalized) {
            forms.append(isbn13)
            forms.append("0" + isbn13)
        }

        var seen: Set<String> = []
        return forms
            .filter { $0.count >= 8 && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }

    /// Whether `candidate` is any written form of `reference`.
    public static func sameProduct(_ candidate: String?, as reference: String?) -> Bool {
        guard let candidate = digits(candidate), let reference = digits(reference) else {
            return false
        }
        return Set(variants(of: reference)).contains(candidate)
            || Set(variants(of: candidate)).contains(reference)
    }

    // MARK: - ISBN

    /// The ISBN-10 for a 978-prefixed ISBN-13, with its own check character
    /// recomputed (the two schemes use different check digits, so the last
    /// digit can never simply be carried across).
    public static func isbn10(fromISBN13 raw: String) -> String? {
        let digitsOnly = raw.filter(\.isNumber)
        guard digitsOnly.count == 13, digitsOnly.hasPrefix("978") else { return nil }
        let body = String(digitsOnly.dropFirst(3).dropLast())
        guard body.count == 9 else { return nil }
        var sum = 0
        for (index, character) in body.enumerated() {
            guard let value = character.wholeNumberValue else { return nil }
            sum += value * (10 - index)
        }
        let remainder = (11 - (sum % 11)) % 11
        let check = remainder == 10 ? "X" : String(remainder)
        return body + check
    }

    /// The ISBN-13 for an ISBN-10 — the `978` prefix plus a recomputed EAN
    /// check digit. Nil unless `raw` is a checksum-valid ISBN-10, so a random
    /// ten-character Amazon ASIN is not silently promoted to a book number.
    public static func isbn13(fromISBN10 raw: String) -> String? {
        guard isValidISBN10(raw) else { return nil }
        let body = "978" + raw.uppercased().filter { $0.isNumber || $0 == "X" }.dropLast()
        guard body.count == 12 else { return nil }
        var sum = 0
        for (index, character) in body.enumerated() {
            guard let value = character.wholeNumberValue else { return nil }
            sum += value * (index % 2 == 0 ? 1 : 3)
        }
        return body + String((10 - (sum % 10)) % 10)
    }

    /// Whether `raw` is a checksum-valid ISBN-10. This is what makes
    /// "the ASIN is the ISBN" safe to rely on: `B09XS7JWHH` fails it, and
    /// `0735211299` passes.
    public static func isValidISBN10(_ raw: String) -> Bool {
        let characters = Array(raw.uppercased().filter { $0.isNumber || $0 == "X" })
        guard characters.count == 10 else { return false }
        var sum = 0
        for (index, character) in characters.enumerated() {
            let value: Int
            if character == "X" {
                guard index == 9 else { return false }
                value = 10
            } else {
                guard let digit = character.wholeNumberValue else { return false }
                value = digit
            }
            sum += value * (10 - index)
        }
        return sum % 11 == 0
    }
}
