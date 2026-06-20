//
//  PriceFetcher.swift
//  Clip
//

import Foundation
import UIKit
import WebKit

/// Fetches the *current* price for a product URL. The price is the load-bearing
/// value of price tracking, so a tracker is only ever created (and only ever
/// refreshed) from a real fetched price — there is no pending/unknown state.
///
/// Reused by BOTH save-time (gating tracker creation on a real price) and the
/// background refresher (re-fetching the live price every cycle), so the exact
/// same resolution strategy — including the WKWebView fallback — runs in both.
protocol PriceFetching {
    /// Resolves the current price for `urlString`, or nil if no price can be found
    /// by any method.
    ///
    /// Resolution order:
    /// 1. **Static markup** (fast, no WebView): structured data (JSON-LD / OG /
    ///    microdata) then embedded app-state JSON (`__NEXT_DATA__` / `window.__…`).
    ///    Uses `prefetchedHTML` when the caller already fetched the page; otherwise
    ///    fetches it.
    /// 2. **Rendered DOM** (WKWebView fallback): if the static paths find nothing,
    ///    the page is loaded in a WebView so JS can run, and the same extractor is
    ///    applied to the rendered `outerHTML` — recovering prices that only exist
    ///    after client-side rendering.
    func fetchPrice(forURLString urlString: String, prefetchedHTML: String?) async -> ProductPrice?
}

/// Live `PriceFetching`: static extraction first (via the pure
/// `ProductPageDetector`), then a WKWebView render fallback for JS-loaded prices.
final class PriceFetcher: PriceFetching {
    private let fetcher: HTMLFetching
    private let detector: ProductPageDetector
    /// Renders a URL in a WKWebView and returns the rendered `outerHTML`. Injected
    /// so save-time / refresh can run the real WebView while tests stay headless.
    private let renderHTML: (URL) async -> String?

    init(
        fetcher: HTMLFetching = ArticleFetcher(),
        detector: ProductPageDetector = ProductPageDetector(),
        renderHTML: ((URL) async -> String?)? = nil
    ) {
        self.fetcher = fetcher
        self.detector = detector
        self.renderHTML = renderHTML ?? { url in await WebViewPriceRenderer.renderedHTML(for: url) }
    }

    func fetchPrice(forURLString urlString: String, prefetchedHTML: String?) async -> ProductPrice? {
        // 1) Static markup (structured data → embedded JSON), no WebView.
        let staticMarkup: String?
        if let prefetchedHTML {
            staticMarkup = prefetchedHTML
        } else {
            staticMarkup = await staticHTML(for: urlString)
        }
        if let html = staticMarkup,
           let price = detector.staticPrice(urlString: urlString, html: html) {
            return price
        }

        // 2) Rendered-DOM fallback: run the page's JS, then re-extract statically
        //    from the rendered markup (the price now lives in the DOM / app state).
        guard let url = URL(string: urlString), let rendered = await renderHTML(url) else {
            return nil
        }
        return detector.staticPrice(urlString: urlString, html: rendered)
    }

    /// Fetches raw HTML for the static paths, returning nil on any failure.
    private func staticHTML(for urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return try? await fetcher.fetchHTML(from: url)
    }
}

/// Renders a URL in an off-screen `WKWebView` so client-side JS runs, then returns
/// the fully rendered `outerHTML`. Used as the price-fetch fallback for retailers
/// whose price only exists after rendering. Runs on the main actor (WebKit
/// requirement); the WebView is created and torn down per call so nothing is held
/// in memory between fetches.
///
/// The wait for the price to hydrate is a **deterministic poll**, not a fixed sleep:
/// a blind settle window races the page's JS, so the same page can return its price
/// on one render and time out (→ no price → article) on the next, depending on how
/// fast the network/JS happened to be. Instead, after the initial navigation we poll
/// the rendered DOM at a fixed cadence and return as soon as a price is extractable
/// (or when the hard timeout is hit), so a given page yields the same result every run.
enum WebViewPriceRenderer {
    /// How often the rendered DOM is re-scraped while waiting for the price to hydrate.
    private static let pollIntervalSeconds: Double = 0.5

    /// Hard ceiling so a never-finishing page can't hang a background refresh, and so
    /// a page that genuinely never shows a price fails consistently (→ article).
    private static let renderTimeoutSeconds: UInt64 = 20

    /// Detector used to decide when the rendered DOM has a usable price yet, so the
    /// poll returns deterministically the moment the price is present.
    private static let detector = ProductPageDetector()

    /// Mobile-Safari UA so retailers serve their normal (priced) page, matching the
    /// device's iOS version (a stale UA reads as an automated client to some bot
    /// checks).
    private static var deviceSafariUserAgent: String {
        let version = UIDevice.current.systemVersion
        let osToken = version.replacingOccurrences(of: ".", with: "_")
        let major = version.split(separator: ".").first.map(String.init) ?? version
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    /// Loads `url` in a fresh off-screen WebView, lets it render, and returns its
    /// rendered HTML. Returns nil on load failure or timeout.
    @MainActor
    static func renderedHTML(for url: URL) async -> String? {
        let renderer = Renderer()
        return await renderer.render(
            url: url, userAgent: deviceSafariUserAgent,
            pollIntervalSeconds: pollIntervalSeconds, timeoutSeconds: renderTimeoutSeconds,
            hasPrice: { html in detector.staticPrice(urlString: url.absoluteString, html: html) != nil })
    }

    /// One-shot off-screen WebView render. Owns its WebView for the duration of a
    /// single `render` call so nothing leaks between fetches.
    @MainActor
    private final class Renderer: NSObject, WKNavigationDelegate {
        private var webView: WKWebView?
        private var continuation: CheckedContinuation<Void, Never>?
        private var didResume = false

        /// Renders `url` and polls the DOM until `hasPrice` is satisfied or the hard
        /// timeout elapses. Returns the rendered HTML from the first poll where the
        /// price is present (deterministic), else the final DOM at timeout.
        func render(
            url: URL, userAgent: String, pollIntervalSeconds: Double, timeoutSeconds: UInt64,
            hasPrice: @escaping (String) -> Bool
        ) async -> String? {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                    configuration: configuration)
            webView.customUserAgent = userAgent
            webView.navigationDelegate = self
            self.webView = webView

            webView.load(URLRequest(url: url, timeoutInterval: TimeInterval(timeoutSeconds)))

            // Wait for the navigation to finish (or fail), bounded by a hard timeout.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.awaitNavigation() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                    await self.resumeNavigation()
                }
                await group.next()
                group.cancelAll()
            }

            // Poll the rendered DOM until the price hydrates (deterministic exit), or
            // give up at the hard timeout. Re-scraping at a fixed cadence — rather than
            // sleeping a fixed window then scraping once — removes the JS-vs-sleep race
            // that made the same page sometimes yield a price and sometimes not.
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            var latestHTML = await outerHTML(of: webView)
            while Date() < deadline {
                if let html = latestHTML, hasPrice(html) { break }
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
                latestHTML = await outerHTML(of: webView)
            }

            webView.navigationDelegate = nil
            webView.stopLoading()
            self.webView = nil
            return latestHTML
        }

        private func awaitNavigation() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.continuation = continuation
            }
        }

        private func resumeNavigation() {
            guard !didResume else { return }
            didResume = true
            continuation?.resume()
            continuation = nil
        }

        private func outerHTML(of webView: WKWebView) async -> String? {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
                    continuation.resume(returning: result as? String)
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.resumeNavigation() }
        }

        nonisolated func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            Task { @MainActor in self.resumeNavigation() }
        }

        nonisolated func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            Task { @MainActor in self.resumeNavigation() }
        }
    }
}
