//
//  FailedSaveNaming.swift
//  LunaFetch
//

import Foundation
import LunaModels

/// How a failed save is NAMED on its card. A page Luna couldn't read has no
/// stored title, so the card walks a fallback chain instead of showing
/// "Untitled": a real fetched title, then whatever the save already carried,
/// then the URL slug (`/2026/07/how-the-deal-collapsed` → "How The Deal
/// Collapsed"), then the bare host. Pure and unit-tested — the chain is the
/// whole feature, so it shouldn't hide inside a view controller.
public enum FailedSaveNaming {

    /// The card's headline. Never empty.
    /// - Parameters:
    ///   - resolvedTitle: a title recovered by the light metadata read
    ///     (`PageMetadataFetcher`), the best source when present.
    ///   - itemTitle: whatever the store already holds for the item.
    public static func displayTitle(
        url: URL?, itemTitle: String? = nil, resolvedTitle: String? = nil
    ) -> String {
        if let resolved = nonEmpty(resolvedTitle) { return resolved }
        if let stored = nonEmpty(itemTitle), stored != "Untitled" { return stored }
        guard let url else { return L10n.string("Untitled") }
        // `articleTitleGuess` already falls back to the bare host when the slug
        // holds no words, so this is the end of the chain.
        return ArticleFetcher.articleTitleGuess(from: url)
    }

    /// The publisher line under the headline: the fetched `og:site_name` when
    /// there is one, else the host without `www.`. nil when there's no URL at
    /// all (a malformed save).
    public static func displaySiteName(url: URL?, siteName: String? = nil) -> String? {
        if let name = nonEmpty(siteName) { return name }
        guard let host = url?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The full failing URL as the card shows it — scheme dropped (it's noise in
    /// a one-line label) but path and query kept, because WHICH url failed is
    /// the point.
    public static func displayURL(_ url: URL?, rawURLString: String? = nil) -> String {
        let text = url?.absoluteString ?? rawURLString ?? ""
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
