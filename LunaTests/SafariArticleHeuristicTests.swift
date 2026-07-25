//
//  SafariArticleHeuristicTests.swift
//  LunaTests
//

import WebKit
import XCTest

/// Exercises `looksLikeArticle` (the Readability-style scorer in
/// `LunaSafari/Resources/content.js`) against realistic fixtures by loading the raw
/// script into a plain `WKWebView` (no extension host, no `browser` global -- the
/// script itself guards every top-level `browser.*` reference so it can be
/// evaluated standalone) and calling the test-only hook it exposes,
/// `window.__lunaLooksLikeArticle`. Positive fixtures cover a news article, a
/// plain blog post, an old-school `<br>`-separated "book" page, and a
/// multi-section essay; negative fixtures cover a company landing page, a
/// comment thread, a docs page, a teaser listing, and a near-empty page -- all
/// tuned so the OLD (text-length-only) heuristic would have gotten some of them
/// wrong.
@MainActor
final class SafariArticleHeuristicTests: XCTestCase {

    /// `LunaTests/SafariArticleHeuristicTests.swift` -> repo root -> `LunaSafari/Resources/content.js`.
    private static let contentScriptSource: String = resource("LunaSafari/Resources/content.js")

    /// The generated shared news-host list (`self.__LUNA_NEWS_HOSTS`); background.js
    /// injects it before content.js in the real extension, so the host-gating tests
    /// evaluate it first too.
    private static let newsHostsSource: String = resource("LunaSafari/Resources/news_hosts.generated.js")
    private static let productRulesSource: String = resource("LunaSafari/Resources/product_rules.generated.js")

    private static func resource(_ relativePath: String) -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    override func setUp() {
        super.setUp()
        XCTAssertFalse(
            Self.contentScriptSource.isEmpty,
            "content.js not found on disk -- check the path relative to #filePath")
        XCTAssertFalse(
            Self.newsHostsSource.isEmpty,
            "news_hosts.generated.js not found on disk -- generate with TEST_RUNNER_RECORD_NEWS_HOSTS=1")
        XCTAssertFalse(
            Self.productRulesSource.isEmpty,
            "product_rules.generated.js not found -- generate with TEST_RUNNER_RECORD_PRODUCT_RULES=1")
    }

    // MARK: - Harness

    /// Loads `html` into a WKWebView at `urlString`, evaluates content.js, then
    /// evaluates `window.__lunaLooksLikeArticle()` and returns the result.
    @MainActor
    private func evaluateHeuristic(html: String, urlString: String = "https://example.com/story") -> Bool {
        let expectation = expectation(description: "heuristic evaluated")
        var outcome: Bool?

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            webView.evaluateJavaScript(Self.contentScriptSource) { _, error in
                if let error { XCTFail("content.js failed to evaluate: \(error)") }
                webView.evaluateJavaScript("window.__lunaLooksLikeArticle()") { result, error in
                    if let error { XCTFail("__lunaLooksLikeArticle() failed to evaluate: \(error)") }
                    outcome = result as? Bool
                    expectation.fulfill()
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: urlString))

        wait(for: [expectation], timeout: 10)
        withExtendedLifetime(delegate) {}
        guard let outcome else {
            XCTFail("heuristic never returned a Bool")
            return false
        }
        return outcome
    }

    /// Bridges `WKNavigationDelegate`'s didFinish callback to the closure above.
    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }

    // MARK: - Fixture prose

    /// Repeats a lorem-style sentence until at least `length` characters, then
    /// trims to exactly `length` -- gives every fixture paragraph a realistic,
    /// tunable volume of prose.
    private func prose(_ length: Int) -> String {
        let sentence = "The quiet observation gathered weight over the course of the afternoon, "
            + "each small detail folding into the next until the whole picture came into view, "
            + "slow and unmistakable, the way a tide only shows itself once it has already turned. "
        var text = ""
        while text.count < length { text += sentence }
        return String(text.prefix(length))
    }

    private func paragraphs(_ count: Int, length: Int) -> String {
        var html = ""
        for _ in 0..<count {
            html += "<p>\(prose(length))</p>"
        }
        return html
    }

    // MARK: - Positive fixtures

    /// (1) News article: og:type=article meta + 5 paragraphs in one <article>.
    func testNewsArticleWithMetadataIsArticle() {
        let html = """
        <html><head><meta property="og:type" content="article"></head>
        <body><article><h1>A Long Investigation</h1>\(paragraphs(5, length: 400))</article></body></html>
        """
        XCTAssertTrue(evaluateHeuristic(html: html, urlString: "https://example.com/news/2026/07/story"))
    }

    /// (2) Plain blog post, no metadata, 6 long paragraphs in a single div.post-body.
    func testPlainBlogPostIsArticle() {
        let body = paragraphs(6, length: 450)
        let html = """
        <html><body><div class="post-body">\(body)</div></body></html>
        """
        XCTAssertTrue(evaluateHeuristic(html: html, urlString: "https://example.com/blog/thoughts-on-things"))
    }

    /// (3) Book-style page: one big div, text separated by <br> instead of <p>.
    func testBookStyleBrSeparatedPageIsArticle() {
        var text = ""
        for _ in 0..<10 { text += prose(400) + "<br>" }
        let html = """
        <html><body><div class="chapter">\(text)</div></body></html>
        """
        XCTAssertTrue(evaluateHeuristic(html: html, urlString: "https://example.com/library/book/chapter-1"))
    }

    /// (4) Multi-section essay, og:type=article, paragraphs spread across 3 <section>s
    /// (passes via the metadata tier, not the cluster-concentration tier).
    func testMultiSectionEssayWithMetadataIsArticle() {
        var sections = ""
        for _ in 0..<3 {
            sections += "<section>\(paragraphs(2, length: 400))</section>"
        }
        let html = """
        <html><head><meta property="og:type" content="article"></head>
        <body>\(sections)</body></html>
        """
        XCTAssertTrue(evaluateHeuristic(html: html, urlString: "https://example.com/essays/long-form-piece"))
    }

    // MARK: - Negative fixtures

    /// (5) Company landing page: hero + 6 short-blurb sections + heavy nav/footer
    /// links. Well over 1500 total chars in <p> tags -- the OLD heuristic (text
    /// length + <h1>) would have accepted this; the new scorer should not.
    func testCompanyLandingPageIsNotArticle() {
        var nav = "<nav>"
        for i in 0..<20 { nav += "<a href=\"/product-\(i)\">Product Category Link Number \(i) With Extra Words</a>" }
        nav += "</nav>"
        var sections = "<div class=\"hero\"><h1>Welcome to Acme</h1><p>\(prose(180))</p></div>"
        for _ in 0..<6 {
            sections += "<section class=\"feature\"><p>\(prose(180))</p></section>"
        }
        var footer = "<footer>"
        for i in 0..<20 { footer += "<a href=\"/footer-\(i)\">Footer Navigation Link Number \(i) More Words</a>" }
        footer += "</footer>"
        let html = "<html><body>\(nav)\(sections)\(footer)</body></html>"
        // Sanity: total <p> text alone clears the old 1500-char threshold.
        XCTAssertFalse(evaluateHeuristic(html: html, urlString: "https://example.com/"))
    }

    /// (6) Comment thread: an intro paragraph plus 10 comment blocks, each a
    /// substantial <p> -- individually long enough to score, but disqualified by
    /// their `.comment` container ancestry.
    func testCommentThreadIsNotArticle() {
        var comments = ""
        for _ in 0..<10 {
            comments += "<div class=\"comment\"><p>\(prose(300))</p></div>"
        }
        let html = """
        <html><body><p>\(prose(300))</p>\(comments)</body></html>
        """
        XCTAssertFalse(evaluateHeuristic(html: html, urlString: "https://example.com/thread/12345"))
    }

    /// (7) Docs page: prose plus large <pre> code blocks outweighing it, at a
    /// `/docs/` URL (either signal alone would already disqualify it).
    func testDocsPageIsNotArticle() {
        var code = ""
        for i in 0..<8 {
            code += "<pre><code>function exampleHandler\(i)(request, response) {\n"
                + "  const payload = buildPayloadFromRequest(request, \(i));\n"
                + "  return response.status(200).json(payload);\n"
                + "}\n</code></pre>"
        }
        let html = """
        <html><body>\(paragraphs(2, length: 400))\(code)</body></html>
        """
        XCTAssertFalse(evaluateHeuristic(html: html, urlString: "https://example.com/docs/getting-started"))
    }

    /// (8) Listing page: 6 <article> teasers -- the >= 4 <article> hard negative.
    func testTeaserListingPageIsNotArticle() {
        var teasers = ""
        for i in 0..<6 {
            teasers += "<article><h2>Headline \(i)</h2><p>\(prose(150))</p></article>"
        }
        let html = "<html><body>\(teasers)</body></html>"
        XCTAssertFalse(evaluateHeuristic(html: html, urlString: "https://example.com/section/latest"))
    }

    /// (9) Near-empty page: a single short paragraph, nowhere near the scoring bar.
    func testNearEmptyPageIsNotArticle() {
        let html = "<html><body><p>Just a short line of text.</p></body></html>"
        XCTAssertFalse(evaluateHeuristic(html: html, urlString: "https://example.com/x"))
    }

    // MARK: - Shared news-host gating (extension <-> main-app parity)

    /// Loads `news_hosts.generated.js` (the shared `NewsSites` list) THEN content.js
    /// into a WKWebView at `urlString`, then evaluates `expression` -- so the host
    /// gating sees `location.hostname` from the baseURL and the injected host set,
    /// exactly as in the real extension.
    @MainActor
    private func evaluate(_ expression: String, html: String, urlString: String) -> Bool {
        let expectation = expectation(description: "evaluated \(expression)")
        var outcome: Bool?

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            webView.evaluateJavaScript(Self.newsHostsSource) { _, error in
                if let error { XCTFail("news_hosts.generated.js failed to evaluate: \(error)") }
                webView.evaluateJavaScript(Self.productRulesSource) { _, error in
                    if let error { XCTFail("product_rules.generated.js failed to evaluate: \(error)") }
                    webView.evaluateJavaScript(Self.contentScriptSource) { _, error in
                        if let error { XCTFail("content.js failed to evaluate: \(error)") }
                        webView.evaluateJavaScript(expression) { result, error in
                            if let error { XCTFail("\(expression) failed to evaluate: \(error)") }
                            outcome = result as? Bool
                            expectation.fulfill()
                        }
                    }
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: urlString))

        wait(for: [expectation], timeout: 10)
        withExtendedLifetime(delegate) {}
        guard let outcome else {
            XCTFail("\(expression) never returned a Bool")
            return false
        }
        return outcome
    }

    /// A metered news site's server-rendered teaser: og:type=article + NewsArticle
    /// JSON-LD, but only a couple of short lead paragraphs before the wall -- far too
    /// little qualifying prose for the DOM scorer to clear its bar. This is the AFR
    /// failure mode from the bug report.
    private func meteredTeaserHTML() -> String {
        return """
        <html><head>
        <meta property="og:type" content="article">
        <script type="application/ld+json">{"@context":"https://schema.org","@type":"NewsArticle","headline":"Teaser"}</script>
        </head>
        <body><article><h1>Anthropic wants Australian data centres</h1>
        <p>\(prose(150))</p><p>\(prose(150))</p>
        <div class="paywall">Subscribe to continue reading.</div>
        </article></body></html>
        """
    }

    /// (A) The bug repro, generalized: a known hard-paywall news host (afr.com) whose
    /// server sends only a thin teaser. The DOM scorer ALONE fails (too little prose --
    /// this is why the "Read in Luna" pill was absent), but the shared `NewsSites` host
    /// list classifies it as an article, exactly as the main app does. No afr-specific
    /// code: afr.com is just one of the ~450 entries in the shared list.
    func testKnownNewsHostWithThinTeaserIsArticle() {
        let html = meteredTeaserHTML()
        let afrURL = "https://www.afr.com/companies/infrastructure/some-story-20260706-p60cwq"
        // The scorer alone misses it (the original bug)...
        XCTAssertFalse(evaluate("window.__lunaLooksLikeArticle()", html: html, urlString: afrURL))
        // ...but sharing the app's host list makes it an article.
        XCTAssertTrue(evaluate("window.__lunaIsArticlePage()", html: html, urlString: afrURL))
        // ...and it's known-locked, so it also surfaces under the onlyLocked mode.
        XCTAssertTrue(evaluate("window.__lunaIsKnownHardPaywallHost()", html: html, urlString: afrURL))
    }

    /// A publisher front page is not one readable work. It can live on a known-news
    /// host and contain plenty of visible teaser copy, so the host fallback alone is
    /// insufficient. The landing-page schema plus a cluster of headline links is the
    /// general, site-agnostic index signal that must veto it.
    func testKnownNewsLandingPageWithHeadlineGridIsNotArticle() {
        var cards = ""
        for index in 0..<6 {
            cards += """
            <section class="story-card">
              <a href="/2026/07/12/story-\(index)"><h2>
                Major developing story number \(index) has a detailed headline
              </h2></a>
              <p>\(prose(130))</p>
            </section>
            """
        }
        let html = """
        <html><head>
          <meta property="og:type" content="website">
          <script type="application/ld+json">
            {"@context":"https://schema.org","@type":"WebPage",
             "additionalType":"landing_homepage","name":"News front page"}
          </script>
        </head><body><main>\(cards)</main></body></html>
        """

        XCTAssertFalse(evaluate(
            "window.__lunaLooksLikeArticle()", html: html, urlString: "https://edition.cnn.com/"))
        XCTAssertFalse(evaluate(
            "window.__lunaIsArticlePage()", html: html, urlString: "https://edition.cnn.com/"))
    }

    /// (A2) The Business Insider bug: a real article on a known FREE/metered news host
    /// that embeds a "read next" rail of related-story `<article>` cards. BI ships six
    /// `<article>` elements (the story plus its rail), which trips the `>= 4 <article>`
    /// structural index veto -- previously killing the "Read in Luna" pill even though
    /// the host is known and the page declares a `NewsArticle`. Positive article
    /// metadata on a known host must win, exactly as the native free-host fast-path
    /// classifies it `.article` outright. No BI-specific code: businessinsider.com is
    /// just one of the entries in the shared `NewsSites.free` list.
    func testKnownNewsArticleWithRelatedArticleCardsIsArticle() {
        var relatedCards = ""
        for index in 0..<5 {
            relatedCards += """
            <article class="river-item"><a href="/story-\(index)"><h3>
              Another developing story number \(index) worth reading next
            </h3></a><p>\(prose(120))</p></article>
            """
        }
        let html = """
        <html><head>
          <meta property="og:type" content="article">
          <script type="application/ld+json">
            {"@context":"https://schema.org","@type":"NewsArticle",
             "headline":"A cyclospora outbreak has been linked to berries"}
          </script>
        </head><body>
          <article class="post-content">
            <h1>A cyclospora outbreak has been linked to berries</h1>
            <p>\(prose(160))</p><p>\(prose(160))</p>
            <div class="ad ad-wrapper fluid in-post">Advertisement</div>
          </article>
          \(relatedCards)
        </body></html>
        """
        let biURL = "https://www.businessinsider.com/cyclospora-outbreak-berries-safe-kids-toddlers-2026-7"
        // Six <article> elements would trip the raw index veto (proving the repro)...
        XCTAssertTrue(evaluate(
            "document.querySelectorAll('article').length >= 4", html: html, urlString: biURL))
        // ...but a known news host declaring an article still shows the Read in Luna pill.
        XCTAssertTrue(evaluate(
            "window.__lunaIsArticlePage()", html: html, urlString: biURL))
    }

    /// A declared article on an UNKNOWN host, shaped like theparisreview.org: an
    /// "Article" JSON-LD node and `og:type=article`, real prose, thirteen
    /// "more from this issue" `<article>` cards, and a sign-in form in the site header.
    /// Both of the veto's structural halves fired (`>= 4 <article>`, and the
    /// document-wide `input[type=password]` inside the scorer), so the "Read in Luna"
    /// pill never appeared on any Paris Review interview. Neither shape says anything
    /// about the page's kind, and a rail of cards is not a property of the HOST — so
    /// declared article metadata must clear both, on the known-news list or not.
    func testUnknownHostArticleWithCardRailAndHeaderSignInIsArticle() {
        var issueCards = ""
        for index in 0..<13 {
            issueCards += """
            <article class="issue-card"><a href="/issue/48/piece-\(index)"><h3>
              Another piece from this issue, number \(index), also worth reading
            </h3></a></article>
            """
        }
        let html = """
        <html><head>
          <meta property="og:type" content="article">
          <script type="application/ld+json">
            {"@context":"https://schema.org/","@type":"Article",
             "name":"John Steinbeck, The Art of Fiction No. 45"}
          </script>
        </head><body>
          <nav>
            <div id="modal_login" class="modal-fade-screen"><form>
              <input type="email" name="login-email"><input type="password" name="login-pass">
            </form></div>
          </nav>
          <article class="interview"><h1>John Steinbeck, The Art of Fiction No. 45</h1>
            <main class="article-body">\(paragraphs(6, length: 420))</main>
          </article>
          \(issueCards)
        </body></html>
        """
        let url = "https://www.theparisreview.org/interviews/3810/the-art-of-fiction-no-45-john-steinbeck"

        // Both blockers are present in the fixture (proving the repro)...
        XCTAssertTrue(evaluate(
            "document.querySelectorAll('article').length >= 4", html: html, urlString: url))
        XCTAssertTrue(evaluate(
            "!!document.querySelector('input[type=\"password\"]')", html: html, urlString: url))
        // ...and the declared article still scores, and still gets the pill.
        XCTAssertTrue(evaluate("window.__lunaLooksLikeArticle()", html: html, urlString: url))
        XCTAssertTrue(evaluate("window.__lunaIsArticlePage()", html: html, urlString: url))
    }

    /// The exemption is only for a page that DECLARES an article: strip the metadata
    /// from the same markup and the structural shapes veto exactly as before, so this
    /// didn't become blanket acceptance of card grids and login pages.
    func testUndeclaredPageWithCardRailAndSignInIsNotArticle() {
        var issueCards = ""
        for index in 0..<13 {
            issueCards += """
            <article class="issue-card"><a href="/issue/48/piece-\(index)"><h3>
              Another piece from this issue, number \(index), also worth reading
            </h3></a></article>
            """
        }
        let html = """
        <html><head></head><body>
          <nav><form><input type="password" name="login-pass"></form></nav>
          <div class="interview">\(paragraphs(6, length: 420))</div>
          \(issueCards)
        </body></html>
        """
        let url = "https://randomblog.example/whatever"

        XCTAssertFalse(evaluate("window.__lunaLooksLikeArticle()", html: html, urlString: url))
        XCTAssertFalse(evaluate("window.__lunaIsArticlePage()", html: html, urlString: url))
    }

    /// A real sign-in page is still rejected — it carries the password field and no
    /// article declaration, which is what the check was always for.
    func testSignInPageIsNotArticle() {
        let html = """
        <html><head><meta property="og:type" content="website"></head><body>
          <main><h1>Sign in to your account</h1>
          <form><input type="email"><input type="password"><button>Sign in</button></form>
          \(paragraphs(4, length: 400))
          </main>
        </body></html>
        """
        XCTAssertFalse(evaluate(
            "window.__lunaIsArticlePage()", html: html, urlString: "https://example.com/account/login"))
    }

    /// (B) Control: the identical thin teaser on a host NOT in the shared list gets no
    /// host rescue and correctly fails the DOM scorer -- proving the fix keys on the
    /// shared host data, not blanket acceptance of thin pages.
    func testUnknownHostWithThinTeaserIsNotArticle() {
        let html = meteredTeaserHTML()
        XCTAssertFalse(evaluate(
            "window.__lunaIsArticlePage()", html: html, urlString: "https://randomblog.example/some-post"))
    }

    /// (C) Fallback intact: an unknown host with a genuinely long article body is still
    /// an article via the DOM scorer -- the host list is additive; it does not gate real
    /// articles on non-news hosts behind a list.
    func testUnknownHostWithFullArticleIsArticle() {
        let html = "<html><body><div class=\"post-body\">\(paragraphs(6, length: 450))</div></body></html>"
        XCTAssertTrue(evaluate(
            "window.__lunaIsArticlePage()", html: html, urlString: "https://randomblog.example/thoughts"))
    }

    // MARK: - Product-page gating (the "Track in Luna" pill)

    /// A grid of several products, each with its own "Add to cart" button and star
    /// rating -- the per-card retail furniture that fires on a search-results page.
    private func productGridHTML() -> String {
        var cards = ""
        let names = ["Sony WH-1000XM5", "Bose QuietComfort Ultra", "Apple AirPods Max", "Sennheiser Momentum 4"]
        for name in names {
            cards += """
            <div class="s-result-item"><h2>\(name)</h2>
            <span class="a-icon-alt">4.6 out of 5 stars</span>
            <span class="a-price"><span class="a-offscreen">$329.00</span></span>
            <button name="submit.addToCart">Add to cart</button></div>
            """
        }
        return "<html><head><meta property=\"og:type\" content=\"website\"></head>"
            + "<body><h1>results for \"headphones\"</h1>\(cards)</body></html>"
    }

    /// The bug: on an Amazon `/s?k=…` search page, the per-card add-to-cart + rating
    /// furniture made `looksLikeProductPage` true, so a "Track in Luna" pill appeared
    /// over a page with no single primary product. The listing-URL veto rejects it.
    func testAmazonSearchResultsIsNotAProductPage() {
        XCTAssertFalse(evaluate(
            "window.__lunaLooksLikeProductPage()",
            html: productGridHTML(),
            urlString: "https://www.amazon.com/s?k=wireless+headphones"))
    }

    /// The identical grid markup served at a single-product `/dp/` URL still counts
    /// (product URL anchor + add-to-cart) -- proving the veto keys on the listing URL,
    /// not on the presence of retail furniture.
    func testSameMarkupAtProductURLIsAProductPage() {
        XCTAssertTrue(evaluate(
            "window.__lunaLooksLikeProductPage()",
            html: productGridHTML(),
            urlString: "https://www.amazon.com/Sony-WH-1000XM5/dp/B09XS7JWHH"))
    }

    /// A genuine single-product page (a JSON-LD Product offer) is still recognized.
    func testSingleProductJSONLDIsAProductPage() {
        let html = """
        <html><head><script type="application/ld+json">
        {"@type":"Product","name":"Anker 715 Charger",
         "offers":{"@type":"Offer","price":"45.99","priceCurrency":"USD"}}
        </script></head><body><h1>Anker 715 Charger</h1></body></html>
        """
        XCTAssertTrue(evaluate(
            "window.__lunaLooksLikeProductPage()",
            html: html, urlString: "https://www.anker.com/products/a2664"))
    }

    /// New Yorker and similar publisher pages carry secondary commerce markup
    /// (subscription prices, store cards, ratings) strong enough to satisfy the
    /// generic product detector. The shared news-host classification must win in
    /// Safari just as it does in Swift, so the extension offers Reader—not Tracker.
    func testKnownNewsArticleCommerceMarkupIsNotAProductPage() {
        let html = """
        <html><head>
          <meta property="og:type" content="article">
          <meta property="product:price:amount" content="120.00">
          <meta property="product:price:currency" content="USD">
        </head><body><article>
          <h1>The Voice of Google</h1><p>Subscriber preview.</p>
          <button>Add to cart</button><div>Star Rating: 5 out of 5</div>
        </article></body></html>
        """
        let newYorkerURL =
            "https://www.newyorker.com/culture/the-weekend-essay/the-voice-of-google"

        XCTAssertFalse(evaluate(
            "window.__lunaLooksLikeProductPage()", html: html, urlString: newYorkerURL))
        XCTAssertTrue(evaluate(
            "window.__lunaIsArticlePage()", html: html, urlString: newYorkerURL))
        XCTAssertTrue(evaluate(
            "window.__lunaIsKnownHardPaywallHost()", html: html, urlString: newYorkerURL))

        XCTAssertTrue(evaluate(
            "window.__lunaLooksLikeProductPage()",
            html: html,
            urlString: "https://publisher.example/store/offer"),
            "Unknown hosts must retain generic product detection"
        )
    }

    /// New Yorker serves its full body in paragraph/blockquote nodes carrying the
    /// `paywall` class. Removing only the modal leaves those nodes hidden. The generic
    /// in-place cleanup must remove that class while deleting the content-less overlay.
    func testRevealArticleUnhidesPaywallClassedArticleBody() {
        let html = """
        <html><head><style>.paywall { display: none; }</style></head><body>
          <article><h1>The Voice of Google</h1>
            <p>Visible lead paragraph.</p>
            <p id="locked-paragraph" class="paywall">Full subscriber paragraph.</p>
            <blockquote id="locked-quote" class="paywall">Full subscriber quotation.</blockquote>
          </article>
          <div id="paywall-overlay" class="paywall">Subscribe to continue reading.</div>
        </body></html>
        """
        let expression = """
        (function () {
          window.__lunaRevealArticle();
          var paragraph = document.getElementById('locked-paragraph');
          var quote = document.getElementById('locked-quote');
          return !!paragraph && !!quote
            && !paragraph.classList.contains('paywall')
            && !quote.classList.contains('paywall')
            && getComputedStyle(paragraph).display !== 'none'
            && document.getElementById('paywall-overlay') === null;
        })()
        """
        XCTAssertTrue(evaluate(
            expression,
            html: html,
            urlString: "https://www.newyorker.com/culture/the-weekend-essay/the-voice-of-google"
        ))
    }

    /// A component-driven metering wall (Business Insider's shape, generalized): the
    /// full body is present but its content container is clamped by an inline
    /// max-height + mask, hidden behind a `pw-modal-backdrop` and a
    /// `data-component-type="paywall"` component plus a display:none inline-backup wall.
    /// The generic cleanup must delete the content-LESS overlays and un-clamp the
    /// prose-bearing container without deleting the body. No site-specific selectors —
    /// it keys on the paywall attribute/backdrop shape and the inline clamp.
    func testRevealArticleDismantlesComponentDrivenWall() {
        let html = """
        <html><body>
          <article>
            <h1>A cyclospora outbreak has been linked to berries</h1>
            <div data-content-container id="body"
                 style="max-height:220px;overflow:hidden;-webkit-mask-image:linear-gradient(#000,transparent)">
              <p>First full subscriber paragraph. \(prose(200))</p>
              <p>Second full subscriber paragraph. \(prose(200))</p>
              <p>Third full subscriber paragraph. \(prose(200))</p>
            </div>
          </article>
          <div class="pw-modal-entry"></div>
          <div class="pw-modal-backdrop"></div>
          <div data-component-type="paywall" data-content-selector="[data-content-container]"></div>
          <div class="inline-backup-paywall modal" data-component-type="inline-backup-paywall"
               style="display:none"><span>This story is available exclusively to subscribers.</span></div>
        </body></html>
        """
        let expression = """
        (function () {
          window.__lunaRevealArticle();
          var body = document.getElementById('body');
          return !!body
            && document.querySelector('.pw-modal-backdrop') === null
            && document.querySelector('[data-component-type="paywall"]') === null
            && document.querySelector('.inline-backup-paywall') === null
            && body.style.maxHeight === 'none'
            && body.style.overflow === 'visible'
            && body.textContent.indexOf('First full subscriber') >= 0;
        })()
        """
        XCTAssertTrue(evaluate(
            expression, html: html,
            urlString: "https://www.businessinsider.com/cyclospora-outbreak-berries-safe-kids-toddlers-2026-7"))
    }
}
