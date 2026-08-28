//
//  LiveNetworkPolicyTests.swift
//  LunaTests
//

import LunaFetch
import LunaModels
import LunaPriceCompare
import LunaPriceUI
import XCTest

/// Pins the ONE thing that keeps this suite off the live web: by default, inside
/// a test process, every live-network entry point refuses immediately.
///
/// The failure mode this guards against is not a red test — it is a GREEN one:
/// a save-driving test whose assertion happened to hold because a real retailer
/// answered. Those pass, slowly, until someone else's server changes.
final class LiveNetworkPolicyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LiveNetworkPolicy.resetRecordedRefusals()
    }

    override func tearDown() {
        LiveNetworkPolicy.overrideForTesting = nil
        LiveNetworkPolicy.resetRecordedRefusals()
        super.tearDown()
    }

    func testTheSuiteItselfRunsWithLiveNetworkRefused() {
        XCTAssertTrue(
            LiveNetworkPolicy.isRunningUnderXCTest,
            "This assertion runs inside XCTest by definition.")
        // If this fails, someone exported an opt-in variable into the ordinary
        // test run — which silently re-arms every fetcher in the process.
        XCTAssertFalse(
            LiveNetworkPolicy.isLiveNetworkAllowed,
            "The default test run must not be permitted to reach a live server.")
    }

    func testOptInKeyIsReadAsABooleanRatherThanAnyNonEmptyValue() {
        XCTAssertFalse(LiveNetworkPolicy.isOptedIn(key: "LUNA_DEFINITELY_UNSET_KEY_\(UUID())"))
    }

    func testRefusalCarriesTheCallSiteAndTheURL() {
        let refusal = LiveNetworkPolicy.Refusal(
            context: "SomeFetcher.fetch", urlString: "https://example.com/a")
        XCTAssertTrue(refusal.description.contains("SomeFetcher.fetch"))
        XCTAssertTrue(refusal.description.contains("https://example.com/a"))
        XCTAssertTrue(refusal.description.contains(LiveNetworkPolicy.optInEnvironmentKey))
    }

    func testCheckThrowsAndRecordsWhenRefused() {
        let url = URL(string: "https://example.com/product")!
        XCTAssertThrowsError(try LiveNetworkPolicy.check(url, context: "UnitTest")) { error in
            XCTAssertEqual(
                (error as? LiveNetworkPolicy.Refusal)?.urlString, url.absoluteString)
        }
        XCTAssertEqual(LiveNetworkPolicy.recordedRefusals.count, 1)
        XCTAssertEqual(LiveNetworkPolicy.recordedRefusals.first?.context, "UnitTest")
    }

    func testAllowsReturnsTrueWithoutRecordingWhenPermitted() {
        LiveNetworkPolicy.overrideForTesting = true
        XCTAssertTrue(
            LiveNetworkPolicy.allows(URL(string: "https://example.com")!, context: "UnitTest"))
        XCTAssertTrue(LiveNetworkPolicy.recordedRefusals.isEmpty)
        XCTAssertNoThrow(
            try LiveNetworkPolicy.check(URL(string: "https://example.com")!, context: "UnitTest"))
    }

    // MARK: - The entry points actually consult it

    func testArticleFetcherRefusesImmediatelyRatherThanTimingOut() async {
        let started = Date()
        do {
            _ = try await ArticleFetcher().fetchHTML(
                from: URL(string: "https://example.com/live-network-guard")!)
            XCTFail("A live fetch must not be attempted from a test process.")
        } catch {
            XCTAssertTrue(error is LiveNetworkPolicy.Refusal, "got \(error)")
        }
        // Fast is half the point: a 20 s timeout reads as a slow suite, not as a
        // mistake, and nobody goes looking.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testFaviconFetcherRefusesRatherThanFetching() async {
        let data = await FaviconFetcher().fetchIconData(
            forPageURL: URL(string: "https://example.com/page")!)
        XCTAssertNil(data)
        XCTAssertFalse(LiveNetworkPolicy.recordedRefusals.isEmpty)
    }

    func testDuckDuckGoSearchRefusesRatherThanSearching() async {
        let results = await DuckDuckGoSearch.results(forQuery: "live network guard")
        XCTAssertNil(results)
        XCTAssertEqual(
            LiveNetworkPolicy.recordedRefusals.map(\.context), ["DuckDuckGoSearch.results"])
    }

    func testFirecrawlSearchRefusesRatherThanSearching() async {
        let outcome = await FirecrawlSearch.results(forQuery: "live network guard")
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(
            LiveNetworkPolicy.recordedRefusals.map(\.context), ["FirecrawlSearch.results"])
    }

    /// The scare that started all of this: `SellerComparisonRunner.installed` is
    /// filled at app launch and the test host IS an app, so a test that drives a
    /// product save would otherwise fan out across a dozen real retailers.
    func testTheInstalledSellerFanOutRefusesToLeaveTheMachine() async {
        SellerComparisonRunner.install()
        defer { SellerComparisonRunner.installed = nil }
        let outcome = await SellerComparisonRunner.run(SellerFanOutRequest(
            sourceURL: URL(string: "https://shop.example.com/p/1")!,
            productName: "Acme Widget",
            identifiers: ProductIdentifiers(gtin: "00012345678905")))
        XCTAssertNil(outcome)
        XCTAssertEqual(
            LiveNetworkPolicy.recordedRefusals.map(\.context),
            ["SellerComparisonRunner.liveRun"])
    }
}
