import XCTest

/// Exercises the complete pill decision, including the article/product fallback,
/// so an Instagram utility page cannot merely switch to a different kind of pill.
@MainActor
final class SafariInstagramEligibilityTests: XCTestCase {
    private lazy var js = SafariJSTestHarness(self)

    private func offer(_ html: String, at url: String) {
        js.load(html: html, urlString: url, scripts: [
            SafariJSTestHarness.platformHosts, SafariJSTestHarness.newsHosts,
            SafariJSTestHarness.productRules, SafariJSTestHarness.contentScript,
        ])
        js.evaluate("""
            window.__lunaOfferLunaButton({ scheme: "luna", mode: "all",
                supportsArticles: true, supportsProducts: true,
                supportsMedia: true, videoPlayer: false });
            "offered"
            """)
        // Settle the product snapshot's promise as well as synchronous decisions.
        js.evaluate("void 0")
    }

    private var pillText: String? {
        js.string("document.getElementById(window.__lunaPillID)?.getAttribute('aria-label')")
    }

    private static let reportURL = "https://www.instagram.com/accounts/password/report/p5jutk6/"
    private static let utilityHTML = """
        <html><body><main><h1>Report a password reset</h1>
        <p>Let us know if you did not request this change.</p>
        <form><button>Continue</button></form></main></body></html>
        """

    func testPasswordReportAndOtherNonContentPagesHaveNoPill() {
        for url in [Self.reportURL,
                    "https://www.instagram.com/accounts/login/?next=/reel/ABC123/",
                    "https://www.instagram.com/accounts/password/reset/",
                    "https://www.instagram.com/accounts/password/report/reel/token/",
                    "https://www.instagram.com/challenge/token/",
                    "https://www.instagram.com/direct/inbox/",
                    "https://www.instagram.com/", "https://www.instagram.com/someone/",
                    "https://www.instagram.com/reels/", "https://www.instagram.com/p/",
                    "https://www.instagr.am/accounts/password/report/token/"] {
            offer(Self.utilityHTML, at: url)
            XCTAssertNil(pillText, url)
        }
    }

    func testUtilityPageCannotFallBackToArticleProductOrIncidentalVideo() {
        for html in [Self.articleHTML, Self.productHTML,
                     "<html><body><video></video></body></html>"] {
            offer(html, at: Self.reportURL)
            XCTAssertNil(pillText)
        }
        // Also cover the delayed article retry window.
        RunLoop.current.run(until: Date().addingTimeInterval(2.7))
        XCTAssertNil(pillText)
    }

    func testPostPermalinksStillQualifyBeforeTheirVideoHydrates() {
        for path in ["p/ABC123/", "someone/p/ABC123/", "reel/ABC123/",
                     "someone/reel/ABC123/", "reels/ABC123/", "tv/ABC123/",
                     "p/ABC123/embed/", "reel/ABC123?igsh=shared"] {
            offer("<html><body><p>Caption</p></body></html>",
                  at: "https://www.instagram.com/" + path)
            XCTAssertTrue(pillText?.contains("Luna actions") == true, path)
        }
        offer("<html><body><video></video></body></html>", at: "https://instagr.am/p/ABC123/")
        XCTAssertTrue(pillText?.contains("Luna actions") == true)
    }

    func testPhotoPostRemainsSuppressedButReelWithSameThumbnailQualifies() {
        let html = """
            <html><head><meta property="og:type" content="article">
            <meta property="og:image" content="https://cdn.example/cover.jpg"></head><body></body></html>
            """
        offer(html, at: "https://www.instagram.com/p/ABC123/")
        XCTAssertNil(pillText)
        offer(html, at: "https://www.instagram.com/reel/ABC123/")
        XCTAssertTrue(pillText?.contains("Luna actions") == true)
    }

    private static let articleHTML = """
        <html><head><meta property="og:type" content="article"></head><body><article>
        <h1>How password recovery works</h1>
        \(Array(repeating: "<p>" + String(repeating: "This is a detailed explanation of account recovery and the choices people make. ", count: 8) + "</p>", count: 6).joined())
        </article><form><input type="password"></form></body></html>
        """

    private static let productHTML = """
        <html><head><script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Product","name":"Security key",
         "offers":{"@type":"Offer","price":"49.99","priceCurrency":"USD"}}
        </script></head><body><h1>Security key</h1><p>$49.99</p></body></html>
        """

    func testArticlesAndPricedProductsOnOtherHostsKeepTheirPills() {
        // Identical utility-looking path text must not become a global blacklist.
        offer(Self.articleHTML, at: "https://example.com/accounts/password/report/guide/")
        XCTAssertTrue(pillText?.contains("Luna actions") == true)
        offer(Self.productHTML, at: "https://shop.example.com/accounts/password/report/security-key/")
        XCTAssertTrue(pillText?.contains("Luna actions") == true)
    }
}
