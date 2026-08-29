//
//  WebSearchChainTests.swift
//  LunaTests
//

import LunaFetch
import LunaModels
import XCTest

/// The fan-out's Layer 2 is Firecrawl first, DuckDuckGo second, and the whole of
/// what makes that safe is the cooldown: Firecrawl's keyless budget is metered
/// per IP, so the device has to remember a refusal across processes instead of
/// re-discovering it on every save.
///
/// These drive the chain against stub providers and the cooldown against an
/// injected clock and a scratch defaults suite — nothing here reaches a server
/// or the user's real App Group.
final class WebSearchChainTests: XCTestCase {

    // MARK: - Stubs

    /// One scripted provider. Each call takes the next answer, so a test states
    /// the sequence a provider gives rather than a single value.
    private final class StubProvider: WebSearchProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [WebSearchProviderOutcome]
        private(set) var queries: [String] = []

        init(_ answers: [WebSearchProviderOutcome]) {
            self.answers = answers
        }

        func search(query: String) async -> WebSearchProviderOutcome {
            lock.withLock {
                queries.append(query)
                return answers.isEmpty ? .unavailable : answers.removeFirst()
            }
        }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_756_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "luna.tests.firecrawl.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = Date(timeIntervalSince1970: 1_756_000_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeCooldown() -> FirecrawlSearchCooldown {
        FirecrawlSearchCooldown(defaults: defaults, now: { [unowned self] in self.clock })
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - Order

    func testFirecrawlServesAndDuckDuckGoIsNeverAsked() async {
        let firecrawl = StubProvider([.results([url("https://a.example.com/p")])])
        let duckDuckGo = StubProvider([.results([url("https://b.example.com/p")])])
        let outcome = await WebSearchChain.search(
            forQuery: "hisense 634L", firecrawl: firecrawl, duckDuckGo: duckDuckGo,
            cooldown: makeCooldown())
        XCTAssertEqual(outcome.urls?.map(\.host), ["a.example.com"])
        XCTAssertEqual(outcome.servedBy, .firecrawl)
        XCTAssertEqual(outcome.firecrawl, .served(count: 1))
        XCTAssertEqual(firecrawl.queries, ["hisense 634L"])
        XCTAssertTrue(duckDuckGo.queries.isEmpty, "the fallback must cost nothing when unused")
    }

    func testAnUnavailableFirecrawlFallsBackToDuckDuckGo() async {
        let outcome = await WebSearchChain.search(
            forQuery: "widget", firecrawl: StubProvider([.unavailable]),
            duckDuckGo: StubProvider([.results([url("https://b.example.com/p")])]),
            cooldown: makeCooldown())
        XCTAssertEqual(outcome.urls?.map(\.host), ["b.example.com"])
        XCTAssertEqual(outcome.servedBy, .duckDuckGo)
        XCTAssertEqual(outcome.firecrawl, .unavailable)
    }

    func testBothProvidersFailingAnswersNilRatherThanNoResults() async {
        let outcome = await WebSearchChain.search(
            forQuery: "widget", firecrawl: StubProvider([.unavailable]),
            duckDuckGo: StubProvider([.unavailable]), cooldown: makeCooldown())
        XCTAssertNil(outcome.urls, "the fan-out reads nil as 'no search happened'")
        XCTAssertNil(outcome.servedBy)
    }

    /// A search that ran and found nothing is an answer. It still tries the
    /// second opinion, but a failing DuckDuckGo must not turn Firecrawl's
    /// answer into "no search happened".
    func testAnEmptyFirecrawlAnswerSurvivesAFailingFallback() async {
        let outcome = await WebSearchChain.search(
            forQuery: "widget", firecrawl: StubProvider([.results([])]),
            duckDuckGo: StubProvider([.unavailable]), cooldown: makeCooldown())
        XCTAssertEqual(outcome.urls, [])
        XCTAssertNil(outcome.servedBy)
        XCTAssertEqual(outcome.firecrawl, .empty)
    }

    func testAnEmptyFirecrawlAnswerYieldsToASecondOpinionThatFoundSomething() async {
        let outcome = await WebSearchChain.search(
            forQuery: "widget", firecrawl: StubProvider([.results([])]),
            duckDuckGo: StubProvider([.results([url("https://b.example.com/p")])]),
            cooldown: makeCooldown())
        XCTAssertEqual(outcome.urls?.map(\.host), ["b.example.com"])
        XCTAssertEqual(outcome.servedBy, .duckDuckGo)
    }

    // MARK: - The cooldown drives the order

    func testARateLimitFallsBackNowAndSkipsFirecrawlOnTheNextRun() async {
        let cooldown = makeCooldown()
        let firecrawl = StubProvider([.rateLimited(retryAfter: 90)])
        let duckDuckGo = StubProvider([
            .results([url("https://b.example.com/p")]),
            .results([url("https://c.example.com/p")]),
        ])
        let first = await WebSearchChain.search(
            forQuery: "widget", firecrawl: firecrawl, duckDuckGo: duckDuckGo, cooldown: cooldown)
        XCTAssertEqual(first.servedBy, .duckDuckGo)
        XCTAssertEqual(first.firecrawl, .rateLimited(cooldown: 90))

        clock.addTimeInterval(30)
        let second = await WebSearchChain.search(
            forQuery: "widget", firecrawl: firecrawl, duckDuckGo: duckDuckGo, cooldown: cooldown)
        XCTAssertEqual(second.servedBy, .duckDuckGo)
        XCTAssertEqual(second.firecrawl, .cooling(remaining: 60))
        XCTAssertEqual(
            firecrawl.queries.count, 1,
            "a cooling-down chain must not spend another request on Firecrawl")
    }

    func testFirecrawlIsAskedAgainOnceTheCooldownExpires() async {
        let cooldown = makeCooldown()
        cooldown.recordRateLimit(retryAfter: 90)
        clock.addTimeInterval(91)
        let firecrawl = StubProvider([.results([url("https://a.example.com/p")])])
        let outcome = await WebSearchChain.search(
            forQuery: "widget", firecrawl: firecrawl,
            duckDuckGo: StubProvider([.unavailable]), cooldown: cooldown)
        XCTAssertEqual(outcome.servedBy, .firecrawl)
        XCTAssertEqual(firecrawl.queries.count, 1)
    }

    /// The escalation is what the cooldown exists for: a bare 429 must not be
    /// retried every save until the daily cap resets.
    func testConsecutiveBareRateLimitsDoubleTheWaitUpToTheCap() {
        let cooldown = makeCooldown()
        var waits: [TimeInterval] = []
        for _ in 0..<10 {
            let wait = cooldown.recordRateLimit(retryAfter: nil)
            waits.append(wait)
            clock.addTimeInterval(wait + 1)
        }
        XCTAssertEqual(
            waits, [60, 120, 240, 480, 960, 1920, 3840, 7680, 14400, 14400])
        XCTAssertEqual(waits.last, FirecrawlSearchCooldown.maximumStep)
    }

    func testRetryAfterIsHonouredVerbatimWhileTheEscalationStillAdvances() {
        let cooldown = makeCooldown()
        XCTAssertEqual(cooldown.recordRateLimit(retryAfter: 5), 5)
        XCTAssertEqual(cooldown.remaining(), 5)
        clock.addTimeInterval(6)
        // The header decided the last wait; the second consecutive refusal is
        // still the second one, so a bare 429 now waits 120 s rather than 60.
        XCTAssertEqual(cooldown.recordRateLimit(retryAfter: nil), 120)
    }

    func testAServedSearchResetsTheEscalation() {
        let cooldown = makeCooldown()
        cooldown.recordRateLimit(retryAfter: nil)
        cooldown.recordRateLimit(retryAfter: nil)
        clock.addTimeInterval(200)
        cooldown.recordSuccess()
        XCTAssertNil(cooldown.remaining())
        XCTAssertEqual(cooldown.recordRateLimit(retryAfter: nil), FirecrawlSearchCooldown.firstStep)
    }

    func testAServedSearchThroughTheChainClearsAnExpiredEscalation() async {
        let cooldown = makeCooldown()
        cooldown.recordRateLimit(retryAfter: nil)
        clock.addTimeInterval(61)
        _ = await WebSearchChain.search(
            forQuery: "widget", firecrawl: StubProvider([.results([url("https://a.example.com/p")])]),
            duckDuckGo: StubProvider([.unavailable]), cooldown: cooldown)
        XCTAssertEqual(cooldown.recordRateLimit(retryAfter: nil), FirecrawlSearchCooldown.firstStep)
    }

    /// The cooldown is App-Group state precisely so a second process — the
    /// share extension, mid-save — reads the refusal the app already met.
    func testASecondReaderOfTheSameDefaultsSeesTheCooldown() {
        makeCooldown().recordRateLimit(retryAfter: 300)
        let elsewhere = FirecrawlSearchCooldown(defaults: defaults, now: { [unowned self] in self.clock })
        XCTAssertTrue(elsewhere.isCoolingDown)
        XCTAssertEqual(elsewhere.remaining(), 300)
    }

    // MARK: - What the run says in the log

    func testTheLogLineNamesTheProviderThatServedAndWhyTheFirstOneDidNot() {
        XCTAssertEqual(
            WebSearchChainOutcome(
                urls: [url("https://a.example.com/p")], servedBy: .firecrawl,
                firecrawl: .served(count: 1)).logLine,
            "web-search firecrawl=served served=firecrawl results=1")
        XCTAssertEqual(
            WebSearchChainOutcome(
                urls: [url("https://b.example.com/p"), url("https://c.example.com/p")],
                servedBy: .duckDuckGo, firecrawl: .rateLimited(cooldown: 90)).logLine,
            "web-search firecrawl=ratelimited(cooldown=90s) served=duckDuckGo results=2")
        XCTAssertEqual(
            WebSearchChainOutcome(
                urls: nil, servedBy: nil, firecrawl: .cooling(remaining: 59.6)).logLine,
            "web-search firecrawl=cooling(60s) served=none results=0")
        XCTAssertEqual(
            WebSearchChainOutcome(urls: nil, servedBy: nil, firecrawl: .unavailable).logLine,
            "web-search firecrawl=unavailable served=none results=0")
    }

    // MARK: - Neither leg may reach the live web from a test process

    func testTheRealChainRefusesBothLegsRatherThanSearching() async {
        LiveNetworkPolicy.resetRecordedRefusals()
        defer { LiveNetworkPolicy.resetRecordedRefusals() }
        let outcome = await WebSearchChain.search(
            forQuery: "live network guard", cooldown: makeCooldown())
        XCTAssertNil(outcome.urls)
        XCTAssertEqual(
            LiveNetworkPolicy.recordedRefusals.map(\.context),
            ["FirecrawlSearch.results", "DuckDuckGoSearch.results"])
    }
}
