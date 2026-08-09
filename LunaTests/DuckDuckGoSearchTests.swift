//
//  DuckDuckGoSearchTests.swift
//  LunaTests
//

import LunaFetch
import XCTest

/// `DuckDuckGoSearch.resultURLs` was silently dead: `html.duckduckgo.com` now
/// serves every result as a DIRECT href on `class="result__a"`, and the old
/// parser understood only the historical `…/l/?uddg=` redirect wrapper — a
/// live 200 page full of results parsed to zero links. These pin BOTH shapes
/// (a live capture for the direct one, a crafted fixture for the legacy one
/// the code must keep understanding too) and the anomaly/challenge page that
/// must be refused rather than parsed as an empty success.
final class DuckDuckGoSearchTests: XCTestCase {

    private func fixture(_ name: String) -> String {
        BypassFixtures.html("DuckDuckGo/\(name)")
    }

    // MARK: - The shape DuckDuckGo now actually serves

    func testDirectHrefResultsAreParsedInDocumentOrderExcludingAds() {
        let urls = DuckDuckGoSearch.resultURLs(inHTML: fixture("ddg-direct-results.html"))
        XCTAssertEqual(urls.map(\.host), [
            "hisense.com.au", "www.thegoodguys.com.au", "www.harveynorman.com.au",
            "www.binglee.com.au", "www.appliancesonline.com.au", "www.costco.com.au",
            "www.jbhifi.com.au", "auhomeappliances.com.au", "www.retravision.com.au",
            "www.appliancecentral.com.au",
        ])
        XCTAssertFalse(urls.contains { $0.host?.contains("duckduckgo.com") == true },
                       "the two paid y.js results must not be parsed as organic results")
    }

    func testDirectHrefBingleeResultIsPresent() throws {
        let urls = DuckDuckGoSearch.resultURLs(inHTML: fixture("ddg-direct-results.html"))
        let binglee = try XCTUnwrap(urls.first { $0.host == "www.binglee.com.au" })
        XCTAssertEqual(
            binglee.absoluteString,
            "https://www.binglee.com.au/products/634l-pureflat-french-door-dark-steel-hrfd634bw")
    }

    // MARK: - The historical shape it must keep understanding

    func testLegacyUddgWrappedResultsAreUnwrappedInDocumentOrderExcludingAds() {
        let urls = DuckDuckGoSearch.resultURLs(inHTML: fixture("ddg-legacy-uddg-results.html"))
        XCTAssertEqual(urls.map(\.host), [
            "www.binglee.com.au", "www.thegoodguys.com.au", "www.retravision.com.au",
        ])
        XCTAssertEqual(
            urls.first?.absoluteString,
            "https://www.binglee.com.au/products/634l-pureflat-french-door-dark-steel-hrfd634bw")
    }

    // MARK: - The anomaly/challenge page

    /// A results page and the challenge page are told apart by their MARKUP,
    /// not by status code — DuckDuckGo has been observed to serve the exact
    /// same challenge under both a 202 and an ordinary 200.
    func testAnomalyPageIsRecognizedRegardlessOfStatusCode() {
        XCTAssertTrue(DuckDuckGoSearch.isAnomalyPage(fixture("ddg-anomaly-challenge.html")))
        XCTAssertFalse(DuckDuckGoSearch.isAnomalyPage(fixture("ddg-direct-results.html")))
        XCTAssertFalse(DuckDuckGoSearch.isAnomalyPage(fixture("ddg-legacy-uddg-results.html")))
    }

    func testAnomalyPageYieldsNoResultURLsRatherThanBeingMisparsed() {
        XCTAssertTrue(DuckDuckGoSearch.resultURLs(inHTML: fixture("ddg-anomaly-challenge.html")).isEmpty)
    }

    // MARK: - Small shape details worth pinning directly

    func testAmpEscapedAmpersandsInHrefsSurviveUnwrapping() {
        let html = """
        <a class="result__a" href="https://shop.example/p?a=1&amp;b=2">X</a>
        """
        XCTAssertEqual(
            DuckDuckGoSearch.resultURLs(inHTML: html).first?.absoluteString,
            "https://shop.example/p?a=1&b=2")
    }

    func testDuplicateResolvedURLsAreDeduplicated() {
        let html = """
        <a class="result__a" href="https://shop.example/p">A</a>
        <a class="result__a" href="https://shop.example/p">A again</a>
        """
        XCTAssertEqual(DuckDuckGoSearch.resultURLs(inHTML: html).count, 1)
    }

    func testProtocolRelativeLegacyHrefIsUnwrapped() {
        let html = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fshop.example%2Fp&rut=x">X</a>
        """
        XCTAssertEqual(
            DuckDuckGoSearch.resultURLs(inHTML: html).first?.absoluteString, "https://shop.example/p")
    }

    func testProtocolRelativeDirectHrefResolvesToHTTPS() {
        let html = #"<a class="result__a" href="//shop.example/p">X</a>"#
        XCTAssertEqual(
            DuckDuckGoSearch.resultURLs(inHTML: html).first?.absoluteString, "https://shop.example/p")
    }

    func testNonResultAnchorsAreIgnored() {
        let html = """
        <a class="nav__a" href="https://shop.example/help">Help</a>
        <a class="result__a" href="https://shop.example/product">Product</a>
        """
        XCTAssertEqual(
            DuckDuckGoSearch.resultURLs(inHTML: html).map(\.absoluteString),
            ["https://shop.example/product"])
    }
}
