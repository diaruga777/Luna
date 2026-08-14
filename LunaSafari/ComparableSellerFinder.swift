//
//  ComparableSellerFinder.swift
//  LunaSafari
//

import Foundation
import LunaAppConfig
import LunaModels
import os
import LunaPriceCompare
import LunaStorage
import LunaURLClassification

/// Answers "is this product cheaper somewhere else, right now?" for the product
/// page the content script just extracted.
///
/// Two legs run in this order:
///
/// 1. **What Luna already knows.** The app-written price-history index and the
///    passive snapshot tables already sit in the App Group database, and
///    `ProductPageMatching`'s tiers say which entries match this page. A price
///    another retailer was seen at in the last 24h is a real answer, and it
///    costs no network at all.
/// 2. **A constrained fan-out**, run only when leg 1 finds nothing. `SellerFanOut`
///    runs with `.constrained` — six candidate retailers, three results, no
///    web-search layer, no name-only matches — over a bare `URLSession`,
///    because the appex cannot link `LunaFetch` (see `claudedocs
///    /safari-extension.md`'s size ceiling) and does not need to: the engine
///    takes its fetching injected precisely so this environment can supply it.
///
/// Whatever leg 2 fetches is written into the snapshot store on the way out, so
/// a price found for a pill also feeds everything snapshots already feed.
///
/// The answer is always the LOWEST price that beats the page, never a list. A
/// pill is one line on someone else's shopping page: if it cannot be reduced to
/// "£X at <shop>", it does not belong there.
enum ComparableSellerFinder {

    /// What the page is told. Nil answers are the common case and are not
    /// failures — the page falls back to today's history-pill rules.
    struct Answer {
        var price: Decimal
        var currency: String
        var sellerName: String
        var urlString: String
    }

    /// Wall clock for the whole lookup. It sits inside the appex's own 20s
    /// notion (`SafariWebExtensionHandler.resolveTimeout`), so the finder gives
    /// up before the handler must, and the page's promise settles with a real
    /// answer rather than a timeout. The fan-out's `.constrained` budget (15s)
    /// is the inner one; the margin covers container reads and the snapshot
    /// write-back.
    static let budget: TimeInterval = 18

    private static let log = Logger(
        subsystem: LunaLogging.subsystem, category: "SellerComparison")

    // MARK: - Entry point

    static func answer(
        forPageSnapshot page: ProductSnapshot, now: Date = Date()
    ) async -> Answer? {
        guard let pagePrice = Decimal(string: page.price), pagePrice > 0 else { return nil }

        if let cached = cachedAnswer(forPageSnapshot: page, pagePrice: pagePrice, now: now) {
            return cached
        }
        return await withinBudget {
            await liveAnswer(forPageSnapshot: page, pagePrice: pagePrice, now: now)
        }
    }

    /// The answer as the page's message payload. Serialization lives here and
    /// not in `SafariWebExtensionHandler`, which stays an adapter.
    static func messagePayload(for answer: Answer?) -> [String: Any] {
        guard let answer else { return ["found": false] }
        return [
            "found": true,
            "price": NSDecimalNumber(decimal: answer.price).stringValue,
            "currency": answer.currency,
            "sellerName": answer.sellerName,
            "url": answer.urlString,
        ]
    }

    // MARK: - Leg 1: what is already stored

    /// Every price Luna already holds for this product, from both files,
    /// filtered by `FreshComparablePrices`' one rule.
    static func cachedAnswer(
        forPageSnapshot page: ProductSnapshot, pagePrice: Decimal, now: Date
    ) -> Answer? {
        var points = indexPoints(matching: page)
        points.append(contentsOf: snapshotPoints(matching: page))
        return FreshComparablePrices.lowestCheaper(
            among: points, pagePrice: pagePrice, pageCurrency: page.currency,
            pageDomain: ProductIdentityMatching.registrableDomain(page.host), now: now)
            .map(answer(from:))
    }

    /// Points from the user's own price trackers, read straight out of the saves
    /// database — this appex links `LunaStorage` and holds the App Group
    /// entitlement, so there is no index file between it and the rows.
    ///
    /// A tracked point records a DAY, not an instant, so its honest timestamp is
    /// that day's UTC start. That makes `isFresh` mean exactly "recorded today":
    /// today's start is always less than 24h ago, and yesterday's never is.
    private static func indexPoints(
        matching page: ProductSnapshot
    ) -> [ComparablePricePoint] {
        var points: [ComparablePricePoint] = []
        let tracked = SavesStore.shared.activePriceTrackers()
            .map { PriceHistoryIndexEntry(tracker: $0) }
        for entry in tracked
        where ProductPageMatching.matches(page: page, indexEntry: entry) {
            for store in entry.stores {
                for point in store.points {
                    guard let amount = Decimal(string: point.price),
                          let day = point.day.startOfDayUTC else { continue }
                    points.append(ComparablePricePoint(
                        sellerName: sellerName(forHost: store.host),
                        domain: ProductIdentityMatching.registrableDomain(store.host),
                        urlString: store.url, price: amount, currency: point.currency,
                        capturedAt: day))
                }
            }
        }
        return points
    }

    /// Points from passive snapshots of OTHER pages — including ones this
    /// finder itself wrote on an earlier visit, which is what makes a second
    /// lookup for the same product free.
    private static func snapshotPoints(
        matching page: ProductSnapshot
    ) -> [ComparablePricePoint] {
        ProductSnapshotStore.shared
            .snapshots(forKeys: page.indexKeys)
            .filter { $0.url != page.url && ProductPageMatching.matches(page: page, snapshot: $0) }
            .compactMap { snapshot in
                guard let amount = Decimal(string: snapshot.price) else { return nil }
                let captured = instant(snapshot.capturedAt)
                    ?? snapshot.day.startOfDayUTC
                    ?? Date(timeIntervalSince1970: 0)
                return ComparablePricePoint(
                    sellerName: sellerName(forHost: snapshot.host),
                    domain: ProductIdentityMatching.registrableDomain(snapshot.host),
                    urlString: snapshot.url, price: amount, currency: snapshot.currency,
                    capturedAt: captured)
            }
    }

    // MARK: - Leg 2: the constrained fan-out

    private static func liveAnswer(
        forPageSnapshot page: ProductSnapshot, pagePrice: Decimal, now: Date
    ) async -> Answer? {
        let identifiers = ProductIdentifiers(
            gtin: page.gtin, mpn: page.mpn,
            // `content.js` writes an Amazon ASIN as SKU. Keep the fallback for
            // snapshots written by an older extension build, which only put it
            // in `retailerItemID`.
            sku: page.sku ?? page.retailerItemID, brand: page.brand)
        // A global id is strongest. A retailer-scoped SKU/ASIN still proves the
        // source is one concrete product and earns a name-verified search; a
        // brand alone does not.
        guard identifiers.hasCrossHostIdentifier || identifiers.normalizedSKU != nil,
              let sourceURL = URL(string: page.url),
              let directory
        else { return nil }

        let profile = SellerFanOutProfile.constrained
        let outcome = await SellerFanOut(
            directory: directory,
            profile: profile,
            networking: URLSessionSellerNetworking(timeout: profile.perFetchTimeout)
        ).run(SellerFanOutRequest(
            sourceURL: sourceURL, productName: page.name, identifiers: identifiers,
            // The market is the page's own: its currency picks the storefronts
            // when the host is unknown, and the engine refuses any result
            // priced in anything else (`FreshComparablePrices` then re-refuses
            // on the way to the pill — the same rule at both ends).
            sourceCurrency: page.currency))

        // One line. The app writes the whole per-candidate story to its
        // shareable diagnostic log (`SellerComparisonRunner.logCategory`); an
        // appex with a hard memory ceiling and a 20s budget gets only the
        // summary — still the difference between "the pill never appears" and
        // a reason why.
        log.info("\(outcome.compactLogLine, privacy: .public)")

        for result in outcome.results {
            ProductSnapshotStore.shared.record(payload: result.snapshotPayload, now: now)
        }
        return FreshComparablePrices.lowestCheaper(
            among: outcome.results.map { $0.pricePoint(now: now) },
            pagePrice: pagePrice, pageCurrency: page.currency,
            pageDomain: ProductIdentityMatching.registrableDomain(page.host), now: now)
            .map(answer(from:))
    }

    // MARK: - Shared

    /// Races `work` against the finder's own wall clock. A lookup that overruns
    /// answers nothing rather than leaving the page's `sendMessage` promise —
    /// and the spinner pill with it — hanging.
    /// Both branches answer `Answer?`, and nil means the same thing in both: no
    /// alternative seller. Whichever finishes first is simply the answer.
    private static func withinBudget(_ work: @escaping @Sendable () async -> Answer?) async -> Answer? {
        await TimeLimit.run(budget, operation: work) ?? nil
    }

    private static func answer(from point: ComparablePricePoint) -> Answer {
        Answer(
            price: point.price, currency: point.currency,
            sellerName: point.sellerName, urlString: point.urlString)
    }

    /// The retailer's name from the bundled directory when it knows the host,
    /// else the registrable domain — never a bare subdomain, which reads as a
    /// typo on a pill.
    private static func sellerName(forHost host: String) -> String {
        directory?.seller(forHost: host)?.name ?? ProductIdentityMatching.registrableDomain(host)
    }

    /// Decoded once: 218 sellers out of the bundled JSON is not work to repeat
    /// per stored price point.
    private static let directory: SellerDirectory? = try? SellerDirectory.bundled()

    private static func instant(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }
}

/// The appex's whole networking answer: a plain ephemeral `URLSession` carrying
/// the same mobile-Safari User-Agent every other Luna fetch uses
/// (`WebFetchConstants`, which lives low enough for this target to link). The
/// response is capped at the same byte ceiling, so a mis-served large file
/// cannot push a memory-limited appex into jetsam.
///
/// It declares no optional layers: no web search, no ingest pipeline, and no
/// WebKit render tier. That is exactly the trade `PipelineSellerNetworking`
/// sits at the other end of.
struct URLSessionSellerNetworking: SellerFanOutNetworking {
    let availableLayers: SellerFanOutLayers = []

    private let session: URLSession

    /// `timeout` is the profile's per-fetch allowance, honoured by the session
    /// itself — the engine checks its own budget only between candidates.
    init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = [
            "User-Agent": WebFetchConstants.safariUserAgent,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        session = URLSession(configuration: configuration)
    }

    func fetch(_ url: URL) async -> FetchedPage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse
        else { return nil }
        let capped = data.count > WebFetchConstants.maxBytes
            ? data.prefix(WebFetchConstants.maxBytes)
            : data[...]
        return FetchedPage(
            url: http.url ?? url,
            html: String(decoding: capped, as: UTF8.self),
            statusCode: http.statusCode)
    }
}
