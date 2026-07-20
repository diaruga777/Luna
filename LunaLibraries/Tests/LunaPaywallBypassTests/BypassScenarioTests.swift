import Foundation
import Testing
import LunaFetch
@testable import LunaPaywallBypass

@Test func knownPaywallPublisherCommerceMarkupRetainsDirectUnlockPlan() {
    let url = URL(string:
        "https://www.newyorker.com/culture/the-weekend-essay/the-voice-of-google"
    )!
    let html = """
    <html><head>
      <title>The Voice of Google | The New Yorker</title>
      <meta property="og:type" content="article">
      <meta property="product:price:amount" content="120.00">
      <meta property="product:price:currency" content="USD">
    </head><body>
      <article><h1>The Voice of Google</h1><p>Subscriber preview.</p></article>
      <button>Add to cart</button><div>Star Rating: 5 out of 5</div>
    </body></html>
    """

    #expect(BypassGate.decision(for: url, html: html, extracted: nil)
        == .attempt(.hardPaywallHostUnreadable))
    let plan = BypassPlan.make(for: url, directHTML: html)
    #expect(plan.webPreStages == [.directUnlock])
    #expect(plan.allowsArchiveToday)

    let unknownURL = URL(string: "https://publisher.example/story")!
    #expect(BypassGate.decision(for: unknownURL, html: html, extracted: nil)
        == .block(.productPage), "Only deterministic news classification overrides heuristics")
}

@Test func resolverAcceptsLongSubscriberMarkedDirectHTML() async {
    let articleURL = URL(string: "https://www.newstatesman.com/world/asia/2026/07/in-hong-kong-i-saw-the-coming-chinese-century")!
    let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about newstatesman. ", count: 30) + "</p>"
    let html = "<html><head><title>Real newstatesman</title>"
        + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
        + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    let fetcher = PackageMockFetcher(html: html)

    let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)

    guard case let .readable(content, _) = result else {
        Issue.record("Expected readable article, got \(result)")
        return
    }
    #expect(content.bodyTextLength > 2500)
    #expect(fetcher.directFetches == 1)
}

private final class PackageMockFetcher: HTMLFetching {
    let html: String
    var directFetches = 0

    init(html: String) {
        self.html = html
    }

    func fetchHTML(from url: URL) async throws -> String {
        directFetches += 1
        return html
    }

    func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String {
        html
    }

    func fetchHTML(from url: URL, referer: String) async throws -> String {
        html
    }

    func fetchHTMLWithoutCookies(from url: URL) async throws -> String {
        html
    }

    func fetchWaybackRawHTML(for url: URL) async throws -> String {
        html
    }

    func fetchJinaReader(for url: URL) async throws -> String {
        html
    }
}
