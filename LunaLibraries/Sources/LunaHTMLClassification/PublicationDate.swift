//
//  PublicationDate.swift
//  LunaHTMLClassification
//

import Foundation

/// When a page says it was published. Read straight out of the markup a publisher
/// already ships for search and social (`article:published_time`, schema.org
/// `datePublished`, `<time datetime>`) — no extra request, no per-host knowledge.
///
/// This exists to answer ONE scheduling question cheaply: *could this article have been
/// free before it was walled?* The `.waybackPrePaywall` bypass strategy hunts for the era
/// before a publisher metered something it had put out free — The Paris Review's 1969
/// interviews, walled decades later. Resolving that costs a Wayback index lookup, which
/// is the slowest and least reliable service in the whole pipeline (measured 1.7s–16s on
/// consecutive lookups of the same URL). A story published this week was walled the day
/// it went out, so the lookup provably cannot help and is simply not scheduled — which is
/// how a save of today's paywalled news stops paying for yesterday's long shot.
public enum PublicationDate {

    /// The publication date declared in `html`, or nil when the page declares none in a
    /// shape we recognize. Pure.
    ///
    /// Deliberately a scan of the raw markup rather than a parse: this runs on the
    /// paywalled path where the page has already been parsed once, the shapes below are
    /// unambiguous enough that a scan can't confuse them for something else, and a wrong
    /// answer only costs a long-shot strategy either way.
    public static func declared(inHTML html: String) -> Date? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let ns = html as NSString
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges >= 2 {
                if let date = parseISO8601(ns.substring(with: match.range(at: 1))) { return date }
            }
        }
        return nil
    }

    /// Whether `html` PROVES the article is younger than `age`. False when the page
    /// declares no date: absence of evidence is never proof, so an undated page keeps
    /// every strategy it would otherwise have had.
    public static func provesYounger(
        than age: TimeInterval, html: String, now: Date = Date()
    ) -> Bool {
        guard let published = declared(inHTML: html) else { return false }
        // A future-dated page (embargo slip, bad timezone) is certainly not old.
        return now.timeIntervalSince(published) < age
    }

    /// The declaration shapes, most authoritative first. Each captures the date in group
    /// 1. Attribute order varies by CMS, so `content`-before-`property` and the reverse
    /// both appear.
    private static let patterns: [String] = [
        // <meta property="article:published_time" content="…"> (and og: / itemprop /
        // name= variants, either attribute order)
        #"<meta[^>]+(?:property|name|itemprop)\s*=\s*["'](?:og:)?(?:article:)?(?:published_time|datePublished|publish-date|pubdate)["'][^>]+content\s*=\s*["']([^"']+)["']"#,
        #"<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]+(?:property|name|itemprop)\s*=\s*["'](?:og:)?(?:article:)?(?:published_time|datePublished|publish-date|pubdate)["']"#,
        // schema.org JSON-LD "datePublished": "…"
        #""datePublished"\s*:\s*"([^"]+)""#,
        // <time datetime="…"> — last: it also marks comment and related-story stamps,
        // so it only speaks when nothing more explicit did.
        #"<time[^>]+datetime\s*=\s*["']([^"']+)["']"#,
    ]

    /// Parses the date shapes publishers actually emit: full ISO 8601 with or without
    /// fractional seconds, and a bare `yyyy-MM-dd`.
    private static func parseISO8601(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = isoFractional.date(from: trimmed) { return date }
        if let date = isoPlain.date(from: trimmed) { return date }
        return dayOnly.date(from: String(trimmed.prefix(10)))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
