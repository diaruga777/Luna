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
    private static let contentScriptSource: String = {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("LunaSafari/Resources/content.js")
        return (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
    }()

    override func setUp() {
        super.setUp()
        XCTAssertFalse(
            Self.contentScriptSource.isEmpty,
            "content.js not found on disk -- check the path relative to #filePath")
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
}
