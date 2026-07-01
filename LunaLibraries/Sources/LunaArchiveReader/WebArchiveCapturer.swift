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
    private let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    private var continuation: CheckedContinuation<Data?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var captured = false

    private init(html: String?, url: URL?, baseURL: URL) {
        self.html = html
        self.url = url
        self.baseURL = baseURL
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
        await withCheckedContinuation { continuation in
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
        // Let late subresources (lazy images, async CSS) settle before archiving, so
        // the capture isn't an incomplete first-paint snapshot.
        guard !captured else { return }
        captured = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.continuation != nil else { return }
            self.webView.createWebArchiveData { [weak self] result in
                let data = try? result.get()
                // Treat a suspiciously tiny archive as a failure (blank/empty page).
                self?.finish((data?.count ?? 0) > 1024 ? data : nil)
            }
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
