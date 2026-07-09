import Foundation
import Testing
import LunaFetch
@testable import LunaPaywallBypass

@Test func trailingDotIsLimitedToNYTimesHosts() {
    #expect(PaywallBypassRules.trailingDotURL(for: URL(string: "https://www.nytimes.com/a")!)?.host == "www.nytimes.com.")
    #expect(PaywallBypassRules.trailingDotURL(for: URL(string: "https://example.com/a")!)?.host == "example.com.")
}

@Test func resolverAcceptsLongSubscriberMarkedDirectHTML() async {
    let articleURL = URL(string: "https://www.newstatesman.com/world/asia/2026/07/in-hong-kong-i-saw-the-coming-chinese-century")!
    let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about newstatesman. ", count: 30) + "</p>"
    let html = "<html><head><title>Real newstatesman</title>"
        + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
        + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    let fetcher = PackageMockFetcher(html: html)

    let result = await ArticleResolver.resolve(
        url: articleURL, fetcher: fetcher, nonArchiveBypass: true)

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
