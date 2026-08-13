//
//  ListingPage.swift
//  LunaHTMLClassification
//

import Foundation
import SwiftSoup

/// The Swift twin of the Safari extension's index veto. It answers one
/// question: is this page a LISTING rather than a single piece of content?
/// A Google search page or a publisher front page gets no Luna pill in Safari
/// (`looksLikeNonArticleIndex` in `LunaSafari/Resources/content.js`), and for
/// the same reason must not become an `.article` here when `Classifier`'s URL
/// table misses and hands the page to article extraction.
///
/// The signals are deliberately the SAME ones the extension uses, so the two
/// sides agree: `SafariIndexVetoParityTests` runs one fixture set through this
/// type and through the production `content.js` in a bare `WKWebView`, and
/// fails if they disagree.
///
/// Pure — no I/O, no UIKit — so it's usable from every extension target.
public enum ListingPage {

    // MARK: - The verdict

    /// Whether `url`/`html` is an index, search-results, or front page rather than
    /// a single readable item.
    ///
    /// Deliberately conservative, because a false positive silently drops a real
    /// save (and the "too aggressive" failure mode is invisible — the user just
    /// never sees the page again):
    ///
    /// 1. A **search-results URL** is decided on the URL alone, so a directly
    ///    shared search page fails before any network round-trip.
    /// 2. With no HTML we say nothing. A page we could not fetch keeps every
    ///    recovery route it has today (bot-block → browser tier → archive).
    /// 3. A page that **declares itself an article** is exempt from every
    ///    structural signal below — the same host-independent exemption
    ///    `content.js` applies, and for the same reason: a related-story card rail
    ///    and a link-dense metered body are routine on real articles.
    public static func isNonContentPage(url: URL, html: String?) -> Bool {
        if isSearchResultsURL(url) { return true }
        guard let html, let document = try? SwiftSoup.parse(html, url.absoluteString) else {
            return false
        }
        if declaresArticle(document: document) { return false }
        if hasStructuralListingShape(document: document) { return true }
        let headlines = headlineLinkCount(document: document)
        if declaresListingPage(document: document), headlines >= minimumHeadlineLinks {
            return true
        }
        // A bare site root that is mostly a grid of story links is a front page.
        // `content.js` gets this for free (a publisher front usually declares
        // `CollectionPage`/`landing_homepage`); a plain blog or shop index often
        // declares nothing at all, and the URL is the missing half of the evidence.
        return isSiteRoot(url) && headlines >= minimumHeadlineLinks
    }

    /// The `String`-HTML convenience used by call sites that never parsed the page.
    public static func isNonContentPage(url: URL, html: String) -> Bool {
        isNonContentPage(url: url, html: Optional(html))
    }

    // MARK: - URL shapes

    /// Path segments that name a search-results page when they lead the path.
    /// Kept tiny on purpose: `ProductPageRules.listingFirstPathSegments` is the
    /// right list for COMMERCE (it includes `s`, `b`, `deals`, `stores`), but
    /// applying it to every page would veto real articles — `medium.com/s/<slug>`
    /// is a publication, not a search.
    static let searchPathSegments: Set<String> = ["search", "results"]

    /// Query parameter names that carry a search term.
    static let searchQueryNames: Set<String> = [
        "q", "query", "search", "searchterm", "search_query", "keyword", "keywords",
    ]

    /// Whether `url` is a search-results page, from the URL alone.
    ///
    /// Two shapes, which between them cover every engine and on-site search we
    /// need without a host list: a leading `search`/`results` path segment
    /// (`google.com/search?q=`, `bing.com/search?q=`, `<site>/search/foo`), or a
    /// search term hung off the site root (`duckduckgo.com/?q=`).
    public static func isSearchResultsURL(_ url: URL) -> Bool {
        let segments = pathSegments(url)
        for segment in segments.prefix(2) where searchPathSegments.contains(segment) {
            return true
        }
        guard segments.isEmpty else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.contains {
            searchQueryNames.contains($0.name.lowercased())
                && !($0.value ?? "").isEmpty
        }
    }

    /// The bare root of a site — no path and no query. (A root carrying a query is
    /// usually a search or a filtered view, handled above.)
    public static func isSiteRoot(_ url: URL) -> Bool {
        guard pathSegments(url).isEmpty else { return false }
        return (url.query ?? "").isEmpty
    }

    private static func pathSegments(_ url: URL) -> [String] {
        url.path.split(separator: "/").map { $0.lowercased() }
    }

    // MARK: - HTML shapes (the content.js mirror)

    /// A page carrying five of these is showing a grid of stories, not one story.
    static let minimumHeadlineLinks = 5

    /// Explicit "this is an article" markup: `og:type=article`, or an
    /// `Article`/`NewsArticle`/`BlogPosting` JSON-LD node. Mirrors
    /// `content.js`'s `pageDeclaresArticle`.
    static func declaresArticle(html: String, baseURL: URL? = nil) -> Bool {
        guard let document = parse(html, baseURL) else { return false }
        return declaresArticle(document: document)
    }

    static func declaresArticle(document: Document) -> Bool {
        if let ogType = openGraphType(document),
           ogType.range(of: "article", options: .caseInsensitive) != nil {
            return true
        }
        return jsonLD(document).contains {
            $0.range(
                of: #""@type"\s*:\s*(\[[^\]]*)?"(news|blog)?(article|posting)""#,
                options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The two purely STRUCTURAL listing shapes — a cluster of sibling `<article>`
    /// elements, and a page that is mostly link text. Neither means anything on a
    /// page that declares itself an article (see `isNonContentPage`), so the
    /// exemption lives here rather than at each call site, exactly as it does in
    /// `content.js`'s shared `hasStructuralListingShape`.
    public static func hasStructuralListingShape(html: String, baseURL: URL? = nil) -> Bool {
        guard let document = parse(html, baseURL) else { return false }
        return hasStructuralListingShape(document: document)
    }

    static func hasStructuralListingShape(document: Document) -> Bool {
        if declaresArticle(document: document) { return false }
        let articles = (try? document.select("article").count) ?? 0
        if articles >= 4 { return true }
        return wholePageLinkDensity(document) > 0.5
    }

    /// The page's own metadata says it is a landing / collection / search / site
    /// index. A generic `WebPage` declaration is deliberately NOT enough — plenty
    /// of real articles carry one.
    public static func declaresListingPage(html: String, baseURL: URL? = nil) -> Bool {
        guard let document = parse(html, baseURL) else { return false }
        return declaresListingPage(document: document)
    }

    static func declaresListingPage(document: Document) -> Bool {
        let combined = jsonLD(document).joined(separator: " ").lowercased()
        if combined.range(
            of: #"landing[ _-]?(home)?page|front[ _-]?page"#,
            options: .regularExpression) != nil {
            return true
        }
        return combined.range(
            of: #""@type"\s*:\s*(\[[^\]]*)?"(collectionpage|searchresultspage|itemlist|website)""#,
            options: .regularExpression) != nil
    }

    /// Distinct, substantial destination links outside site chrome. A story grid
    /// has many; an article's related-story rail does not reach five on its own,
    /// which is why this is only ever combined with another signal.
    ///
    /// Counting stops at `minimumHeadlineLinks` — nothing downstream needs more.
    public static func headlineLinkCount(html: String, baseURL: URL? = nil) -> Int {
        guard let document = parse(html, baseURL) else { return 0 }
        return headlineLinkCount(document: document)
    }

    static func headlineLinkCount(document: Document) -> Int {
        guard let links = try? document.select("a[href]") else { return 0 }
        var destinations: Set<String> = []
        for link in links {
            if headlineLinkIsChrome(link) { continue }
            let text = (try? link.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 25 { continue }
            let href = ((try? link.attr("href")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty || href.hasPrefix("#") { continue }
            if href.range(
                of: "^(javascript:|mailto:|tel:)",
                options: [.regularExpression, .caseInsensitive]) != nil { continue }
            destinations.insert(href)
            if destinations.count >= minimumHeadlineLinks { return destinations.count }
        }
        return destinations.count
    }

    /// Story cards are counted deliberately, so this cannot reuse the extractor's
    /// "unlikely container" test (which quite correctly rejects `.card` for PROSE).
    /// Only real site chrome is excluded.
    private static func headlineLinkIsChrome(_ node: Element) -> Bool {
        var current: Element? = node
        var depth = 0
        while let element = current, depth <= 5 {
            let tag = element.tagName().lowercased()
            if tag == "nav" || tag == "header" || tag == "footer" || tag == "body" {
                return tag != "body"
            }
            let className = (try? element.attr("class")) ?? ""
            let combined = "\(className) \((try? element.attr("id")) ?? "")"
            if combined.range(
                of: "(nav|menu|footer|header|breadcrumb|pagination|cookie|account|social|share)",
                options: [.regularExpression, .caseInsensitive]) != nil,
               combined.range(
                of: "(article|body|content|main|story|post|entry)",
                options: [.regularExpression, .caseInsensitive]) == nil {
                return true
            }
            current = element.parent()
            depth += 1
        }
        return false
    }

    /// Sum of `<a>` text divided by the body's own text — above 0.5 the page is
    /// mostly navigation.
    private static func wholePageLinkDensity(_ document: Document) -> Double {
        guard let body = document.body(),
              let totalText = try? body.text(), !totalText.isEmpty,
              let anchors = try? body.select("a") else { return 0 }
        let linkText = anchors.reduce(0) { $0 + (((try? $1.text()) ?? "").count) }
        return Double(linkText) / Double(totalText.count)
    }

    // MARK: - Parsing helpers

    private static func parse(_ html: String, _ baseURL: URL?) -> Document? {
        try? SwiftSoup.parse(html, baseURL?.absoluteString ?? "")
    }

    private static func openGraphType(_ document: Document) -> String? {
        guard let meta = try? document.select("meta[property=og:type]").first() else { return nil }
        return try? meta.attr("content")
    }

    /// The raw text of every JSON-LD script, matched with the SAME regexes
    /// `content.js` uses rather than being decoded into objects — the two sides
    /// have to agree, and a shape one parser tolerates and the other rejects
    /// would be a silent divergence.
    private static func jsonLD(_ document: Document) -> [String] {
        guard let scripts = try? document.select("script[type=application/ld+json]") else {
            return []
        }
        return scripts.map { $0.data() }
    }
}
