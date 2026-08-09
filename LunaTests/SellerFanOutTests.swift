//
//  SellerFanOutTests.swift
//  LunaTests
//

import LunaModels
import LunaPriceCompare
import XCTest

/// The orchestration itself, with every network call stubbed: which retailers
/// get asked and in what order, when the run stops, and how the two layers'
/// results are folded together. Nothing here touches the network — the whole
/// module is written against injected closures precisely so this is possible.
final class SellerFanOutTests: XCTestCase {

    // MARK: - Fixtures

    /// Records every URL it is asked for, in order, and answers from a table.
    /// A missing entry is a transport failure (nil), which is how "this seller
    /// simply didn't answer" is expressed.
    private final class StubFetcher: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [String: FetchedPage] = [:]
        private var requested: [String] = []

        func stub(_ urlString: String, html: String, statusCode: Int = 200) {
            lock.lock(); defer { lock.unlock() }
            pages[urlString] = FetchedPage(
                url: URL(string: urlString)!, html: html, statusCode: statusCode)
        }

        var requestedURLs: [String] {
            lock.lock(); defer { lock.unlock() }
            return requested
        }

        var fetch: SellerFanOut.Fetch {
            { [self] url in
                lock.lock()
                requested.append(url.absoluteString)
                let page = pages[url.absoluteString]
                lock.unlock()
                return page
            }
        }
    }

    /// A clock that advances a fixed step every time it is read, so budget
    /// expiry is a deterministic fact rather than a race with wall-clock time.
    private final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var ticks = 0
        private let step: TimeInterval
        private let origin = Date(timeIntervalSince1970: 1_700_000_000)

        init(step: TimeInterval) { self.step = step }

        var now: @Sendable () -> Date {
            { [self] in
                lock.lock(); defer { lock.unlock() }
                let date = origin.addingTimeInterval(Double(ticks) * step)
                ticks += 1
                return date
            }
        }
    }

    private func seller(_ id: String, tier: Int = 1, verified: Bool = false) -> Seller {
        Seller(
            id: id, name: id.capitalized, region: "US", domain: "\(id).example",
            searchURL: "https://\(id).example/search?q={query}",
            acceptsGTIN: false, marketplace: false, categories: ["general"],
            tier: tier, verified: verified)
    }

    /// Five sellers whose ranking is fixed by tier and id: a, b, c, d, e.
    private var directory: SellerDirectory {
        SellerDirectory(version: 1, sellers: [
            seller("a"), seller("b"), seller("c"),
            seller("d", tier: 2), seller("e", tier: 3),
        ])
    }

    private func searchHTML(productPath: String) -> String {
        "<html><body><a href=\"\(productPath)\">Result</a></body></html>"
    }

    private func productHTML(
        name: String = "Sony WH-1000XM5", gtin: String? = "0194644090876",
        price: String = "299.00", currency: String = "USD"
    ) -> String {
        let gtinLine = gtin.map { "\"gtin13\":\"\($0)\"," } ?? ""
        return """
        <script type="application/ld+json">
        {"@type":"Product","name":"\(name)",\(gtinLine)"brand":{"name":"Sony"},
         "offers":{"price":"\(price)","priceCurrency":"\(currency)"}}
        </script>
        """
    }

    private func request(
        excluding excluded: [String] = [], identifiers: ProductIdentifiers? = nil
    ) -> SellerFanOutRequest {
        SellerFanOutRequest(
            sourceURL: URL(string: "https://source.example/products/xm5")!,
            productName: "Sony WH-1000XM5",
            identifiers: identifiers ?? ProductIdentifiers(gtin: "0194644090876", brand: "Sony"),
            excludedURLStrings: excluded,
            regionOverride: "US")
    }

    private func profile(
        candidates: Int = 5, target: Int = 2, concurrency: Int = 1,
        budget: TimeInterval = 1_000, webSearch: Bool = false, nameOnly: Bool = true
    ) -> SellerFanOutProfile {
        SellerFanOutProfile(
            candidateLimit: candidates, resultTarget: target, concurrency: concurrency,
            productURLsPerCandidate: 2, totalBudget: budget, perFetchTimeout: 5,
            allowsNameOnlyMatch: nameOnly, usesWebSearchLayer: webSearch)
    }

    // MARK: - Rank order

    func testAsksCandidatesInRankOrder() async {
        let fetcher = StubFetcher()
        // Every search answers with nothing usable, so the run walks the list.
        for id in ["a", "b", "c", "d", "e"] {
            fetcher.stub("https://\(id).example/search?q=Sony+WH-1000XM5", html: "<html></html>")
        }
        let outcome = await SellerFanOut(
            directory: directory, profile: profile(), fetch: fetcher.fetch,
            localeRegion: "US").run(request())
        XCTAssertEqual(outcome.attemptedSellerIDs, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(outcome.stopReason, .exhausted)
        XCTAssertTrue(outcome.results.isEmpty)
    }

    func testConcurrentLaunchesStillFollowRankOrder() async {
        let fetcher = StubFetcher()
        for id in ["a", "b", "c", "d", "e"] {
            fetcher.stub("https://\(id).example/search?q=Sony+WH-1000XM5", html: "<html></html>")
        }
        let outcome = await SellerFanOut(
            directory: directory, profile: profile(concurrency: 3), fetch: fetcher.fetch,
            localeRegion: "US").run(request())
        XCTAssertEqual(outcome.attemptedSellerIDs, ["a", "b", "c", "d", "e"])
    }

    // MARK: - Stopping

    func testStopsAtTheResultTarget() async {
        let fetcher = StubFetcher()
        for id in ["a", "b", "c", "d", "e"] {
            fetcher.stub(
                "https://\(id).example/search?q=Sony+WH-1000XM5",
                html: searchHTML(productPath: "/products/xm5"))
            fetcher.stub("https://\(id).example/products/xm5", html: productHTML())
        }
        let outcome = await SellerFanOut(
            directory: directory, profile: profile(target: 2), fetch: fetcher.fetch,
            localeRegion: "US").run(request())
        XCTAssertEqual(outcome.results.count, 2)
        XCTAssertEqual(outcome.stopReason, .reachedTarget)
        XCTAssertEqual(outcome.attemptedSellerIDs, ["a", "b"], "no candidate is asked needlessly")
        XCTAssertEqual(outcome.results.map(\.sellerName), ["A", "B"])
        XCTAssertEqual(outcome.results.first?.confidence, .gtin)
        XCTAssertEqual(outcome.results.first?.source, .directory)
        XCTAssertEqual(outcome.results.first?.price, Decimal(string: "299.00"))
    }

    func testBudgetExpiryStopsTheRunEarly() async {
        let fetcher = StubFetcher()
        for id in ["a", "b", "c", "d", "e"] {
            fetcher.stub("https://\(id).example/search?q=Sony+WH-1000XM5", html: "<html></html>")
        }
        // 10s per clock read against a 15s budget: the run gets a couple of
        // candidates in and then must stop rather than walk the whole list.
        let outcome = await SellerFanOut(
            directory: directory, profile: profile(budget: 15), fetch: fetcher.fetch,
            localeRegion: "US", now: SteppingClock(step: 10).now).run(request())
        XCTAssertEqual(outcome.stopReason, .budgetExpired)
        XCTAssertLessThan(outcome.attemptedSellerIDs.count, 5)
        XCTAssertFalse(outcome.attemptedSellerIDs.isEmpty)
    }

    // MARK: - Bot walls

    /// A refused search means the whole host is out for this run — following
    /// its product links would just spend the budget collecting more 403s.
    func testABotWalledHostIsNeverAskedAgainInTheSameRun() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://a.example/search?q=Sony+WH-1000XM5",
            html: searchHTML(productPath: "/products/xm5"), statusCode: 403)
        fetcher.stub("https://a.example/products/xm5", html: productHTML())
        for id in ["b", "c", "d", "e"] {
            fetcher.stub(
                "https://\(id).example/search?q=Sony+WH-1000XM5",
                html: searchHTML(productPath: "/products/xm5"))
            fetcher.stub("https://\(id).example/products/xm5", html: productHTML())
        }
        let outcome = await SellerFanOut(
            directory: directory, profile: profile(target: 2), fetch: fetcher.fetch,
            localeRegion: "US").run(request())
        XCTAssertFalse(
            fetcher.requestedURLs.contains("https://a.example/products/xm5"),
            "a bot-walled host must not be followed into")
        XCTAssertEqual(outcome.results.map(\.sellerName), ["B", "C"])
    }

    func testAChallengePageServedWithTwoHundredCountsAsABotWall() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://a.example/search?q=Sony+WH-1000XM5",
            html: "<html>Please complete the captcha</html><a href=\"/products/xm5\">x</a>")
        fetcher.stub("https://a.example/products/xm5", html: productHTML())
        let outcome = await SellerFanOut(
            directory: SellerDirectory(version: 1, sellers: [seller("a")]),
            profile: profile(target: 1), fetch: fetcher.fetch, localeRegion: "US").run(request())
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertFalse(fetcher.requestedURLs.contains("https://a.example/products/xm5"))
    }

    // MARK: - Verification

    func testAPageForADifferentProductIsRejected() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://a.example/search?q=Sony+WH-1000XM5",
            html: searchHTML(productPath: "/products/other"))
        fetcher.stub(
            "https://a.example/products/other",
            html: productHTML(name: "Sony WH-1000XM4", gtin: "9999999999999"))
        let outcome = await SellerFanOut(
            directory: SellerDirectory(version: 1, sellers: [seller("a")]),
            profile: profile(target: 1), fetch: fetcher.fetch, localeRegion: "US").run(request())
        XCTAssertTrue(outcome.results.isEmpty, "a different GTIN is a refusal")
        XCTAssertEqual(outcome.stopReason, .exhausted)
    }

    func testAPageWithNoStructuredPriceIsSkippedAndTheNextLinkTried() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://a.example/search?q=Sony+WH-1000XM5",
            html: """
            <a href="/products/priceless">One</a><a href="/products/xm5">Two</a>
            """)
        fetcher.stub("https://a.example/products/priceless", html: "<html><title>Sony</title></html>")
        fetcher.stub("https://a.example/products/xm5", html: productHTML())
        let outcome = await SellerFanOut(
            directory: SellerDirectory(version: 1, sellers: [seller("a")]),
            profile: profile(target: 1), fetch: fetcher.fetch, localeRegion: "US").run(request())
        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(outcome.results.first?.url.absoluteString, "https://a.example/products/xm5")
    }

    // MARK: - Exclusions

    func testExistingStoresAndTheSourceAreNeverAsked() async {
        let fetcher = StubFetcher()
        for id in ["a", "b", "c", "d", "e"] {
            fetcher.stub("https://\(id).example/search?q=Sony+WH-1000XM5", html: "<html></html>")
        }
        let outcome = await SellerFanOut(
            directory: directory, profile: profile(), fetch: fetcher.fetch, localeRegion: "US")
            .run(request(excluding: ["https://www.b.example/products/xm5"]))
        XCTAssertEqual(outcome.attemptedSellerIDs, ["a", "c", "d", "e"])
    }

    // MARK: - Rich resolver

    /// The full profile hands candidate verification to the shared pipeline, so
    /// a JS-rendered price still counts. When the resolver answers, the lean
    /// parser is not consulted and the page is not fetched twice.
    func testRichResolverSupersedesTheLeanParser() async {
        let fetcher = StubFetcher()
        fetcher.stub(
            "https://a.example/search?q=Sony+WH-1000XM5",
            html: searchHTML(productPath: "/products/xm5"))
        // Deliberately NOT stubbed as a product page: only the resolver can answer.
        let resolved = ParsedProductPage(
            url: URL(string: "https://a.example/products/xm5")!,
            name: "Sony WH-1000XM5", price: Decimal(string: "279.00"), currency: "USD",
            identifiers: ProductIdentifiers(gtin: "0194644090876", brand: "Sony"))
        let outcome = await SellerFanOut(
            directory: SellerDirectory(version: 1, sellers: [seller("a")]),
            profile: profile(target: 1), fetch: fetcher.fetch,
            richResolve: { _ in resolved }, localeRegion: "US").run(request())
        XCTAssertEqual(outcome.results.first?.price, Decimal(string: "279.00"))
        XCTAssertFalse(fetcher.requestedURLs.contains("https://a.example/products/xm5"))
    }

    // MARK: - Layer 2

    func testWebSearchLayerContributesHostsTheDirectoryNeverHeardOf() async {
        let fetcher = StubFetcher()
        for id in ["a", "b", "c", "d", "e"] {
            fetcher.stub("https://\(id).example/search?q=Sony+WH-1000XM5", html: "<html></html>")
        }
        fetcher.stub("https://indie.example/products/xm5", html: productHTML(price: "249.00"))
        let outcome = await SellerFanOut(
            directory: directory, profile: profile(target: 2, webSearch: true),
            fetch: fetcher.fetch,
            webSearch: { _ in [URL(string: "https://indie.example/products/xm5")!] },
            localeRegion: "US").run(request())
        XCTAssertEqual(outcome.results.count, 1)
        XCTAssertEqual(outcome.results.first?.domain, "indie.example")
        XCTAssertEqual(outcome.results.first?.source, .webSearch)
        XCTAssertNil(outcome.results.first?.sellerID, "an unknown host has no directory id")
    }

    func testWebSearchSkipsExcludedDomainsAndListingURLs() async {
        let fetcher = StubFetcher()
        fetcher.stub("https://a.example/search?q=Sony+WH-1000XM5", html: "<html></html>")
        fetcher.stub("https://source.example/products/xm5", html: productHTML())
        fetcher.stub("https://indie.example/search?q=xm5", html: productHTML())
        let outcome = await SellerFanOut(
            directory: SellerDirectory(version: 1, sellers: [seller("a")]),
            profile: profile(target: 2, webSearch: true), fetch: fetcher.fetch,
            webSearch: { _ in [
                URL(string: "https://source.example/products/xm5")!,
                URL(string: "https://indie.example/search?q=xm5")!,
            ] },
            localeRegion: "US").run(request())
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertFalse(fetcher.requestedURLs.contains("https://source.example/products/xm5"))
        XCTAssertFalse(fetcher.requestedURLs.contains("https://indie.example/search?q=xm5"))
    }

    func testWebSearchQueryPrefersGTINDigitsThenBrandedName() {
        let subject = SellerFanOut(
            directory: directory, profile: profile(), fetch: { _ in nil }, localeRegion: "US")
        XCTAssertEqual(
            subject.webSearchQuery(SellerFanOutRequest(
                sourceURL: URL(string: "https://source.example/p")!,
                productName: "Sony WH-1000XM5",
                identifiers: ProductIdentifiers(gtin: "0194644090876", brand: "Sony"))),
            "0194644090876")
        XCTAssertEqual(
            subject.webSearchQuery(SellerFanOutRequest(
                sourceURL: URL(string: "https://source.example/p")!,
                productName: "WH-1000XM5 Headphones",
                identifiers: ProductIdentifiers(brand: "Sony"))),
            "Sony WH-1000XM5 Headphones")
        XCTAssertEqual(
            subject.webSearchQuery(SellerFanOutRequest(
                sourceURL: URL(string: "https://source.example/p")!,
                productName: "Sony WH-1000XM5",
                identifiers: ProductIdentifiers(brand: "Sony"))),
            "Sony WH-1000XM5", "the brand is not repeated when the name already has it")
        XCTAssertEqual(
            subject.webSearchQuery(SellerFanOutRequest(
                sourceURL: URL(string: "https://www.amazon.com.au/dp/B084PTKMTT")!,
                productName: "Russell Hobbs Carlton 2 Slice Toaster, Chrome: Toasters: Amazon.com.au",
                identifiers: ProductIdentifiers(brand: "Russell Hobbs"))),
            "Russell Hobbs Carlton 2 Slice Toaster, Chrome",
            "the web-search query is the CLEANED name, like the retailer searches")
    }

    // MARK: - Profiles

    func testShippedProfiles() {
        XCTAssertEqual(SellerFanOutProfile.full.candidateLimit, 12)
        XCTAssertEqual(SellerFanOutProfile.full.resultTarget, 6)
        XCTAssertEqual(SellerFanOutProfile.full.concurrency, 3)
        XCTAssertTrue(SellerFanOutProfile.full.usesWebSearchLayer)
        XCTAssertTrue(SellerFanOutProfile.full.allowsNameOnlyMatch)

        XCTAssertEqual(SellerFanOutProfile.constrained.candidateLimit, 6)
        XCTAssertEqual(SellerFanOutProfile.constrained.resultTarget, 3)
        XCTAssertEqual(SellerFanOutProfile.constrained.concurrency, 2)
        XCTAssertFalse(SellerFanOutProfile.constrained.usesWebSearchLayer)
        XCTAssertFalse(SellerFanOutProfile.constrained.allowsNameOnlyMatch)
        // The Safari appex answers inside a 20s native budget.
        XCTAssertLessThan(SellerFanOutProfile.constrained.totalBudget, 20)
        // Candidates are over-provisioned against the target in BOTH profiles —
        // that is what makes an expected bot wall survivable.
        XCTAssertGreaterThan(
            SellerFanOutProfile.full.candidateLimit, SellerFanOutProfile.full.resultTarget)
        XCTAssertGreaterThan(
            SellerFanOutProfile.constrained.candidateLimit,
            SellerFanOutProfile.constrained.resultTarget)
    }
}

/// The Layer-1/Layer-2 merge rule on its own: one price per retailer, a
/// better-verified result supplants a weaker one for the same retailer, and
/// otherwise the first to complete stands.
final class ComparableResultMergerTests: XCTestCase {

    private func result(
        domain: String, price: String, confidence: SellerMatchConfidence,
        source: ComparableResultSource = .directory
    ) -> ComparableSellerResult {
        ComparableSellerResult(
            sellerID: nil, sellerName: domain, domain: domain,
            url: URL(string: "https://\(domain)/p/\(price)")!,
            price: Decimal(string: price)!, currency: "USD", productName: "Widget",
            identifiers: ProductIdentifiers(), imageURL: nil,
            confidence: confidence, source: source)
    }

    func testNewDomainsAppendInArrivalOrder() {
        var merger = ComparableResultMerger()
        XCTAssertTrue(merger.offer(result(domain: "a.example", price: "10", confidence: .name)))
        XCTAssertTrue(merger.offer(result(domain: "b.example", price: "20", confidence: .name)))
        XCTAssertEqual(merger.results.map(\.domain), ["a.example", "b.example"])
        XCTAssertEqual(merger.count, 2)
    }

    func testBetterVerifiedResultSupplantsTheSameDomainInPlace() {
        var merger = ComparableResultMerger()
        merger.offer(result(domain: "a.example", price: "10", confidence: .name))
        merger.offer(result(domain: "b.example", price: "20", confidence: .name))
        XCTAssertTrue(merger.offer(
            result(domain: "a.example", price: "11", confidence: .gtin, source: .webSearch)))
        XCTAssertEqual(merger.results.count, 2)
        XCTAssertEqual(merger.results.first?.price, Decimal(string: "11"))
        XCTAssertEqual(merger.results.first?.confidence, .gtin)
        XCTAssertEqual(merger.results.first?.source, .webSearch)
        XCTAssertEqual(
            merger.results.map(\.domain), ["a.example", "b.example"],
            "supplanting keeps the retailer's place in the list")
    }

    func testEqualOrWeakerConfidenceLeavesTheIncumbentAlone() {
        var merger = ComparableResultMerger()
        merger.offer(result(domain: "a.example", price: "10", confidence: .gtin))
        XCTAssertFalse(merger.offer(result(domain: "a.example", price: "5", confidence: .gtin)))
        XCTAssertFalse(merger.offer(result(domain: "a.example", price: "5", confidence: .name)))
        XCTAssertEqual(merger.results.count, 1)
        XCTAssertEqual(
            merger.results.first?.price, Decimal(string: "10"),
            "first completed wins — a cheaper second listing is not better evidence")
    }
}
