//
//  PageMetadataFetcher.swift
//  LunaFetch
//
//  The last-resort naming pass for a save Luna could never read. A `.failed`
//  item almost by definition has no title: `ArticleResolver` only reports
//  `.unreadable` when it couldn't get even a `<title>` out of the page, so the
//  card would otherwise be headed "Untitled".
//
//  This is a SEPARATE, much cheaper read than article ingestion — it wants only
//  the <head> — so it frequently succeeds where extraction failed (a timeout, a
//  transient 5xx, a body too big to extract). When the page itself stays
//  unreachable it falls back to the site's HOMEPAGE for a publisher name, which
//  is nearly always reachable, and the caller pairs that with a slug guess.
//
//  Networking + parsing only; persistence is the caller's job (the app writes
//  the winner into the `SaveFailureStore` sidecar so a cold launch doesn't
//  refetch).
//

import Foundation
import LunaModels
import SwiftSoup

/// The naming metadata a failed card can show: the page's own title and the
/// publisher name behind it. Either half may be missing.
public struct PageMetadata: Equatable, Sendable {
    public var title: String?
    public var siteName: String?

    public init(title: String? = nil, siteName: String? = nil) {
        self.title = title
        self.siteName = siteName
    }

    public var isEmpty: Bool { title == nil && siteName == nil }
}

public struct PageMetadataFetcher {

    private let fetcher: HTMLFetching

    public init(fetcher: HTMLFetching = ArticleFetcher()) {
        self.fetcher = fetcher
    }

    /// Best-effort title + site name for `url`. Tries the page itself, then the
    /// site's homepage for a publisher name only. Never throws — a failed card
    /// degrades to a slug guess, it doesn't break.
    public func fetchMetadata(for url: URL) async -> PageMetadata {
        if URLBehaviorPolicy.pluginsOnly { return PageMetadata() }
        var result = PageMetadata()
        if let html = try? await fetcher.fetchHTML(from: url) {
            result = Self.metadata(inHTML: html)
        }
        guard result.title == nil || result.siteName == nil else { return result }

        // The page is unreachable (or nameless). Its site almost certainly
        // isn't: a homepage read gives us "The New York Times" for a card that
        // would otherwise say nothing but a bare host.
        guard let origin = Self.origin(of: url), origin != url,
              let homeHTML = try? await fetcher.fetchHTML(from: origin)
        else { return result }
        let home = Self.metadata(inHTML: homeHTML)
        // Never take the homepage's TITLE as the article's title — it names the
        // site, not this page. Only the site name transfers.
        if result.siteName == nil { result.siteName = home.siteName ?? home.title }
        return result
    }

    /// Pure `<head>` parse: `og:title` beats `<title>` (publishers keep the
    /// clean headline in Open Graph and append " | Site" to the tag), and
    /// `og:site_name` names the publisher. Unit-tested via
    /// `PageMetadataFetcherTests`.
    public static func metadata(inHTML html: String) -> PageMetadata {
        guard let document = try? SwiftSoup.parse(html) else { return PageMetadata() }
        let title = firstNonEmpty([
            metaContent(document, property: "og:title"),
            metaContent(document, property: "twitter:title"),
            try? document.title(),
        ])
        let siteName = firstNonEmpty([
            metaContent(document, property: "og:site_name"),
            metaContent(document, property: "application-name"),
        ])
        return PageMetadata(title: title.map(cleaned), siteName: siteName.map(cleaned))
    }

    /// `https://<host>/` for `url` — the homepage the fallback read targets.
    public static func origin(of url: URL) -> URL? {
        guard let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        return components.url
    }

    // MARK: - Private

    /// Reads `<meta property=…>` and `<meta name=…>` — publishers use both
    /// spellings for the same Open Graph key.
    private static func metaContent(_ document: Document, property: String) -> String? {
        for selector in ["meta[property=\(property)]", "meta[name=\(property)]"] {
            if let element = try? document.select(selector).first(),
               let content = try? element.attr("content"),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ candidates: [String?]) -> String? {
        candidates.compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Collapses whitespace and drops HTML-entity noise so a headline reads as
    /// one line in a card.
    private static func cleaned(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
