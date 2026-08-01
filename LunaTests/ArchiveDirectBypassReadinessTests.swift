//
//  ArchiveDirectBypassReadinessTests.swift
//  LunaTests
//

import LunaArchiveReader
import LunaModels
import WebKit
import XCTest

/// The direct-unlock pre-stage's readiness probe, run against fixture pages in a
/// real `WKWebView` (the JS is the thing under test, so evaluating it is the only
/// honest way to test it).
///
/// The case that motivated these: WSJ wraps TEASER CARDS in their own `<article>`,
/// so a page whose real body hasn't hydrated still has article elements in it.
/// Treating their mere existence as "the article rendered" let the whole-document
/// extraction save teaser prose + page furniture as the article.
@MainActor
final class ArchiveDirectBypassReadinessTests: XCTestCase {

    private func probeResult(for html: String) async throws -> String {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let loaded = expectation(description: "loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/a"))
        await fulfillment(of: [loaded], timeout: 20)
        let result = try await webView.evaluateJavaScript(
            ArchiveWebReaderViewController.directBypassStageProbeJavaScript)
        withExtendedLifetime(delegate) {}
        return (result as? String) ?? ""
    }

    private func prose(_ characters: Int) -> String {
        String(repeating: "The eclipse crossed the meridian at dawn. ",
               count: characters / 42 + 1)
    }

    /// A page carrying only teaser cards is NOT ready, however many of them there
    /// are — this is the WSJ shape that used to read as a rendered article.
    func testTeaserArticleCardsAreNotReadiness() async throws {
        let cards = (0..<6).map { index in
            "<article><h3>Teaser \(index)</h3><p>A one-line standfirst.</p></article>"
        }.joined()
        let result = try await probeResult(for: "<html><body><h1>Section</h1>\(cards)</body></html>")

        XCTAssertNotEqual(
            result, "content-root",
            "Teaser cards in their own <article> must not read as a rendered article")
    }

    /// The real body, wherever it sits among the teasers, IS readiness — the probe
    /// scans every match rather than stopping at the first.
    func testRealArticleAmongTeasersIsReadiness() async throws {
        let teaser = "<article><h3>Teaser</h3><p>A one-line standfirst.</p></article>"
        let real = "<article><h1>The real one</h1><p>\(prose(2000))</p></article>"
        let result = try await probeResult(
            for: "<html><body>\(teaser)\(real)\(teaser)</body></html>")

        XCTAssertEqual(result, "content-root")
    }

    /// A container holding an article's worth of text still reads as ready on its
    /// own — the ordinary case must not regress.
    func testSingleRenderedArticleIsReadiness() async throws {
        let result = try await probeResult(for: """
        <html><body><article><h1>Story</h1><p>\(prose(1600))</p></article></body></html>
        """)

        XCTAssertEqual(result, "content-root")
    }

    /// The bar is the extractor's own threshold, so the probe can never call a page
    /// ready that extraction would then reject as unreadable.
    func testReadinessBarMatchesTheExtractorsReadableThreshold() async throws {
        let under = try await probeResult(for: """
        <html><body><article><p>\(prose(ArticleContent.readableBodyThreshold - 400))</p></article></body></html>
        """)
        let over = try await probeResult(for: """
        <html><body><article><p>\(prose(ArticleContent.readableBodyThreshold + 400))</p></article></body></html>
        """)

        XCTAssertNotEqual(under, "content-root")
        XCTAssertEqual(over, "content-root")
    }

    /// An access CAPTCHA with no article behind it still reveals for the user.
    func testAccessChallengeIsStillDetectedWhenNoArticleRendered() async throws {
        let result = try await probeResult(for: """
        <html><body><iframe src="https://www.google.com/recaptcha/api2/anchor"></iframe></body></html>
        """)

        XCTAssertEqual(result, "challenge")
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish()
        }
    }
}
