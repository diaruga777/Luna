//
//  ArticleMatcher.swift
//  LunaIntents
//

import LunaModels
import Foundation

/// Selection/ranking logic behind `ArticleEntity`'s query (`Luna/Intents/
/// ArticleEntity.swift`) and `ReadArticleIntent`'s nil-entity fallback. Kept
/// as plain, store-free functions over `[ReadingListItem]` so it's
/// unit-testable without AppIntents, CoreSpotlight, or a real
/// `ReadingListStore`. Never loads `ArticleContent` — matching uses only
/// `title`/`urlString`/`dateAdded`, so it stays cheap over a large list.
public enum ArticleMatcher {
    /// The `EntityStringQuery.entities(matching:)` workhorse: matches
    /// "about ⟨title words⟩" and "from ⟨source⟩" phrases against title
    /// tokens and source tokens (host + `ArticleSourceName.humanReadable`),
    /// with an optional "yesterday"/"today"/"this week" date filter parsed
    /// out of the query text. Readable articles only. Best matches first,
    /// ties (including "no text to match, just a date filter") broken by
    /// recency — which also makes "latest ⟨date/source⟩" phrasing fall out
    /// naturally rather than needing separate handling.
    public static func search(
        query: String, in items: [ReadingListItem],
        now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian),
        limit: Int = 10
    ) -> [ReadingListItem] {
        let parsed = ArticleQueryParser.parse(query)
        let readable = items.filter(ArticleReadability.isReadableArticle)
        let dateFiltered: [ReadingListItem]
        if let dateFilter = parsed.dateFilter {
            dateFiltered = readable.filter {
                ArticleRelativeDateFilter.matches(date: $0.dateAdded, filter: dateFilter, now: now, calendar: calendar)
            }
        } else {
            dateFiltered = readable
        }

        guard !parsed.textTokens.isEmpty else {
            // Query was pure date words ("yesterday") or had no distinguishing
            // text at all — recency alone (within the date filter, if any) ranks.
            return Array(dateFiltered.sorted { $0.dateAdded > $1.dateAdded }.prefix(limit))
        }

        let scored: [(item: ReadingListItem, score: Double)] = dateFiltered.compactMap { item in
            let score = matchScore(item: item, queryTokens: parsed.textTokens)
            return score > 0 ? (item, score) : nil
        }
        return scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.item.dateAdded > rhs.item.dateAdded
            }
            .prefix(limit)
            .map(\.item)
    }

    /// Recent unread readable articles, newest first — `suggestedEntities()`.
    public static func suggested(in items: [ReadingListItem], limit: Int = 10) -> [ReadingListItem] {
        Array(
            items
                .filter { ArticleReadability.isReadableArticle($0) && $0.readState == .unopened }
                .sorted { $0.dateAdded > $1.dateAdded }
                .prefix(limit))
    }

    /// The newest-saved unread readable article — `ReadArticleIntent`'s
    /// nil-entity fallback ("Read my latest ⟨app⟩ article").
    public static func latestUnread(in items: [ReadingListItem]) -> ReadingListItem? {
        items
            .filter { ArticleReadability.isReadableArticle($0) && $0.readState == .unopened }
            .max { $0.dateAdded < $1.dateAdded }
    }

    /// Title-token matches count double; source-token matches (host + human
    /// name) count triple — a query built around "from ⟨source⟩" should
    /// outweigh an incidental word overlap in an unrelated article's title.
    private static func matchScore(item: ReadingListItem, queryTokens: [String]) -> Double {
        let titleTokens = Set(ArticleQueryParser.tokenize(ArticleQueryParser.normalize(item.title ?? "")))
        var sourceTokens: Set<String> = []
        if let host = ArticleSourceName.host(fromURLString: item.urlString) {
            sourceTokens.formUnion(ArticleQueryParser.tokenize(host))
            sourceTokens.formUnion(ArticleQueryParser.tokenize(ArticleSourceName.humanReadable(host: host)))
        }
        var score = 0.0
        for token in queryTokens {
            if titleTokens.contains(token) { score += 2 }
            if sourceTokens.contains(token) { score += 3 }
        }
        return score
    }
}
