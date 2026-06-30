//
//  Classifier.swift
//  ReaderKit
//

import LuneURLClassification
import LuneModels
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
public enum Classifier {

    /// Classifies `url`. An explicit `documentType` (a save-time flag) always wins.
    /// With `html == nil` only the deterministic table runs (URL-only classification
    /// for a first-glance routing before any fetch); a table miss returns
    /// `.undetermined`. With `html` present, a table miss falls through to the HTML
    /// heuristic phase.
    public static func classify(url: URL, html: String? = nil, documentType: String? = nil) -> ContentKind {
        if let documentType, !documentType.isEmpty { return .document(type: documentType) }
        // Google Shopping pages are distinguished by query params (`ibp=oshop`,
        // `prds`, `tbm=shop`, …), which the host+path `KnownSite` table can't express.
        // Route them straight to product extraction — deterministically, before the
        // table and the HTML heuristics — so a saved shopping page (e.g. a resolved
        // `share.google` product link) becomes a price tracker, never an article.
        if GoogleShoppingURL.isProductPage(url) { return .product(.knownShopHost) }
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
    public static let knownSites: [KnownSite] = platformSites + shopSites + newsSites

    // MARK: - Phase 1a: platform / video / social / audio rows

    /// The platform rows: a single row that defers to `PlatformRecognizer` (the one
    /// place URL→platform rules live), mapping its `RecognizedPlatform` to the
    /// matching `ContentKind` branch. Recognition is FIRST so a video/social/audio
    /// URL is never text-extracted or treated as a product.
    public static let platformSites: [KnownSite] = [
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
    public static func contentKind(for recognized: RecognizedPlatform) -> ContentKind {
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
    public static let platformHosts: [String] = Array(Set(PlatformRecognizer.rules.flatMap { $0.hosts })).sorted()

    // MARK: - Phase 1b: shop rows

    /// Known shops → `.product(.knownShopHost)`. A deterministic hit lets real shops
    /// skip the fuzzy heuristic scorer entirely (fewer false positives). APPEND here.
    public static let shopSites: [KnownSite] = [
        // Amazon — every regional storefront. Amazon share domains are unwrapped
        // before classification, so they never bypass the storefront price rules.
        KnownSite(hosts: AmazonPriceRule.storefrontHosts,
                  kind: { _ in .product(.knownShopHost) }),
        // General-merchandise retailers (international list in `ShoppingSites`).
        KnownSite(hosts: ShoppingSites.retailers,
                  kind: { _ in .product(.knownShopHost) }),
    ]

    // MARK: - Phase 1c: news rows

    /// Hard-paywall news hosts → `.paywalledArticle(hardHost: true)` (only the
    /// archive-CAPTCHA route can read them). The worldwide list lives in
    /// `NewsSites.hardPaywall`.
    public static let hardPaywallNewsSites = KnownSite(
        hosts: NewsSites.hardPaywall,
        kind: { _ in .paywalledArticle(hardHost: true) })

    /// Free-news hosts → `.article` (fast-path: skip the heuristic phase for a host
    /// we already know is a readable article site). The worldwide list lives in
    /// `NewsSites.free`.
    public static let freeNewsSites = KnownSite(
        hosts: NewsSites.free,
        kind: { _ in .article })

    public static let newsSites: [KnownSite] = [hardPaywallNewsSites, freeNewsSites]

    /// Whether `url` is a known hard-paywall news host — the SINGLE determination
    /// source shared by classification (`.paywalledArticle(hardHost: true)`) and the
    /// "unreadable → park for the archive reader" routing in `IngestPipeline` /
    /// `ArticleFetcher.isHardPaywallHost`. Derives straight from
    /// `hardPaywallNewsSites`, so the two can never drift apart.
    public static func isHardPaywallHost(_ url: URL) -> Bool {
        hardPaywallNewsSites.matches(url)
    }

    // MARK: - Phase 2: HTML heuristics (table-miss only)

    /// The heuristic phase, run only when the deterministic table is undetermined.
    /// Order mirrors the table: product (structured/strong-heuristic) → paywall →
    /// readable article → undetermined. Reuses the existing pure detectors.
    public static func heuristicKind(url: URL, html: String) -> ContentKind {
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
    public static func productSignal(url: URL, html: String) -> ProductSignal? {
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
