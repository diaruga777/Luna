//
//  ProductTitleSummary.swift
//  LunaPriceUI
//

import Foundation

/// Splits a scraped product title into the two things a product surface shows:
/// the **headline** — a word or three that names the thing — and the **detail**,
/// the full title underneath in small type.
///
/// A retailer's `<title>` is not a product name. It is a product name followed by
/// the marketplace, the category path, and often a variant list:
/// "Panasonic spare blade men's shaver 6-blade ES9600 : Amazon.com.au: Health,
/// Household & Personal Care". Rendered at `title3` across three lines, that
/// pushed the graph and the seller list off the bottom of the card and told the
/// reader nothing the first three words hadn't. So the card leads with the three
/// words and keeps the rest, smaller, below — nothing is hidden, it is just
/// ranked.
///
/// Pure and heuristic, in that order: every rule below is about SHAPE (separators,
/// brackets, digits), never about a vocabulary of brands or nouns, so it degrades
/// to "the first few words" rather than to a wrong guess.
public enum ProductTitleSummary {

    /// The most words a headline may carry. Three is the point where a
    /// marketplace title stops naming a product and starts describing it.
    static let maximumWords = 3
    /// …unless three of them are this long, in which case two read better on a
    /// card that is 320pt wide.
    static let maximumCharacters = 30

    /// The short name: at most three words off the front of the title's first
    /// segment, stopping early at a model code once the name already stands up
    /// on its own ("Apple iPhone", not "Apple iPhone 15").
    public static func headline(for title: String) -> String {
        let words = self.words(in: primarySegment(of: title))
        guard !words.isEmpty else { return collapsed(title) }
        var picked: [String] = []
        for word in words {
            // A code is a name only while nothing else has named the product:
            // "Sony WH-1000XM5" keeps its model, "Apple iPhone 15" drops it.
            if picked.count >= 2, isModelCode(word) { break }
            picked.append(word)
            if picked.count == maximumWords { break }
        }
        while picked.count > 1, picked.joined(separator: " ").count > maximumCharacters {
            picked.removeLast()
        }
        return picked.joined(separator: " ")
    }

    /// The whole title, whitespace-collapsed — or nil when it says nothing the
    /// headline didn't, so a short product name never draws a duplicate line
    /// under itself.
    public static func detail(for title: String) -> String? {
        let full = collapsed(title)
        let short = headline(for: title)
        guard !full.isEmpty, full.compare(short, options: .caseInsensitive) != .orderedSame
        else { return nil }
        return full
    }

    // MARK: - Shape

    /// The characters that end a product name and begin a marketplace's own
    /// prose. `-` is absent on purpose: it is a hyphen inside "6-blade" far more
    /// often than it is a separator, and the spaced form is handled below.
    private static let separators: Set<Character> = ["|", ":", "–", "—", "·", ",", ";", "\n"]

    /// The title up to its first separator, with bracketed asides removed. Never
    /// empty: a title that opens with a separator keeps the whole string.
    static func primarySegment(of title: String) -> String {
        var text = collapsed(withoutBracketedAsides(title))
        for spaced in [" - ", " -- "] {
            if let range = text.range(of: spaced) { text = String(text[..<range.lowerBound]) }
        }
        if let index = text.firstIndex(where: { separators.contains($0) }) {
            let head = String(text[..<index]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        return text
    }

    /// A token that identifies a MODEL rather than naming a product: it carries a
    /// digit. Deliberately crude — "4K", "256GB", "ES9600" and "15" are all the
    /// same kind of thing to a reader skimming a card.
    static func isModelCode(_ word: String) -> Bool {
        word.contains { $0.isNumber }
    }

    private static func words(in segment: String) -> [String] {
        segment
            .split(whereSeparator: { $0 == " " })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Drops `(…)`, `[…]` and `{…}` groups — a parenthesised aside is never the
    /// product's name, and an unclosed bracket leaves the text alone.
    private static func withoutBracketedAsides(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth = max(0, depth - 1)
            default: if depth == 0 { result.append(character) }
            }
        }
        return depth == 0 ? result : text
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
