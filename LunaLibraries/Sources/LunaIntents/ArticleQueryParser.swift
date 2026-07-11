//
//  ArticleQueryParser.swift
//  LunaIntents
//

import Foundation

/// A Siri/Shortcuts search string split into an optional relative-date filter
/// and the remaining free-text tokens (title/source matching material).
public struct ArticleParsedQuery: Equatable {
    public let dateFilter: ArticleRelativeDateFilter?
    public let textTokens: [String]
}

/// Pure text handling for `ArticleMatcher`: normalization, tokenization, and
/// pulling a relative-date phrase out of a raw query string.
public enum ArticleQueryParser {
    /// Checked longest-phrase-first so "this week" doesn't leave a stray
    /// "week" token that could spuriously (mis)match a title.
    private static let phraseFilters: [(phrase: String, filter: ArticleRelativeDateFilter)] = [
        ("this week", .thisWeek),
        ("yesterday", .yesterday),
        ("today", .today),
    ]

    /// Extracts (at most) one relative-date phrase, then tokenizes whatever's
    /// left for title/source matching.
    public static func parse(_ rawQuery: String) -> ArticleParsedQuery {
        var remaining = normalize(rawQuery)
        var dateFilter: ArticleRelativeDateFilter?
        for (phrase, filter) in phraseFilters where remaining.contains(phrase) {
            dateFilter = filter
            remaining = remaining.replacingOccurrences(of: phrase, with: " ")
            break
        }
        return ArticleParsedQuery(dateFilter: dateFilter, textTokens: tokenize(remaining))
    }

    /// Case- and diacritic-insensitive lowercase fold ("Café" ≡ "cafe").
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    /// Splits already-normalized text on runs of non-alphanumeric characters.
    public static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
    }
}
