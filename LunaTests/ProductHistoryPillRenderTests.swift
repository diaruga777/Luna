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

    private func render(historyRespJSON: String) {
        js.load(html: "<h1>Widget</h1>", urlString: "https://shop.example/p/1", scripts: [
            SafariJSTestHarness.newsHosts,
            SafariJSTestHarness.productRules,
            SafariJSTestHarness.contentScript,
        ])
        _ = js.evaluate("""
            window.__lunaRenderProductPills(
                { supportsProducts: true, scheme: "luna" }, \(historyRespJSON));
            "rendered"
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
}
