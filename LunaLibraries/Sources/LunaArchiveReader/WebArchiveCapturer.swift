//
//  WebArchiveCapturer.swift
//  Luna
//

import WebKit

/// Captures a web page into WebKit's portable `.webarchive` format. Opening
/// "Original" later is a pure local load and cannot re-fetch or change as the
/// publisher page does.
///
/// Prefer `capture(url:)`: loading the live URL lets WebKit fetch every subresource
/// (CSS, images, fonts) exactly as a browser would, so the archive renders like the
/// real page. `capture(html:baseURL:)` remains as an offline fallback, but a static
/// HTML string often archives incompletely (lazy/JS-loaded resources are missing).
@MainActor
public final class WebArchiveCapturer: NSObject, WKNavigationDelegate {
    private let html: String?
    private let url: URL?
    private let baseURL: URL
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Data?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var captured = false

    private init(html: String?, url: URL?, baseURL: URL) {
        self.html = html
        self.url = url
        self.baseURL = baseURL
        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 1024),
            configuration: SavedArchiveWebConfiguration.make(for: baseURL))
        super.init()
        webView.navigationDelegate = self
    }

    /// Archive the live page at `url` — the high-fidelity path.
    public static func capture(url: URL) async -> Data? {
        await WebArchiveCapturer(html: nil, url: url, baseURL: url).run()
    }

    /// Archive a pre-fetched HTML string (offline fallback; lower fidelity).
    public static func capture(html: String, baseURL: URL) async -> Data? {
        await WebArchiveCapturer(html: html, url: nil, baseURL: baseURL).run()
    }

    private func run() async -> Data? {
        await SavedArchiveWebConfiguration.prepare(webView.configuration, for: baseURL)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
            if let url {
                webView.load(URLRequest(url: url))
            } else if let html {
                webView.loadHTMLString(html, baseURL: baseURL)
            } else {
                finish(nil)
            }
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let late subresources, fonts, injected CSS, and lazy layout settle before
        // archiving. A fixed first-paint delay repeatedly captured complex publisher
        // pages before their style system had reached a stable layout.
        guard !captured else { return }
        captured = true
        Task { [weak self] in
            guard let self, self.continuation != nil else { return }
            await self.waitForStableLayout()
            guard self.continuation != nil else { return }
            self.webView.createWebArchiveData { [weak self] result in
                let rawData = try? result.get()
                // Preserve the rendered DOM/CSS but never persist publisher code
                // that can hydrate a paywall again when the archive is replayed.
                let data = rawData.flatMap(WebArchiveSanitizer.sanitized)
                // Treat a suspiciously tiny archive as a failure (blank/empty page).
                self?.finish((data?.count ?? 0) > 1024 ? data : nil)
            }
        }
    }

    /// The settle loop's pacing. Only tests write these: capturing a fixture
    /// page is otherwise several real seconds of waiting for a layout that
    /// settled on the first sample. The SHAPE of the loop — a first turn, then
    /// three identical signatures, then a cap — is what the tests exercise, so
    /// shrinking the intervals costs no coverage.
    static var settleFirstTurn: Duration = .milliseconds(500)
    static var settlePollInterval: Duration = .milliseconds(250)

    private func waitForStableLayout() async {
        // Always give post-load work one turn before sampling. Then require three
        // identical signatures, capped at four seconds so animation/ad churn cannot
        // consume the whole capture timeout.
        try? await Task.sleep(for: Self.settleFirstTurn)
        var previous: String?
        var stableSamples = 0
        for _ in 0..<14 {
            guard continuation != nil else { return }
            let signature = try? await webView.evaluateJavaScript("""
            (function () {
              var body = document.body;
              if (!body) { return 'no-body'; }
              var fonts = document.fonts ? document.fonts.status : 'unsupported';
              return [
                document.readyState,
                fonts,
                document.styleSheets.length,
                body.innerText.length,
                body.scrollHeight,
                document.documentElement.scrollHeight
              ].join('|');
            })()
            """) as? String
            if let signature, signature == previous {
                stableSamples += 1
                if stableSamples >= 3 { return }
            } else {
                previous = signature
                stableSamples = 0
            }
            try? await Task.sleep(for: Self.settlePollInterval)
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { finish(nil) }

    private func finish(_ data: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: data)
    }
}
