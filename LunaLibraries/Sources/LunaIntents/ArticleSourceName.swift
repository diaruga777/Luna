//
//  ArticleSourceName.swift
//  LunaIntents
//

import Foundation

/// Derives a display host and a human-readable source name from an article's
/// URL — the host is what `ArticleEntity`'s visible representation shows as
/// the base URL; the human-readable name is a lower-priority matching signal
/// so a spoken "from The Atlantic" can match `theatlantic.com`.
public enum ArticleSourceName {
    /// Second-level labels that precede a country-code TLD (`bbc.co.uk`,
    /// `nytimes.com.au`) — both trailing labels are dropped together when
    /// deriving the human-readable name, instead of just the last one.
    private static let multiPartSecondLevelLabels: Set<String> = [
        "co", "com", "org", "net", "gov", "ac", "edu",
    ]

    /// The literal, `www.`-stripped host (`"theatlantic.com"`) — nil for
    /// synthetic non-web URLs (`lunamail://`, `lunadoc://`) or an unparsable
    /// `urlString`.
    public static func host(fromURLString urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A human-readable source name for matching purposes only (not shown to
    /// the user) — strips the TLD, splits remaining labels on `.`/`-`, and
    /// special-cases a leading "the" run-in (a common news-site naming
    /// pattern a plain dot/hyphen split can't separate): `"theatlantic.com"`
    /// → `"the atlantic"`, `"thehill.com"` → `"the hill"`,
    /// `"new-york-times.com"` → `"new york times"`.
    public static func humanReadable(host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        if labels.count >= 3, multiPartSecondLevelLabels.contains(labels[labels.count - 2]) {
            labels.removeLast(2)
        } else if labels.count >= 2 {
            labels.removeLast()
        }
        var words: [String] = []
        for label in labels {
            for piece in label.split(separator: "-") {
                words.append(contentsOf: splitLeadingThe(String(piece)))
            }
        }
        return words.joined(separator: " ")
    }

    /// `"theatlantic"` → `["the", "atlantic"]`; anything else passes through
    /// unchanged (including bare `"the"`, too short to have a remainder).
    private static func splitLeadingThe(_ word: String) -> [String] {
        guard word.count > 3, word.hasPrefix("the") else { return [word] }
        return ["the", String(word.dropFirst(3))]
    }
}
