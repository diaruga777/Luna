//
//  SafariSubscribeInterstitialTests.swift
//  LunaTests
//

import WebKit
import XCTest

/// Covers the Safari half of the News Corp Australia unlock, by evaluating the real
/// `LunaSafari/Resources/content.js` in a bare `WKWebView` (no extension host — the
/// script guards every `browser.*` reference, exactly as the other Safari JS tests
/// rely on):
///
/// 1. `subscribeInterstitialTarget` — the article a publisher's subscribe page is
///    holding, which the extension then navigates to with an `?amp` flag. This is the
///    only way to unlock in Safari on those sites: the article is not in the document
///    at all, so the DOM cleanup has nothing to reveal.
/// 2. The AMP subscriber-gate strip inside `revealArticle` — an AMP document carries
///    the story AND the pitch, and the runtime chooses between them after load.
@MainActor
final class SafariSubscribeInterstitialTests: XCTestCase {

    private static let contentScriptSource: String = resource("LunaSafari/Resources/content.js")
    private static let newsHostsSource: String = resource("LunaSafari/Resources/news_hosts.generated.js")
    private static let productRulesSource: String = resource("LunaSafari/Resources/product_rules.generated.js")

    private static func resource(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: repoRoot.appendingPathComponent(relativePath),
                            encoding: .utf8)) ?? ""
    }

    private let articleURL = "https://www.theaustralian.com.au/wealth/retirement/"
        + "selffunded-retirees-hit-by-new-30pc-topup-tax-on-investments/news-story/"
        + "476176fcef46250d229a1612ce9f44d1"

    override func setUp() {
        super.setUp()
        XCTAssertFalse(Self.contentScriptSource.isEmpty, "content.js not found on disk")
        XCTAssertFalse(Self.newsHostsSource.isEmpty, "news_hosts.generated.js not found on disk")
    }

    // MARK: - Harness

    /// Loads `html` at `urlString`, evaluates the generated data globals + content.js,
    /// then evaluates `script` and returns its result.
    private func evaluate(_ script: String, html: String, urlString: String) -> Any? {
        let expectation = expectation(description: "script evaluated")
        var outcome: Any?
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            webView.evaluateJavaScript(Self.newsHostsSource) { _, _ in
                webView.evaluateJavaScript(Self.productRulesSource) { _, _ in
                    webView.evaluateJavaScript(Self.contentScriptSource) { _, error in
                        if let error { XCTFail("content.js failed to evaluate: \(error)") }
                        webView.evaluateJavaScript(script) { result, error in
                            if let error { XCTFail("\(script) failed: \(error)") }
                            outcome = result
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
        return outcome
    }

    private func target(html: String, urlString: String) -> String? {
        evaluate("window.__lunaSubscribeInterstitialTarget()", html: html, urlString: urlString) as? String
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }

    /// A trimmed capture of the live subscribe page, which carries the article in both
    /// `dest=` and `og:url`.
    private var subscribeHTML: String {
        BypassFixtures.html("Readable/theaustralian-subscribe.html")
    }

    private var interstitialURL: String {
        "https://www.theaustralian.com.au/subscribe/news/1/?sourceCode=TAWEB_MRE170_a&dest="
            + (articleURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? articleURL)
            + "&memtype=anonymous&mode=premium"
    }

    // MARK: - Finding the held article

    func testSubscribeInterstitialNamesTheArticleItHolds() {
        XCTAssertEqual(target(html: subscribeHTML, urlString: interstitialURL), articleURL)
    }

    /// `og:url` alone is enough (the same publishers emit it with `og:type=article`) —
    /// this is the shape the browser-tier cleanup script reads.
    func testOGURLIsUsedWhenNoTargetParamIsPresent() {
        let html = """
        <html><head><meta property="og:type" content="article">
        <meta property="og:url" content="\(articleURL)"></head>
        <body><p>Subscribe to The Australian</p></body></html>
        """
        XCTAssertEqual(
            target(html: html,
                   urlString: "https://www.theaustralian.com.au/subscribe/news/1/?sourceCode=x"),
            articleURL)
    }

    /// An ordinary article page is not an interstitial, so nothing is proposed.
    func testArticlePageProposesNoHop() {
        XCTAssertNil(target(html: "<html><body><p>Story</p></body></html>", urlString: articleURL))
    }

    /// The hop must never fire on a SIGN-IN / checkout page: the user started
    /// something there, and `?next=` would abandon it.
    func testSignInAndCheckoutPagesAreLeftAlone() {
        let html = """
        <html><head><meta property="og:type" content="article">
        <meta property="og:url" content="\(articleURL)"></head><body><p>Log in</p></body></html>
        """
        for path in ["/login/?next=/account", "/signin/", "/checkout/step-1/", "/register/"] {
            XCTAssertNil(
                target(html: html, urlString: "https://www.theaustralian.com.au" + path),
                path)
        }
    }

    /// The same-site rule is what keeps this from being an open-redirect follower.
    func testOffSiteTargetIsRejected() {
        let html = "<html><body><p>Subscribe</p></body></html>"
        XCTAssertNil(target(
            html: html,
            urlString: "https://www.theaustralian.com.au/subscribe/news/1/?dest="
                + "https%3A%2F%2Fevil.example%2Fphish"))
    }

    /// Unknown hosts are out of scope entirely — this only runs where the app already
    /// recognizes a news site.
    func testUnknownHostProposesNoHop() {
        let html = """
        <html><head><meta property="og:type" content="article">
        <meta property="og:url" content="https://randomblog.example/post"></head>
        <body><p>Subscribe</p></body></html>
        """
        XCTAssertNil(target(html: html, urlString: "https://randomblog.example/subscribe/"))
    }

    // MARK: - The AMP flag

    func testAMPFlagMatchesTheSwiftTransform() {
        let html = "<html><body><p>x</p></body></html>"
        XCTAssertEqual(
            evaluate("window.__lunaWithAMPFlag(\"\(articleURL)\")", html: html,
                     urlString: articleURL) as? String,
            articleURL + "?amp")
        XCTAssertEqual(
            evaluate("window.__lunaWithAMPFlag(\"\(articleURL)?utm_source=x\")", html: html,
                     urlString: articleURL) as? String,
            articleURL + "?utm_source=x&amp")
        XCTAssertEqual(
            evaluate("window.__lunaWithAMPFlag(\"\(articleURL)?amp\")", html: html,
                     urlString: articleURL) as? String,
            articleURL + "?amp")
    }

    // MARK: - The AMP gate strip

    /// On the AMP page the story is present but attribute-gated, and the pitch sits
    /// beside it. After `revealArticle`, the body is visible and the pitch is gone.
    func testRevealArticleStripsTheAMPSubscriberGate() {
        let html = """
        <html><body><article>
        <div id="story-body">
        <section subscriptions-section="content"><p>Under previous arrangements, investors could
        build wealth and then sell assets when they hit retirement.</p></section>
        <section subscriptions-section="content"><p>The government quietly added a new provision
        to the final draft of the legislation last month.</p></section>
        </div>
        <div subscriptions-section="content-not-granted"><div>Already a subscriber?</div>
        <div>Get the full story</div></div>
        <div amp-access-hide>Sign up</div>
        </article></body></html>
        """
        let result = evaluate(
            """
            window.__lunaRevealArticle();
            JSON.stringify({
                gates: document.querySelectorAll('[subscriptions-section]').length,
                hidden: document.querySelectorAll('[amp-access-hide]').length,
                pitch: document.body.innerText.indexOf('Already a subscriber?'),
                body: document.body.innerText.indexOf('Under previous arrangements')
            })
            """,
            html: html, urlString: articleURL + "?amp") as? String

        guard let result, let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        else { return XCTFail("reveal probe returned \(String(describing: result))") }
        XCTAssertEqual(json["gates"], 0, "the gate attribute must be gone from the content")
        XCTAssertEqual(json["hidden"], 0)
        XCTAssertEqual(json["pitch"], -1, "the not-granted pitch must be removed")
        XCTAssertGreaterThanOrEqual(json["body"] ?? -1, 0, "the story must remain visible")
    }
}
