//
//  WebArchiveCapturer.swift
//  Clip
//

import WebKit

/// Captures the fetched source page into WebKit's portable `.webarchive` format.
/// This runs only while saving a web article; opening Original later is a pure local
/// load and cannot re-fetch, re-parse, or change as the publisher page changes.
@MainActor
final class WebArchiveCapturer: NSObject, WKNavigationDelegate {
    private let html: String
    private let baseURL: URL
    private let webView = WKWebView(frame: .zero)
    private var continuation: CheckedContinuation<Data?, Never>?
    private var timeoutTask: Task<Void, Never>?

    private init(html: String, baseURL: URL) {
        self.html = html
        self.baseURL = baseURL
        super.init()
        webView.navigationDelegate = self
    }

    static func capture(html: String, baseURL: URL) async -> Data? {
        await WebArchiveCapturer(html: html, baseURL: baseURL).run()
    }

    private func run() async -> Data? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.createWebArchiveData { [weak self] result in
            self?.finish(try? result.get())
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(
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
