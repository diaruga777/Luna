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
        guard let url else { return L10n.string("Common_untitled") }
        // `articleTitleGuess` already falls back to the bare host when the slug
        // holds no words, so this is the end of the chain.
        if URLBehaviorPolicy.pluginsOnly { return url.host ?? url.absoluteString }
        return ArticleFetcher.articleTitleGuess(from: url)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
