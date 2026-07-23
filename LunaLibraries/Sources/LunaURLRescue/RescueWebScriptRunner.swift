//
//  RescueWebScriptRunner.swift
//  LunaURLRescue
//

import Foundation
import LunaFetch
#if canImport(WebKit)
import WebKit
#endif

/// Runs an LLM-supplied script against a loaded page in an off-screen WKWebView.
/// The seam is a protocol so the engine is testable with a fake (WebKit isn't
/// available/meaningful in the pure-package test target).
public protocol RescueScriptRunning: AnyObject {
    /// Loads `script.pageURL` (applying `script.headers`), waits for navigation
    /// to settle, then runs the wrapped script and returns its string result.
    /// Returns nil on load failure, timeout, or a non-string / empty result.
    func run(_ script: RescueScript) async -> String?
}

#if canImport(WebKit)
/// The real runner. Modeled on `WebViewPriceRenderer.Renderer`: fresh WKWebView,
/// non-persistent data store (NO app cookies — the real defense against a
/// malicious script exfiltrating session state), one hard deadline over
/// navigation + evaluation, teardown after.
public final class RescueWebScriptRunner: RescueScriptRunning {
    public init() {}

    /// Wraps the model JS so it can never be eval'd raw and always yields a
    /// string (or "" which we treat as no-result).
    static func wrap(_ js: String) -> String {
        """
        (function(){ try { var r = (function(){ \(js) })();
          return (typeof r === "string" && r.length) ? r : ""; }
          catch (e) { return ""; } })()
        """
    }

    public func run(_ script: RescueScript) async -> String? {
        await Runner().run(script)
    }

    @MainActor
    private final class Runner: NSObject, WKNavigationDelegate {
        private var webView: WKWebView?
        private var continuation: CheckedContinuation<Void, Never>?
        private var didResume = false

        private static let timeoutSeconds: UInt64 = 20

        func run(_ script: RescueScript) async -> String? {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                    configuration: configuration)
            webView.customUserAgent = script.headers.userAgent ?? ArticleFetcher.safariUserAgent
            webView.navigationDelegate = self
            self.webView = webView

            let deadline = Date().addingTimeInterval(TimeInterval(Self.timeoutSeconds))
            var request = URLRequest(url: script.pageURL, timeoutInterval: TimeInterval(Self.timeoutSeconds))
            // WKWebView honors custom header fields on the initial load request
            // (they may be dropped across cross-origin redirects — best-effort).
            if let referer = script.headers.referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
            if let lang = script.headers.acceptLanguage { request.setValue(lang, forHTTPHeaderField: "Accept-Language") }
            if let xff = script.headers.xForwardedFor { request.setValue(xff, forHTTPHeaderField: "X-Forwarded-For") }
            webView.load(request)

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

            // Poll the wrapped script until it returns a non-empty string or the
            // deadline — tolerates client-side hydration, like the price renderer.
            let wrapped = RescueWebScriptRunner.wrap(script.javascript)
            var result: String?
            while Date() < deadline {
                result = await evaluate(wrapped, in: webView)
                if let result, !result.isEmpty { break }
                try? await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
            }

            webView.navigationDelegate = nil
            webView.stopLoading()
            self.webView = nil

            guard let result, !result.isEmpty, result.utf8.count <= ArticleFetcher.maxBytes else { return nil }
            return result
        }

        private func awaitNavigation() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if didResume { continuation.resume() } else { self.continuation = continuation }
            }
        }

        private func resumeNavigation() {
            guard !didResume else { return }
            didResume = true
            continuation?.resume()
            continuation = nil
        }

        private func evaluate(_ js: String, in webView: WKWebView) async -> String? {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                webView.evaluateJavaScript(js) { result, _ in
                    continuation.resume(returning: result as? String)
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.resumeNavigation() }
        }
        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in self.resumeNavigation() }
        }
        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in self.resumeNavigation() }
        }
    }
}
#else
/// Non-WebKit platforms (the pure-package macOS test build): a runner that can
/// never execute JS.
public final class RescueWebScriptRunner: RescueScriptRunning {
    public init() {}
    static func wrap(_ js: String) -> String {
        "(function(){ try { var r = (function(){ \(js) })();\n  return (typeof r === \"string\" && r.length) ? r : \"\"; }\n  catch (e) { return \"\"; } })()"
    }
    public func run(_ script: RescueScript) async -> String? { nil }
}
#endif
