//
//  ProductHistoryPillRenderTests.swift
//  LunaTests
//

import XCTest

/// The render DECISION `content.js` makes from a `productSnapshot` reply
/// (`{hasHistory, isTracked, amount, currency, day}`, computed natively --
/// see `SharedProductMatching.historyAnswer` — content.js only renders it):
/// history pill stacked above Track when unsaved-with-history, alone when
/// tracked-with-history, no pills when tracked-with-no-history, and just the
/// Track pill when there's no history at all. Driven directly through
/// `window.__lunaRenderProductPills`, the same hook a stubbed
/// `browser.runtime.sendMessage` reply would ultimately reach.
@MainActor
final class ProductHistoryPillRenderTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    /// A fresh document (so one test's pills never leak into the next) with the
    /// content script and the generated tables loaded, then `script`.
    private func run(_ script: String) {
        js.load(html: "<h1>Widget</h1>", urlString: "https://shop.example/p/1", scripts: [
            SafariJSTestHarness.newsHosts,
            SafariJSTestHarness.productRules,
            SafariJSTestHarness.contentScript,
        ])
        _ = js.evaluate(script + "\n\"ran\"")
    }

    private func render(historyRespJSON: String) {
        run("""
            window.__lunaRenderProductPills(
                { supportsProducts: true, scheme: "luna" }, \(historyRespJSON));
            """)
    }

    private var trackPillExists: Bool {
        js.bool("!!document.getElementById('queue-read-button')")
    }
    private var historyPillExists: Bool {
        js.bool("!!document.getElementById('queue-history-pill')")
    }
    private var historyPillText: String? {
        js.string("(document.getElementById('queue-history-pill') || {}).textContent")
    }

    func testUnsavedWithHistoryShowsBothPillsHistoryAboveTrack() {
        render(historyRespJSON: #"{hasHistory: true, isTracked: false, amount: "79.99", currency: "USD", day: "2026-01-12"}"#)
        XCTAssertTrue(trackPillExists)
        XCTAssertTrue(historyPillExists)
    }

    func testTrackedWithHistoryShowsOnlyTheHistoryPill() {
        render(historyRespJSON: #"{hasHistory: true, isTracked: true, amount: "79.99", currency: "USD", day: "2026-01-12"}"#)
        XCTAssertFalse(trackPillExists, "an already-tracked page must not also offer Track")
        XCTAssertTrue(historyPillExists)
    }

    func testTrackedWithNoHistoryShowsNoPillsAtAll() {
        render(historyRespJSON: "{hasHistory: false, isTracked: true}")
        XCTAssertFalse(trackPillExists)
        XCTAssertFalse(historyPillExists)
    }

    func testUnsavedWithNoHistoryShowsOnlyTheTrackPill() {
        render(historyRespJSON: "{hasHistory: false, isTracked: false}")
        XCTAssertTrue(trackPillExists)
        XCTAssertFalse(historyPillExists)
    }

    func testANullReplyFallsBackToJustTheTrackPill() {
        render(historyRespJSON: "null")
        XCTAssertTrue(trackPillExists)
        XCTAssertFalse(historyPillExists)
    }

    func testHistoryPillTextIncludesTheFormattedPriceAndDate() {
        render(historyRespJSON: #"{hasHistory: true, isTracked: false, amount: "79.99", currency: "USD", day: "2026-01-12"}"#)
        let text = historyPillText ?? ""
        XCTAssertTrue(text.contains("79.99") || text.contains("$79.99"), "pill text was: \(text)")
    }

    /// Non-interactive: the pill must never be able to swallow a page tap.
    func testHistoryPillIsPointerEventsNone() {
        render(historyRespJSON: #"{hasHistory: true, isTracked: false, amount: "79.99", currency: "USD", day: "2026-01-12"}"#)
        let pointerEvents = js.string(
            "getComputedStyle(document.getElementById('queue-history-pill')).pointerEvents")
        XCTAssertEqual(pointerEvents, "none")
    }

    // MARK: - The alternative-seller lookup

    /// Puts the page into the waiting state, as `handleProductPage` does once
    /// the `productSnapshot` reply lands.
    private func beginLookup(historyRespJSON: String = "{hasHistory: false, isTracked: false}") {
        run("""
            window.__lunaBeginSellerLookup(
                { supportsProducts: true, scheme: "luna" }, \(historyRespJSON));
            """)
    }

    /// Delivers the lookup's answer (or the absence of one).
    private func finishLookup(
        historyRespJSON: String = "{hasHistory: false, isTracked: false}",
        sellerRespJSON: String
    ) {
        _ = js.evaluate("""
            window.__lunaFinishSellerLookup(
                { supportsProducts: true, scheme: "luna" },
                \(historyRespJSON), \(sellerRespJSON));
            "finished"
            """)
    }

    private var sellerPillExists: Bool {
        js.bool("!!document.getElementById(window.__lunaSellerPillID)")
    }
    private var sellerPillState: String? {
        js.string("""
            (document.getElementById(window.__lunaSellerPillID) || { getAttribute: function () { return null; } })
                .getAttribute("data-luna-state")
            """)
    }
    private var sellerPillText: String? {
        js.string("(document.getElementById(window.__lunaSellerPillID) || {}).textContent")
    }
    private func sellerPillStyle(_ property: String) -> String? {
        js.string("getComputedStyle(document.getElementById(window.__lunaSellerPillID)).\(property)")
    }

    private static let foundSeller =
        #"{ found: true, price: "59.00", currency: "USD", sellerName: "Acme", url: "https://acme.example/p/1" }"#

    func testTheSpinnerStandsAboveTheTrackPillWhileTheLookupRuns() {
        beginLookup()
        XCTAssertEqual(sellerPillState, "loading")
        XCTAssertTrue(trackPillExists, "the Track pill isn't waiting on this lookup")
        XCTAssertFalse(historyPillExists, "history is held back until the lookup answers")
    }

    /// It is a status, not a control — a tap must reach the page under it.
    func testTheSpinnerIsNotTappable() {
        beginLookup()
        XCTAssertEqual(sellerPillStyle("pointerEvents"), "none")
    }

    func testAFoundSellerReplacesTheSpinnerInPlace() {
        beginLookup()
        finishLookup(sellerRespJSON: Self.foundSeller)
        XCTAssertEqual(sellerPillState, "found")
        let text = sellerPillText ?? ""
        XCTAssertTrue(text.contains("59"), "pill text was: \(text)")
        XCTAssertTrue(text.contains("Acme"), "pill text was: \(text)")
    }

    /// The whole point of this pill: it goes somewhere.
    func testAFoundSellerPillIsTappableAndCarriesTheSellersURL() {
        beginLookup()
        finishLookup(sellerRespJSON: Self.foundSeller)
        XCTAssertEqual(sellerPillStyle("pointerEvents"), "auto")
        XCTAssertEqual(
            js.string("""
                document.getElementById(window.__lunaSellerPillID)
                    .getAttribute("data-luna-seller-url")
                """),
            "https://acme.example/p/1")
    }

    /// A better price NOW and a lower price LAST MONTH would sit in the same
    /// slot; the current one wins and the historical one is not rendered.
    func testAFoundSellerSuppressesTheHistoryPill() {
        beginLookup(historyRespJSON: Self.historyReply)
        finishLookup(historyRespJSON: Self.historyReply, sellerRespJSON: Self.foundSeller)
        XCTAssertTrue(sellerPillExists)
        XCTAssertFalse(historyPillExists)
    }

    private static let historyReply =
        #"{hasHistory: true, isTracked: false, amount: "79.99", currency: "USD", day: "2026-01-12"}"#

    /// The fallback contract: nothing found leaves the page exactly as it was
    /// before this feature existed.
    func testNoSellerFoundFallsBackToTheHistoryPill() {
        beginLookup(historyRespJSON: Self.historyReply)
        finishLookup(historyRespJSON: Self.historyReply, sellerRespJSON: "{ found: false }")
        XCTAssertFalse(sellerPillExists, "the spinner must not be left behind")
        XCTAssertTrue(historyPillExists)
        XCTAssertTrue(trackPillExists)
    }

    func testNoSellerFoundAndNoHistoryLeavesJustTheTrackPill() {
        beginLookup()
        finishLookup(sellerRespJSON: "null")
        XCTAssertFalse(sellerPillExists)
        XCTAssertFalse(historyPillExists)
        XCTAssertTrue(trackPillExists)
    }

    /// An answer with no URL is not an answer — there is nowhere for the tap to
    /// go, so the page falls back rather than showing an inert pill.
    func testAFoundAnswerWithNoURLFallsBack() {
        beginLookup(historyRespJSON: Self.historyReply)
        finishLookup(
            historyRespJSON: Self.historyReply,
            sellerRespJSON: #"{ found: true, price: "59.00", currency: "USD", sellerName: "Acme" }"#)
        XCTAssertFalse(sellerPillExists)
        XCTAssertTrue(historyPillExists)
    }

    /// An already-tracked page shows no Track pill, so the seller pill takes
    /// the lower slot rather than floating above nothing.
    func testATrackedPageGetsTheSellerPillAloneInTheLowerSlot() {
        let tracked = "{hasHistory: false, isTracked: true}"
        beginLookup(historyRespJSON: tracked)
        finishLookup(historyRespJSON: tracked, sellerRespJSON: Self.foundSeller)
        XCTAssertFalse(trackPillExists)
        XCTAssertTrue(sellerPillExists)
        XCTAssertEqual(sellerPillStyle("bottom"), "20px")
    }

    func testAnUntrackedPagesSellerPillSitsAboveTheTrackPill() {
        beginLookup()
        finishLookup(sellerRespJSON: Self.foundSeller)
        XCTAssertEqual(sellerPillStyle("bottom"), "70px")
    }

    /// One lookup per page: the flag is set before any DOM work, so a second
    /// caller is refused rather than stacking a second spinner.
    func testTheLookupIsOneShotPerPage() {
        beginLookup()
        XCTAssertFalse(js.bool("""
            window.__lunaBeginSellerLookup({ supportsProducts: true, scheme: "luna" }, null)
            """))
        XCTAssertEqual(js.number("document.querySelectorAll('#' + window.__lunaSellerPillID).length"), 1)
    }

    /// A host app that doesn't handle products never asks.
    func testAHostThatDoesNotSupportProductsNeverLooksUp() {
        run("""
            window.__lunaSellerLookupBegan =
                window.__lunaBeginSellerLookup({ supportsProducts: false }, null);
            """)
        XCTAssertFalse(js.bool("window.__lunaSellerLookupBegan"))
        XCTAssertFalse(sellerPillExists)
    }

    // MARK: - The round trip's own guarantees

    /// Every non-answer collapses to nil before it reaches the render decision,
    /// so `finishSellerLookup` has exactly one shape to handle.
    func testARejectedRoundTripResolvesToNothingFound() {
        XCTAssertEqual(replyFor("Promise.reject(new Error('nope'))"), "null")
    }

    func testAThrowingRequestResolvesToNothingFound() {
        XCTAssertEqual(replyFor("(function () { throw new Error('nope'); })()"), "null")
    }

    func testANotFoundReplyResolvesToNothingFound() {
        XCTAssertEqual(replyFor("Promise.resolve({ found: false })"), "null")
    }

    func testAFoundReplyIsPassedThrough() {
        XCTAssertEqual(replyFor("Promise.resolve(\(Self.foundSeller))"), "https://acme.example/p/1")
    }

    /// Stubs the native request with `expression`, runs the round trip and
    /// reports what it resolved to: `"null"`, or the seller URL.
    private func replyFor(_ expression: String) -> String {
        run("""
            window.__lunaSetComparableSellersRequest(function () { return \(expression); });
            window.__lunaComparableReply = "pending";
            window.__lunaRequestComparableSellers({}).then(function (reply) {
                window.__lunaComparableReply = reply ? reply.url : "null";
            });
            """)
        // The stub settles on a microtask; a second round trip through
        // `evaluateJavaScript` is already past it.
        _ = js.evaluate("void 0")
        return js.string("window.__lunaComparableReply") ?? ""
    }
}
