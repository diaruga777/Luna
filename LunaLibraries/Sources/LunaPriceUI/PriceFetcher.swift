//
//  PriceFetcher.swift
//  LunaPriceUI
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
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
public protocol PriceFetching {
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

/// Renders a page in a WKWebView and hands back the rendered `outerHTML`. A
/// seam because the render is the one part of a price fetch a test cannot
/// afford: the live conformer is `WebViewPriceHTMLRenderer`.
public protocol PriceHTMLRendering {
    func renderedHTML(for url: URL) async -> String?
}

/// Production: the real off-screen WebView.
public struct WebViewPriceHTMLRenderer: PriceHTMLRendering {
    public init() {}

    public func renderedHTML(for url: URL) async -> String? {
        await WebViewPriceRenderer.renderedHTML(for: url)
    }
}

/// Live `PriceFetching`: static extraction first (via the pure
/// `ProductPageDetector`), then a WKWebView render fallback for JS-loaded prices.
public final class PriceFetcher: PriceFetching {
    private let fetcher: HTMLFetching
    private let detector: ProductPageDetector
    /// Renders a URL in a WKWebView and returns the rendered `outerHTML`. Injected
    /// so save-time / refresh can run the real WebView while tests stay headless.
    private let renderer: any PriceHTMLRendering
    /// Hard ceiling on the WHOLE price fetch (static fetch + WebView render). Even
    /// with each stage individually bounded, this is the absolute backstop so a save
    /// can NEVER hang waiting on a price — on timeout it returns nil and the caller
    /// falls back to a normal article.
    private let overallTimeoutSeconds: UInt64

    public init(
        fetcher: HTMLFetching = ArticleFetcher(),
        detector: ProductPageDetector = ProductPageDetector(),
        renderer: any PriceHTMLRendering = WebViewPriceHTMLRenderer(),
        overallTimeoutSeconds: UInt64 = 30
    ) {
        self.fetcher = fetcher
        self.detector = detector
        self.renderer = renderer
        self.overallTimeoutSeconds = overallTimeoutSeconds
    }

    /// The backstop above is only a backstop if it can return without the work.
    /// A task group cannot: it awaits every child when its scope exits, so the
    /// sleeping leg decided what a slow answer was CALLED and never when it
    /// arrived. `TimeLimit.run` runs the resolution unstructured instead.
    public func fetchPrice(forURLString urlString: String, prefetchedHTML: String?) async -> ProductPrice? {
        await TimeLimit.run(TimeInterval(overallTimeoutSeconds)) {
            await self.resolvePrice(forURLString: urlString, prefetchedHTML: prefetchedHTML)
        } ?? nil
    }

    /// The actual resolution (static markup → WebView render). Bounded by the
    /// overall timeout in `fetchPrice`.
    private func resolvePrice(forURLString urlString: String, prefetchedHTML: String?) async -> ProductPrice? {
        // 1) Static markup (structured data → embedded JSON), no WebView.
        let staticMarkup: String?
        if let prefetchedHTML {
            staticMarkup = prefetchedHTML
        } else {
            staticMarkup = await staticHTML(for: urlString)
        }
        if let html = staticMarkup,
           let price = detector.staticPrice(urlString: urlString, html: html) {
            SaveDiagnostics.record(
                "price: static markup (\(html.count)ch) → \(price.amount) \(price.currency)",
                category: "price")
            return price
        }
        SaveDiagnostics.record(
            "price: no price in "
                + (staticMarkup.map { "\($0.count)ch of static markup" } ?? "an unfetchable page")
                + " — trying the render tier",
            category: "price")

        // 2) Rendered-DOM fallback: run the page's JS, then re-extract statically
        //    from the rendered markup (the price now lives in the DOM / app state).
        guard let url = URL(string: urlString),
              let rendered = await renderer.renderedHTML(for: url)
        else {
            SaveDiagnostics.record("price: render tier produced nothing", category: "price")
            return nil
        }
        let price = detector.staticPrice(urlString: urlString, html: rendered)
        SaveDiagnostics.record(
            "price: rendered DOM (\(rendered.count)ch) → "
                + (price.map { "\($0.amount) \($0.currency)" } ?? "still no price"),
            category: "price")
        return price
    }

    /// Fetches raw HTML for the static paths, returning nil on any failure.
    private func staticHTML(for urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        // The fetch itself is already traced at `ArticleFetcher.fetch`.
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
public enum WebViewPriceRenderer {
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

    /// How long a SEARCH-page render may take. Shorter than the price render
    /// because the fan-out is racing a whole run's budget across a dozen
    /// retailers, not resolving one product.
    private static let searchRenderTimeoutSeconds: UInt64 = 12

    /// Renders a SEARCH page and returns its markup once `readyWhen` is
    /// satisfied (or at the deadline).
    ///
    /// The price poll is the wrong readiness test for a results grid — there is
    /// no single price to wait for — so the caller supplies its own: the
    /// alternative-seller fan-out waits until the rendered DOM yields at least
    /// one product link. Target's and Walmart's search pages are JS shells whose
    /// served markup contains no product URLs at all, and this is the only way
    /// the app tier can see what a browser would have seen.
    @MainActor
    public static func renderedSearchHTML(
        for url: URL, readyWhen isReady: @escaping (String) -> Bool
    ) async -> String? {
        guard LiveNetworkPolicy.allows(url, context: "WebViewPriceRenderer.renderedSearchHTML")
        else { return nil }
        return await bounded(searchRenderTimeoutSeconds) {
            await Renderer().render(
                url: url, userAgent: deviceSafariUserAgent,
                pollIntervalSeconds: pollIntervalSeconds,
                timeoutSeconds: searchRenderTimeoutSeconds, hasPrice: isReady)
        }
    }

    /// The stated ceiling, enforced from OUTSIDE the render as well as inside it.
    ///
    /// `render` polls its own deadline between scrapes, which bounds it only for
    /// as long as each scrape returns. One does not always: `outerHTML` is a
    /// continuation over `evaluateJavaScript`, and a WebContent process that is
    /// jetsammed mid-call — the routine end of several megabyte DOMs rendering
    /// at once, which the fan-out asks for by design — leaves that continuation
    /// with nobody to resume it. `grace` is for the scrape already in flight
    /// when the deadline passes; past that the caller stops waiting and the
    /// WebView is abandoned to ARC.
    /// `render` is explicitly `@MainActor`: `TimeLimit` runs its work in an
    /// unstructured task, which inherits no isolation, and `Renderer` owns a
    /// `WKWebView`.
    private static func bounded(
        _ timeoutSeconds: UInt64, _ render: @escaping @MainActor @Sendable () async -> String?
    ) async -> String? {
        await TimeLimit.run(TimeInterval(timeoutSeconds) + renderGrace) {
            await render()
        } ?? nil
    }

    /// Slack for the in-flight DOM scrape when the render's own deadline passes.
    private static let renderGrace: TimeInterval = 3

    /// Loads `url` in a fresh off-screen WebView, lets it render, and returns its
    /// rendered HTML. Returns nil on load failure or timeout.
    @MainActor
    public static func renderedHTML(for url: URL) async -> String? {
        // The WKWebView tier is live traffic like any other, and an off-screen
        // page load is the one that would be slowest to notice in a test.
        guard LiveNetworkPolicy.allows(url, context: "WebViewPriceRenderer.renderedHTML")
        else { return nil }
        // Logged HERE and not inside `Renderer`: its work happens in WKWebView
        // navigation callbacks, which the save's task-local recorder does not
        // reach (`claudedocs/save-diagnostics.md`). This call is still on the
        // save's own task, so the boundary is where the trace can see it.
        SaveDiagnostics.record(
            "price: rendering \(SaveDiagnostics.url(url)) off-screen, "
                + "\(renderTimeoutSeconds)s ceiling",
            category: "price")
        return await bounded(renderTimeoutSeconds) {
            await Renderer().render(
                url: url, userAgent: deviceSafariUserAgent,
                pollIntervalSeconds: pollIntervalSeconds, timeoutSeconds: renderTimeoutSeconds,
                hasPrice: { html in
                    detector.staticPrice(urlString: url.absoluteString, html: html) != nil
                })
        }
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

            // ONE hard deadline bounds the ENTIRE render (navigation + price poll), so
            // a save can never hang: a page that neither loads nor shows a price exits
            // by `deadline` and the caller falls back to a normal article.
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
            webView.load(URLRequest(url: url, timeoutInterval: TimeInterval(timeoutSeconds)))

            // Wait for the navigation to finish (or fail), bounded by the SAME hard
            // deadline — not a fresh full timeout — so navigation + poll together can't
            // exceed `timeoutSeconds`.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.awaitNavigation() }
                group.addTask {
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    await self.resumeNavigation()
                }
                await group.next()
                group.cancelAll()
            }

            // Poll the rendered DOM until the price hydrates (deterministic exit), or
            // give up at the hard deadline. Re-scraping at a fixed cadence — rather than
            // sleeping a fixed window then scraping once — removes the JS-vs-sleep race
            // that made the same page sometimes yield a price and sometimes not.
            //
            // The cancellation check is not politeness. `try? await Task.sleep`
            // returns IMMEDIATELY once the task is cancelled, so without it a
            // cancelled render stops pacing and re-scrapes the DOM as fast as
            // `evaluateJavaScript` can serialize it — on the main actor, on a
            // multi-megabyte results page, for the rest of the deadline. Several
            // of those at once is how a fan-out that had already been given up
            // on kept the main thread from getting anything else done.
            var latestHTML = await outerHTML(of: webView)
            while Date() < deadline, !Task.isCancelled {
                if let html = latestHTML, hasPrice(html) { break }
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
                if Task.isCancelled { break }
                latestHTML = await outerHTML(of: webView)
            }

            webView.navigationDelegate = nil
            webView.stopLoading()
            self.webView = nil
            return latestHTML
        }

        private func awaitNavigation() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // The navigation can finish/fail before this task registers (an
                // instant provisional failure) — resume immediately then, or the
                // continuation would never fire and `render` would hang forever.
                if didResume {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
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
