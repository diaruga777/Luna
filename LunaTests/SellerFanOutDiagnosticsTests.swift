//
//  SellerFanOutDiagnosticsTests.swift
//  LunaTests
//

import LunaModels
import LunaPriceCompare
import XCTest

/// A failing fan-out used to be invisible: twelve candidates, zero results, and
/// nothing in the diagnostic log to say which retailer refused, which served a
/// shell, and which was simply the wrong product. These pin the per-candidate
/// record that replaced the silence, and the two things that consume it — the
/// client-rendered skip and the injected render fallback.
final class SellerFanOutDiagnosticsTests: XCTestCase {

    // MARK: - Fixtures

    private final class StubFetcher: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String: FetchedPage] = [:]
        private(set) var requested: [String] = []

        func stub(_ urlString: String, html: String, statusCode: Int = 200) {
            lock.lock(); defer { lock.unlock() }
            pages[urlString] = FetchedPage(
                url: URL(string: urlString)!, html: html, statusCode: statusCode)
        }

        var fetch: SellerFanOut.Fetch {
            { [self] url in
                return lock.withLock {
                    requested.append(url.absoluteString)
                    return pages[url.absoluteString]
                }
            }
        }
    }

    private func seller(
        _ id: String, domain: String, tier: Int = 1, acceptsGTIN: Bool? = true,
        clientRendered: Bool? = nil
    ) -> Seller {
        Seller(
            id: id, name: id.capitalized, region: "US", domain: domain,
            searchURL: "https://\(domain)/search?q={query}", acceptsGTIN: acceptsGTIN,
            marketplace: false, categories: ["general"], tier: tier, verified: true,
            searchIsClientRendered: clientRendered)
    }

    private func productPage(name: String, gtin: String, price: String) -> String {
        """
        <script type="application/ld+json">{"@type":"Product","name":"\(name)",
        "gtin13":"\(gtin)","offers":{"price":"\(price)","priceCurrency":"USD"}}</script>
        """
    }

    private func request(gtin: String = "0194644090876") -> SellerFanOutRequest {
        SellerFanOutRequest(
            sourceURL: URL(string: "https://source.example/p/1")!,
            productName: "Sony WH-1000XM5",
            identifiers: ProductIdentifiers(gtin: gtin, brand: "Sony"))
    }

    private var profile: SellerFanOutProfile {
        SellerFanOutProfile(
            candidateLimit: 4, resultTarget: 4, concurrency: 1, productURLsPerCandidate: 2,
            totalBudget: 60, perFetchTimeout: 5,
            allowsNameOnlyMatch: false, usesWebSearchLayer: false,
            skipsClientRenderedSearch: false, renderedSearchLimit: 2)
    }

    // MARK: - Per-candidate reasons

    func testEveryCandidateReportsWhyItProducedNothing() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://refuses.example/search?q=0194644090876", html: "", statusCode: 403)
        fetcher.stub("https://shell.example/search?q=0194644090876", html: "<html><body></body></html>")
        fetcher.stub("https://gone.example/search?q=0194644090876", html: "", statusCode: 404)
        // `stocks.example` is never stubbed: a transport failure.
        let directory = SellerDirectory(version: 1, sellers: [
            seller("refuses", domain: "refuses.example"),
            seller("shell", domain: "shell.example"),
            seller("gone", domain: "gone.example"),
            seller("stocks", domain: "stocks.example"),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())

        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(outcome.rejection(for: "refuses"), .searchBotWalled)
        XCTAssertEqual(outcome.rejection(for: "shell"), .noProductLinks)
        XCTAssertEqual(outcome.rejection(for: "gone"), .searchBadStatus)
        XCTAssertEqual(outcome.rejection(for: "stocks"), .searchUnreachable)
        XCTAssertEqual(outcome.attempts.count, 4)
        XCTAssertEqual(outcome.region, "US")
    }

    func testAnAcceptedCandidateRecordsItsConfidenceAndNoRejection() async throws {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://stocks.example/search?q=0194644090876",
            html: #"<a href="/products/xm5">XM5</a>"#)
        fetcher.stub(
            "https://stocks.example/products/xm5",
            html: productPage(name: "Sony WH-1000XM5", gtin: "0194644090876", price: "329.99"))
        let directory = SellerDirectory(
            version: 1, sellers: [seller("stocks", domain: "stocks.example")])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())

        let attempt = try XCTUnwrap(outcome.attempts.first)
        XCTAssertEqual(attempt.accepted, .gtin)
        XCTAssertNil(attempt.rejection)
        XCTAssertEqual(attempt.productLinks.count, 1)
        XCTAssertEqual(attempt.query, "0194644090876")
        XCTAssertGreaterThan(attempt.searchBytes, 0)
        XCTAssertTrue(attempt.logLine.contains("ACCEPTED"))
    }

    func testPricedButUnmatchedIsDistinguishedFromUnpriced() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://wrong.example/search?q=0194644090876",
            html: #"<a href="/products/other">Other</a>"#)
        fetcher.stub(
            "https://wrong.example/products/other",
            html: productPage(name: "Garden Hose", gtin: "0000000000001", price: "19.99"))
        fetcher.stub(
            "https://unpriced.example/search?q=0194644090876",
            html: #"<a href="/products/xm5">XM5</a>"#)
        fetcher.stub(
            "https://unpriced.example/products/xm5",
            html: "<meta property=\"og:title\" content=\"Sony WH-1000XM5\">")
        let directory = SellerDirectory(version: 1, sellers: [
            seller("wrong", domain: "wrong.example"),
            seller("unpriced", domain: "unpriced.example"),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())

        XCTAssertEqual(outcome.rejection(for: "wrong"), .noVerifiedMatch)
        XCTAssertEqual(outcome.rejection(for: "unpriced"), .noPriceOnAnyLink)
    }

    /// A diagnostics consumer must see each candidate as it finishes, not only
    /// at the end.
    func testAttemptsAreStreamedAsTheyFinish() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://a.example/search?q=0194644090876", html: "")
        fetcher.stub("https://b.example/search?q=0194644090876", html: "")
        let seen = Streamed()
        let directory = SellerDirectory(version: 1, sellers: [
            seller("a", domain: "a.example"), seller("b", domain: "b.example"),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch,
            onAttempt: { await seen.add($0.sellerID) })
            .run(request())

        let streamed = await seen.ids
        XCTAssertEqual(Set(streamed), Set(outcome.attempts.map(\.sellerID)))
    }

    func testTheRunSummaryNamesTheRegionResultsAndStopReason() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://a.example/search?q=0194644090876", html: "")
        let directory = SellerDirectory(
            version: 1, sellers: [seller("a", domain: "a.example")])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())

        XCTAssertTrue(outcome.logSummary.contains("region=US"))
        XCTAssertTrue(outcome.logSummary.contains("stop=exhausted"))
        XCTAssertTrue(outcome.logSummary.contains("a q=0194644090876"))
        XCTAssertTrue(outcome.compactLogLine.contains("asked=1"))
        XCTAssertTrue(outcome.compactLogLine.contains("found=0"))
    }

    private actor Streamed {
        private(set) var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }

    // MARK: - Client-rendered search

    /// A static-only context must not spend a candidate slot on a page that is
    /// structurally empty.
    func testAStaticOnlyProfileSkipsClientRenderedSellers() async {
        let fetcher = StubFetcher()
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shell", domain: "shell.example", clientRendered: true),
        ])
        var constrained = profile
        constrained = SellerFanOutProfile(
            candidateLimit: 4, resultTarget: 4, concurrency: 1, productURLsPerCandidate: 2,
            totalBudget: 60, perFetchTimeout: 5,
            allowsNameOnlyMatch: false, usesWebSearchLayer: false,
            skipsClientRenderedSearch: true, renderedSearchLimit: 0)
        let outcome = await SellerFanOut(
            directory: directory, profile: constrained, fetch: fetcher.fetch)
            .run(request())

        XCTAssertTrue(outcome.attempts.isEmpty, "it is not even a candidate")
        XCTAssertTrue(fetcher.requested.isEmpty, "and no budget was spent finding out")
    }

    func testTheFullProfileStillAsksAClientRenderedSeller() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://shell.example/search?q=0194644090876", html: "<html></html>")
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shell", domain: "shell.example", clientRendered: true),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())
        XCTAssertEqual(outcome.rejection(for: "shell"), .noProductLinks)
    }

    /// A directory entry written before the flag existed decodes as "not known
    /// to be client-rendered" rather than failing.
    func testDirectoryEntriesWithoutTheFlagStillDecode() throws {
        let json = """
        {"version":1,"sellers":[{"id":"a","name":"A","region":"US","domain":"a.example",
        "searchURL":"https://a.example/s?q={query}","acceptsGTIN":null,"marketplace":false,
        "categories":["general"],"tier":1,"verified":false}]}
        """
        let decoded = try SellerDirectory.decode(Data(json.utf8))
        XCTAssertEqual(decoded.sellers.first?.searchIsClientRendered, nil)
        XCTAssertFalse(try XCTUnwrap(decoded.sellers.first).searchRequiresRendering)
    }

    func testTheShippedDirectoryFlagsTheMeasuredShells() throws {
        let directory = try SellerDirectory.bundled()
        let flagged = Set(directory.sellers.filter(\.searchRequiresRendering).map(\.id))
        XCTAssertTrue(flagged.contains("target-us"))
        XCTAssertTrue(flagged.contains("walmart-us"))
        XCTAssertFalse(flagged.contains("amazon-us"))
        XCTAssertFalse(flagged.contains("barnesandnoble-us"))
    }

    func testEveryDirectoryRegionHasACurrency() throws {
        let directory = try SellerDirectory.bundled()
        for region in directory.regions {
            XCTAssertNotNil(
                SellerDirectory.currencies[region], "no currency for region \(region)")
        }
    }

    // MARK: - The render fallback

    func testAnEmptyStaticSearchIsRetriedThroughTheInjectedRenderer() async throws {
        let fetcher = StubFetcher()
        fetcher.stub("https://shell.example/search?q=0194644090876", html: "<html></html>")
        fetcher.stub(
            "https://shell.example/products/xm5",
            html: productPage(name: "Sony WH-1000XM5", gtin: "0194644090876", price: "329.99"))
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shell", domain: "shell.example", clientRendered: true),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch,
            renderSearch: { _ in #"<a href="/products/xm5">XM5</a>"# })
            .run(request())

        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertTrue(try XCTUnwrap(outcome.attempts.first).usedRenderedSearch)
    }

    func testTheRendererIsNotCalledWhenStaticMarkupAlreadyHasLinks() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://ok.example/search?q=0194644090876",
            html: #"<a href="/products/xm5">XM5</a>"#)
        fetcher.stub(
            "https://ok.example/products/xm5",
            html: productPage(name: "Sony WH-1000XM5", gtin: "0194644090876", price: "329.99"))
        let renders = Counter()
        let directory = SellerDirectory(
            version: 1, sellers: [seller("ok", domain: "ok.example")])
        _ = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch,
            renderSearch: { _ in await renders.bump(); return nil })
            .run(request())
        let count = await renders.value
        XCTAssertEqual(count, 0)
    }

    /// A render is an off-screen WebView and seconds of wall clock; the run may
    /// only afford so many.
    func testRendersAreCappedPerRun() async {
        let fetcher = StubFetcher()
        let sellers = (0..<5).map { seller("s\($0)", domain: "s\($0).example") }
        for candidate in sellers {
            fetcher.stub(
                "https://\(candidate.domain)/search?q=0194644090876", html: "<html></html>")
        }
        let renders = Counter()
        let wide = SellerFanOutProfile(
            candidateLimit: 5, resultTarget: 5, concurrency: 1, productURLsPerCandidate: 2,
            totalBudget: 60, perFetchTimeout: 5,
            allowsNameOnlyMatch: false, usesWebSearchLayer: false,
            skipsClientRenderedSearch: false, renderedSearchLimit: 2)
        _ = await SellerFanOut(
            directory: SellerDirectory(version: 1, sellers: sellers), profile: wide,
            fetch: fetcher.fetch,
            renderSearch: { _ in await renders.bump(); return nil })
            .run(request())
        let count = await renders.value
        XCTAssertEqual(count, 2, "the profile's render budget, not one per candidate")
    }

    /// No renderer injected (the appex, and every test that does not ask for
    /// one) means no render budget at all.
    func testNoInjectedRendererMeansNoRenderAttempt() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://shell.example/search?q=0194644090876", html: "<html></html>")
        let directory = SellerDirectory(
            version: 1, sellers: [seller("shell", domain: "shell.example")])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())
        XCTAssertFalse(outcome.attempts[0].usedRenderedSearch)
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: - The second question

    /// A shop whose barcode support is UNKNOWN is asked by identifier first and
    /// by name only if that found nothing — which is what lets the evidence
    /// tier apply to it at all.
    func testAnUnknownSellerIsAskedByIdentifierThenByName() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://shop.example/search?q=0194644090876", html: "<html></html>")
        fetcher.stub(
            "https://shop.example/search?q=Sony+WH-1000XM5",
            html: #"<a href="/products/xm5">XM5</a>"#)
        fetcher.stub(
            "https://shop.example/products/xm5",
            html: productPage(name: "Sony WH-1000XM5", gtin: "0194644090876", price: "329.99"))
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shop", domain: "shop.example", acceptsGTIN: nil),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())

        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(fetcher.requested.prefix(2), [
            "https://shop.example/search?q=0194644090876",
            "https://shop.example/search?q=Sony+WH-1000XM5",
        ])
    }

    /// A seller KNOWN to take barcodes is asked once: an empty answer means "not
    /// stocked", and a second request is how a bot wall gets tripped.
    func testASellerKnownToAcceptGTINsIsAskedOnlyOnce() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://shop.example/search?q=0194644090876", html: "<html></html>")
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shop", domain: "shop.example", acceptsGTIN: true),
        ])
        _ = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())
        XCTAssertEqual(fetcher.requested, ["https://shop.example/search?q=0194644090876"])
    }

    /// The evidence tier no longer needs the identifier question specifically
    /// — once the name already agrees (this candidate's own nesting inside
    /// `ComparisonMatching.verify`), a NAME query landing on a page that
    /// prints the barcode is exactly as good evidence as a GTIN query would
    /// have been. This is the Costco/JB-style gap the fix closed: a retailer
    /// whose search buries the exact product under a NAME query used to be
    /// refused for it.
    func testTheEvidenceTierIsNowAvailableOnTheNameFallbackToo() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://shop.example/search?q=0194644090876", html: "<html></html>")
        fetcher.stub(
            "https://shop.example/search?q=Sony+WH-1000XM5",
            html: #"<a href="/products/xm5">XM5</a>"#)
        // The page prints the barcode but was reached by a NAME search.
        fetcher.stub(
            "https://shop.example/products/xm5",
            html: """
            <meta property="og:title" content="Sony WH-1000XM5">
            <meta property="og:price:amount" content="329.99">
            <meta property="og:price:currency" content="USD">
            <p>EAN 0194644090876</p>
            """)
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shop", domain: "shop.example", acceptsGTIN: nil),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())
        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(outcome.results.first?.confidence, .gtinInPage)
    }

    // MARK: - Falling through to the next query

    /// A GTIN query whose extracted links all fail to verify (a retailer's
    /// own junk that happened to match a shared URL pattern, or simply the
    /// wrong product) used to END the candidate outright. The NAME query,
    /// asked second, is what actually finds the product.
    func testAGTINQueryWithNoVerifiedLinkFallsThroughToTheNameQuery() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://shop.example/search?q=0194644090876",
            html: #"<a href="/products/unrelated-widget">Unrelated</a>"#)
        fetcher.stub(
            "https://shop.example/products/unrelated-widget",
            html: productPage(name: "Garden Hose Reel", gtin: "0000000000001", price: "19.99"))
        fetcher.stub(
            "https://shop.example/search?q=Sony+WH-1000XM5",
            html: #"<a href="/products/xm5">XM5</a>"#)
        fetcher.stub(
            "https://shop.example/products/xm5",
            html: productPage(name: "Sony WH-1000XM5", gtin: "0194644090876", price: "329.99"))
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shop", domain: "shop.example", acceptsGTIN: nil),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())
        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(outcome.results.first?.url.absoluteString, "https://shop.example/products/xm5")
        XCTAssertEqual(fetcher.requested, [
            "https://shop.example/search?q=0194644090876",
            "https://shop.example/products/unrelated-widget",
            "https://shop.example/search?q=Sony+WH-1000XM5",
            "https://shop.example/products/xm5",
        ])
    }

    /// The fallthrough cannot double the run's cost: the total number of
    /// pages FETCHED across every query is still capped at
    /// `productURLsPerCandidate` (2, in this profile) — not that budget PER
    /// query.
    func testFallthroughIsBoundedByTheSamePerCandidateLinkBudget() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://shop.example/search?q=0194644090876",
            html: """
            <a href="/products/wrong-a">A</a><a href="/products/wrong-b">B</a>
            """)
        fetcher.stub(
            "https://shop.example/products/wrong-a",
            html: productPage(name: "Garden Hose Reel", gtin: "0000000000001", price: "19.99"))
        fetcher.stub(
            "https://shop.example/products/wrong-b",
            html: productPage(name: "Cordless Drill", gtin: "0000000000002", price: "59.99"))
        fetcher.stub(
            "https://shop.example/search?q=Sony+WH-1000XM5",
            html: #"<a href="/products/xm5">XM5</a>"#)
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shop", domain: "shop.example", acceptsGTIN: nil),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch)
            .run(request())
        XCTAssertTrue(outcome.results.isEmpty)
        // Two links already spent on the (wrong) GTIN query left no budget at
        // all for a second query — its search page is never even fetched.
        XCTAssertEqual(fetcher.requested, [
            "https://shop.example/search?q=0194644090876",
            "https://shop.example/products/wrong-a",
            "https://shop.example/products/wrong-b",
        ])
        XCTAssertEqual(outcome.rejection(for: "shop"), .noVerifiedMatch)
    }

    // MARK: - Rendering past a markup-only challenge

    /// A retailer's search sometimes serves a soft interstitial under an
    /// ordinary 200 rather than a blocked status — previously indistinguishable
    /// from a hard bot wall, so the run gave up on the host immediately. A
    /// context that can render gets one chance to see past it, exactly as it
    /// does for a structurally-empty page.
    func testAMarkupChallengeUnderTwoHundredGetsARenderAttempt() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://shop.example/search?q=0194644090876",
            html: "<html><body>Pardon Our Interruption</body></html>", statusCode: 200)
        fetcher.stub(
            "https://shop.example/products/xm5",
            html: productPage(name: "Sony WH-1000XM5", gtin: "0194644090876", price: "329.99"))
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shop", domain: "shop.example"),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch,
            renderSearch: { _ in #"<a href="/products/xm5">XM5</a>"# })
            .run(request())
        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertTrue(try! XCTUnwrap(outcome.attempts.first).usedRenderedSearch)
    }

    /// A genuinely BLOCKED status (403/429/…) is a hard refusal — there is
    /// nothing to render past, so no render slot is spent discovering that.
    func testABlockedStatusIsNeverRetriedThroughTheRenderer() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://shop.example/search?q=0194644090876", html: "refused", statusCode: 403)
        let renders = Counter()
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shop", domain: "shop.example"),
        ])
        _ = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch,
            renderSearch: { _ in await renders.bump(); return nil })
            .run(request())
        let count = await renders.value
        XCTAssertEqual(count, 0)
    }

    /// If the RENDERED markup still looks like a challenge, the host is
    /// marked bot-walled rather than treating the render as a second static
    /// fetch to search for links in.
    func testAChallengeThatSurvivesRenderingIsStillABotWall() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://shop.example/search?q=0194644090876",
            html: "<html><body>Please complete the CAPTCHA</body></html>", statusCode: 200)
        let directory = SellerDirectory(version: 1, sellers: [
            seller("shop", domain: "shop.example"),
        ])
        let outcome = await SellerFanOut(
            directory: directory, profile: profile, fetch: fetcher.fetch,
            renderSearch: { _ in "<html><body>Please complete the CAPTCHA</body></html>" })
            .run(request())
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(outcome.rejection(for: "shop"), .searchBotWalled)
    }
}

/// A book fanned out to a pet store, a hardware chain, an auto-parts chain and a
/// pharmacy, because tier alone put four tier-1 specialists above every tier-2
/// bookshop.
final class SellerCategoryRelevanceTests: XCTestCase {

    private func seller(_ id: String, tier: Int, categories: [String]) -> Seller {
        Seller(
            id: id, name: id, region: "US", domain: "\(id).example",
            searchURL: "https://\(id).example/s?q={query}", acceptsGTIN: nil,
            marketplace: false, categories: categories, tier: tier, verified: true)
    }

    func testABookOutranksUnrelatedSpecialists() {
        let directory = SellerDirectory(version: 1, sellers: [
            seller("pets", tier: 1, categories: ["pets"]),
            seller("auto", tier: 1, categories: ["auto"]),
            seller("pharmacy", tier: 1, categories: ["pharmacy"]),
            seller("bookshop", tier: 3, categories: ["books"]),
            seller("massmerchant", tier: 1, categories: ["general"]),
        ])
        let ranked = SellerCandidateSelector.select(
            SellerCandidateSelector.Input(
                sourceHost: "source.example", identifiers: ProductIdentifiers(gtin: "9780735211292"),
                productName: "Atomic Habits", categoryHints: ["book"],
                region: "US", limit: 5),
            in: directory).map(\.seller.id)

        XCTAssertEqual(Array(ranked.prefix(2)), ["massmerchant", "bookshop"])
        for unrelated in ["pets", "auto", "pharmacy"] {
            XCTAssertGreaterThan(
                try! XCTUnwrap(ranked.firstIndex(of: unrelated)),
                try! XCTUnwrap(ranked.firstIndex(of: "bookshop")),
                "\(unrelated) must rank below a shop that sells books")
        }
    }

    /// A mass merchant has no specialism to mismatch and is never penalized.
    func testMassMerchantsAreNeverPenalizedForNotSpecializing() {
        let mass = seller("mass", tier: 1, categories: ["general"])
        XCTAssertEqual(
            SellerCandidateSelector.score(mass, categories: ["books"], hasGTIN: false),
            SellerCandidateSelector.score(mass, categories: [], hasGTIN: false))
    }

    /// The singular hint that started this. Both directions of the plural now
    /// work, and so do the shelf words a breadcrumb uses.
    func testHintVocabularyIsNormalized() {
        for hint in ["book", "Books", "BOOKS", "Home › Books › Self-Help", "Books/Nonfiction"] {
            XCTAssertTrue(
                SellerCategoryInference.categories(hints: [hint], productName: "Atomic Habits")
                    .contains(SellerCategory.books.rawValue),
                "hint '\(hint)' should reach the books category")
        }
        XCTAssertTrue(
            SellerCategoryInference.categories(hints: ["Groceries"], productName: "Milk")
                .contains(SellerCategory.grocery.rawValue),
            "an irregular plural must reach its singular keyword")
    }

    /// Hyphenated vocabulary must survive the separator pass.
    func testHyphenatedKeywordsSurvive() {
        XCTAssertTrue(
            SellerCategoryInference.categories(hints: ["Blu-ray"], productName: "Dune")
                .contains(SellerCategory.media.rawValue))
    }
}
