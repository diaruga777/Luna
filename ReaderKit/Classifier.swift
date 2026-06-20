//
//  Classifier.swift
//  ReaderKit
//

import Foundation
import SwiftSoup

/// THE content classifier — pure, dependency-free of UIKit/network, living in
/// ReaderKit so the main app AND every extension classify a URL identically from
/// one source of truth. Determination only: it returns WHAT a URL is and never
/// fetches, prices, bypasses, or renders.
///
/// Two phases, in strict order:
/// 1. **Deterministic `[KnownSite]` table FIRST** (URL-only, no HTML). Platform /
///    video / audio rows are checked before shops and news, so a recognized
///    platform URL can never fall through to article/product handling.
/// 2. **HTML heuristics**, run ONLY when the table is `.undetermined` — reusing the
///    logic of `ProductPageDetector` / `PaywallDetector` / `ArticleContent`'s
///    readable check, as pure functions.
enum Classifier {

    /// Classifies `url`. An explicit `documentType` (a save-time flag) always wins.
    /// With `html == nil` only the deterministic table runs (URL-only classification
    /// for a first-glance routing before any fetch); a table miss returns
    /// `.undetermined`. With `html` present, a table miss falls through to the HTML
    /// heuristic phase.
    static func classify(url: URL, html: String? = nil, documentType: String? = nil) -> ContentKind {
        if let documentType, !documentType.isEmpty { return .document(type: documentType) }
        if let hit = knownSites.first(where: { $0.matches(url) }) {
            return hit.kind(url)
        }
        guard let html else { return .undetermined }
        return heuristicKind(url: url, html: html)
    }

    /// The extensible deterministic table. APPEND a row to teach the classifier a
    /// new site. Ordered most-specific first: platform/video/audio (so a platform
    /// URL is recognized before anything else), then shops, then news — so overlaps
    /// resolve deterministically.
    static let knownSites: [KnownSite] = platformSites + shopSites + newsSites

    // MARK: - Phase 1a: platform / video / social / audio rows

    /// The platform rows: a single row that defers to `PlatformRecognizer` (the one
    /// place URL→platform rules live), mapping its `RecognizedPlatform` to the
    /// matching `ContentKind` branch. Recognition is FIRST so a video/social/audio
    /// URL is never text-extracted or treated as a product.
    static let platformSites: [KnownSite] = [
        KnownSite(
            hosts: platformHosts,
            path: nil,
            kind: { url in
                guard let recognized = PlatformRecognizer.recognize(url.absoluteString) else {
                    // A platform host with no recognizable item (a channel/profile
                    // page) isn't a video/post — defer to heuristics/article.
                    return .undetermined
                }
                return contentKind(for: recognized)
            }),
    ]

    /// Maps a recognized platform to the `ContentKind` branch for its category.
    static func contentKind(for recognized: RecognizedPlatform) -> ContentKind {
        switch recognized.kind {
        case .video: return .video(recognized.platform, itemID: recognized.itemID)
        case .social: return .social(recognized.platform, itemID: recognized.itemID)
        case .audio: return .audio(recognized.platform, recognized.service, itemID: recognized.itemID)
        }
    }

    /// Every host any `PlatformRule` covers — the gate for the single platform row
    /// (so the row only `matches` when a platform host is involved; the closure then
    /// asks the recognizer for the precise platform + id). Derived from the rule
    /// table so adding a platform rule extends this automatically.
    static let platformHosts: [String] = Array(Set(PlatformRecognizer.rules.flatMap { $0.hosts })).sorted()

    // MARK: - Phase 1b: shop rows

    /// Known shops → `.product(.knownShopHost)`. A deterministic hit lets real shops
    /// skip the fuzzy heuristic scorer entirely (fewer false positives). APPEND here.
    static let shopSites: [KnownSite] = [
        // Amazon — every storefront TLD (amazon.com / .co.uk / .com.au / .de / …).
        KnownSite(hosts: ["amazon.com", "amazon.co.uk", "amazon.com.au", "amazon.ca",
                          "amazon.de", "amazon.fr", "amazon.it", "amazon.es",
                          "amazon.co.jp", "amazon.in", "amazon.com.br", "amazon.com.mx",
                          "amazon.nl", "amazon.se", "amazon.sg", "amzn.to", "amzn.com"],
                  kind: { _ in .product(.knownShopHost) }),
        // General-merchandise retailers.
        KnownSite(hosts: ["target.com", "walmart.com", "bestbuy.com", "ebay.com", "ebay.co.uk",
                          "ebay.com.au", "ebay.de", "etsy.com", "wayfair.com", "homedepot.com",
                          "lowes.com", "costco.com", "ikea.com", "newegg.com", "aliexpress.com",
                          "alibaba.com", "temu.com", "shein.com", "wish.com", "overstock.com",
                          "macys.com", "nordstrom.com", "kohls.com", "argos.co.uk",
                          "currys.co.uk", "johnlewis.com", "bunnings.com.au", "kmart.com.au",
                          "bigw.com.au", "jbhifi.com.au", "harveynorman.com.au", "thegoodguys.com.au",
                          "rei.com", "chewy.com", "zappos.com", "wickes.co.uk"],
                  kind: { _ in .product(.knownShopHost) }),
    ]

    // MARK: - Phase 1c: news rows

    /// Hard-paywall news hosts → `.paywalledArticle(hardHost: true)` (only the
    /// archive-CAPTCHA route can read them). Folds in `ArticleFetcher.hardPaywallHosts`
    /// plus named international peers. APPEND here.
    static let hardPaywallNewsSites = KnownSite(
        hosts: ["wsj.com", "ft.com", "nytimes.com", "economist.com", "bloomberg.com",
                "washingtonpost.com", "newyorker.com", "theatlantic.com", "wired.com",
                "barrons.com", "businessinsider.com", "theinformation.com", "hbr.org",
                "foreignpolicy.com", "foreignaffairs.com", "thetimes.co.uk", "telegraph.co.uk",
                "nikkei.com", "seekingalpha.com", "latimes.com", "bostonglobe.com",
                "smh.com.au", "theage.com.au", "afr.com", "theaustralian.com.au",
                "wsj.com.au", "thetimes.com"],
        kind: { _ in .paywalledArticle(hardHost: true) })

    /// Free-news hosts → `.article` (fast-path: skip the heuristic phase for a host
    /// we already know is a readable article site). APPEND here.
    static let freeNewsSites = KnownSite(
        hosts: ["theguardian.com", "bbc.com", "bbc.co.uk", "reuters.com", "apnews.com",
                "npr.org", "cnn.com", "nbcnews.com", "abcnews.go.com", "cbsnews.com",
                "abc.net.au", "news.com.au", "9news.com.au", "aljazeera.com",
                "techcrunch.com", "theverge.com", "arstechnica.com", "engadget.com",
                "wikipedia.org"],
        kind: { _ in .article })

    static let newsSites: [KnownSite] = [hardPaywallNewsSites, freeNewsSites]

    // MARK: - Phase 2: HTML heuristics (table-miss only)

    /// The heuristic phase, run only when the deterministic table is undetermined.
    /// Order mirrors the table: product (structured/strong-heuristic) → paywall →
    /// readable article → undetermined. Reuses the existing pure detectors.
    static func heuristicKind(url: URL, html: String) -> ContentKind {
        if let signal = productSignal(url: url, html: html) { return .product(signal) }
        if PaywallDetector.htmlDeclaresLocked(html) { return .paywalledArticle(hardHost: false) }
        if let document = try? SwiftSoup.parse(html, url.absoluteString),
           let bodyText = try? document.body()?.text(),
           PaywallDetector.textLooksPaywalled(bodyText, bodyLength: bodyText.count) {
            return .paywalledArticle(hardHost: false)
        }
        return .undetermined
    }

    /// The TIGHTENED product heuristic (regression guard for the documented
    /// false-positive: a news article with a stray "addToCart" must NOT become a
    /// product). A page is a product ONLY with a real structured product/price
    /// signal — never on a bare affordance/rating substring:
    /// - a structured-data candidate (JSON-LD / OG / microdata price), OR
    /// - a Tier-2 candidate that carries an actual recovered price (`staticPrice`)
    ///   or declares `og:type == product`.
    static func productSignal(url: URL, html: String) -> ProductSignal? {
        let detector = ProductPageDetector()
        guard let document = try? SwiftSoup.parse(html, url.absoluteString) else { return nil }
        let baseURL = URL(string: url.absoluteString)

        // Tier 1: structured price markup is unambiguous.
        if detector.hasStructuredProductData(document: document, baseURL: baseURL) {
            return .structuredData
        }

        // Tier 2: a heuristic candidate counts ONLY with a hard product signal —
        // a recovered price or an explicit product OG type — not a stray affordance.
        let (score, embeddedPrice) = detector.heuristicProductScore(document: document, baseURL: baseURL)
        guard score >= ProductPageDetector.minimumHeuristicScore else { return nil }
        let ogType = (try? document.select("meta[property=og:type]").first()?.attr("content"))??
            .lowercased()
        let declaresProductType = ogType == "product" || ogType == "product.item"
        guard embeddedPrice != nil || declaresProductType else { return nil }
        return .heuristicScore(score)
    }
}
