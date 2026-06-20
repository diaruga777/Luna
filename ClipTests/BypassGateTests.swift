//
//  BypassGateTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Exercises the single `BypassGate` — the hard gate that decides whether ANY
/// paywall bypass may run. The critical assertions are the NO-bypass cases: a
/// readable article, a product page, and a platform link must never be bypassed.
final class BypassGateTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    /// A readable article body (clears the readability gate, no paywall text).
    private func readableArticle() -> ArticleContent {
        let paragraph = String(repeating: "An ordinary readable sentence about the topic at hand. ", count: 20)
        return ArticleContent(title: "Real Story", blocks: [
            .init(kind: .paragraph, text: paragraph, links: []),
            .init(kind: .paragraph, text: paragraph, links: []),
        ])
    }

    private let readableFreeHTML = "<html><body><article>"
        + String(repeating: "<p>Ordinary free article prose here, nothing locked. </p>", count: 20)
        + "</article></body></html>"

    // MARK: NO-bypass cases (false positives the gate must eliminate)

    func testReadableArticleDoesNotBypass() {
        let decision = BypassGate.decision(
            for: url("https://example.com/news/story"),
            html: readableFreeHTML, extracted: readableArticle())
        XCTAssertEqual(decision, .block(.readableArticle))
        XCTAssertFalse(decision.allowsBypass)
    }

    func testProductPageDoesNotBypass() {
        let productURL = "https://www.bunnings.com.au/ryobi-18v-one-25-30cm-cordless-line-trimmer-tool-only_p0208315"
        let html = BypassFixtures.html("Products/bunnings-nextdata.html")
        let decision = BypassGate.decision(for: url(productURL), html: html, extracted: nil)
        XCTAssertEqual(decision, .block(.productPage))
        XCTAssertFalse(decision.allowsBypass)
    }

    func testPlatformLinkDoesNotBypass() {
        // YouTube, X, and a music link are all platform links.
        for link in [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://x.com/jack/status/20",
            "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT",
        ] {
            let decision = BypassGate.decision(for: url(link), html: readableFreeHTML, extracted: nil)
            XCTAssertEqual(decision, .block(.platformLink), "\(link) must not bypass")
        }
    }

    /// A platform link wins even over a hard-paywall-host check (it's checked first).
    func testPlatformWinsOverEverything() {
        let decision = BypassGate.decision(
            for: url("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), html: nil, extracted: nil)
        XCTAssertEqual(decision, .block(.platformLink))
    }

    func testShortNonArticleFreePageDoesNotBypass() {
        // A fetched page that's neither a product, platform, nor wall: a JS shell /
        // landing page. No paywall evidence ⇒ no bypass.
        let shell = "<html><body><div id=\"root\"></div><p>Loading…</p></body></html>"
        let decision = BypassGate.decision(
            for: url("https://example.com/app"), html: shell, extracted: nil)
        XCTAssertEqual(decision, .block(.notPaywalled))
    }

    // MARK: bypass cases (genuine paywalls)

    func testDeclaredLockedBypasses() {
        let locked = #"<html><body><p>x</p><script type="application/ld+json">{"isAccessibleForFree":false}</script></body></html>"#
        let decision = BypassGate.decision(for: url("https://example.com/x"), html: locked, extracted: nil)
        XCTAssertEqual(decision, .attempt(.declaredLocked))
        XCTAssertTrue(decision.allowsBypass)
    }

    func testGateMarkerInHTMLBypasses() {
        let metered = "<html><body><p>To continue reading, subscribe to read the rest.</p></body></html>"
        let decision = BypassGate.decision(for: url("https://example.com/x"), html: metered, extracted: nil)
        XCTAssertEqual(decision, .attempt(.gateMarker))
    }

    func testPaywalledExtractedStubBypasses() {
        // A short extracted body carrying a gate phrase (teaser) bypasses even when
        // the raw HTML wasn't provided.
        let stub = ArticleContent(title: "FT Headline", blocks: [
            .init(kind: .paragraph, text: "The lede. To continue reading this article subscribe now.", links: []),
        ])
        let decision = BypassGate.decision(for: url("https://example.com/x"), html: nil, extracted: stub)
        XCTAssertEqual(decision, .attempt(.gateMarker))
    }

    func testHardPaywallHostWithNoReadableBodyBypasses() {
        // WSJ 401: no HTML, no extraction → the host check alone allows the archive path.
        let decision = BypassGate.decision(
            for: url("https://www.wsj.com/articles/x"), html: nil, extracted: nil)
        XCTAssertEqual(decision, .attempt(.hardPaywallHostUnreadable))
    }

    /// A hard-paywall host that DID return a readable body (reader logged in via
    /// their browser session-cookie path) must NOT be bypassed — content beats host.
    func testHardPaywallHostWithReadableBodyDoesNotBypass() {
        let decision = BypassGate.decision(
            for: url("https://www.wsj.com/articles/x"),
            html: readableFreeHTML, extracted: readableArticle())
        XCTAssertEqual(decision, .block(.readableArticle))
    }

    func testArchiveSnapshotBypasses() {
        let decision = BypassGate.decision(
            for: url("https://archive.is/abcde"), html: nil, extracted: nil)
        XCTAssertEqual(decision, .attempt(.archiveSnapshot))
    }

    func testUnknownHostFailedFetchBypasses() {
        // Direct fetch failed on an unknown host: can't prove it's free → best-effort.
        let decision = BypassGate.decision(
            for: url("https://unknown.example/story"), html: nil, extracted: nil)
        XCTAssertEqual(decision, .attempt(.unprovenFreeUnknownHost))
    }
}
