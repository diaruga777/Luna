//
//  SafariJSTestHarness.swift
//  LunaTests
//

import WebKit
import XCTest

/// The extension's JS sources, read from disk once per run. A plain (unisolated)
/// namespace, so it can be named from default arguments and from any test class.
enum SafariJSSource {

    /// The production content script every pill/heuristic test evaluates.
    static let content = read("LunaSafari/Resources/content.js")
    /// The generated data tables `background.js` injects BEFORE `content.js`.
    static let newsHosts = read("LunaSafari/Resources/news_hosts.generated.js")
    static let productRules = read("LunaSafari/Resources/product_rules.generated.js")
    static let platformHosts = read("LunaSafari/Resources/platform_hosts.generated.js")
    /// The document-start annoyance script.
    static let annoyances = read("LunaSafari/Resources/annoyances.js")

    /// The viewport-carrying blank page. Without the viewport meta WebKit lays
    /// fixtures out in its 980pt-wide default viewport, which scales every CSS
    /// pixel (and every `vh`) away from phone geometry.
    static let blankPage = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        </head><body style="margin:0"><p>fixture</p></body></html>
        """

    /// A file read relative to the repo root (`LunaTests/…` → repo root).
    static func read(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }
}

/// ONE `WKWebView` — and therefore ONE WebContent process — for every
/// Safari-extension JS test in the bundle.
///
/// Each of those tests used to build its own web view per assertion (~160
/// WebContent process launches across the suite), even though the expensive part
/// is the PROCESS, not the page: navigating the same web view to a new
/// `loadHTMLString` document gives a completely fresh JS global context, which is
/// all the isolation these tests need.
///
/// So the web view is created once, lazily, and kept for the whole run; every
/// test drives it through an instance of this harness bound to the running
/// `XCTestCase` (so failures and expectation waits are attributed correctly):
///
/// ```swift
/// private lazy var js = SafariJSTestHarness(self)
/// …
/// js.load(html: html, urlString: url, scripts: [SafariJSTestHarness.contentScript])
/// XCTAssertTrue(js.bool("window.__lunaIsArticlePage()"))
/// ```
///
/// If the WebContent process ever dies, the shared view is dropped and the next
/// `load` builds a new one, so one crashed page can't cascade through the suite.
@MainActor
final class SafariJSTestHarness {

    // MARK: - Script sources

    static var contentScript: String { SafariJSSource.content }
    static var newsHosts: String { SafariJSSource.newsHosts }
    static var productRules: String { SafariJSSource.productRules }
    static var platformHosts: String { SafariJSSource.platformHosts }
    static var annoyances: String { SafariJSSource.annoyances }
    static var blankPage: String { SafariJSSource.blankPage }

    static func source(_ relativePath: String) -> String { SafariJSSource.read(relativePath) }

    // MARK: - The shared web view

    private static var sharedWebView: WKWebView?
    private static let navigation = Navigation()

    private let test: XCTestCase

    init(_ test: XCTestCase) { self.test = test }

    private var webView: WKWebView {
        // A crashed WebContent process must not cascade through the rest of the
        // suite: drop the dead view and build a fresh one.
        if Self.navigation.didTerminate {
            Self.navigation.didTerminate = false
            Self.sharedWebView = nil
        }
        if let existing = Self.sharedWebView { return existing }
        let created = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        created.navigationDelegate = Self.navigation
        Self.sharedWebView = created
        return created
    }

    // MARK: - Driving it

    /// Navigates the shared web view to `html` at `urlString` (a brand-new document,
    /// so the JS context starts clean) and evaluates `scripts` in order — the same
    /// injection order `background.js` uses in the real extension.
    func load(
        html: String = SafariJSSource.blankPage,
        urlString: String,
        scripts: [String] = [SafariJSSource.content]
    ) {
        Self.navigation.appSchemeURL = nil
        Self.navigation.onAppSchemeNavigation = nil

        let loaded = test.expectation(description: "loaded \(urlString)")
        Self.navigation.onFinish = { loaded.fulfill() }
        webView.loadHTMLString(html, baseURL: URL(string: urlString))
        test.wait(for: [loaded], timeout: 10)

        for script in scripts {
            XCTAssertFalse(
                script.isEmpty,
                "a LunaSafari script source is missing from disk — check the path "
                    + "relative to #filePath, and regenerate the *.generated.js tables")
            evaluate(script)
        }
    }

    @discardableResult
    func evaluate(_ script: String) -> Any? {
        let finished = test.expectation(description: "evaluated JS")
        var outcome: Any?
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                XCTFail("JS failed to evaluate: \(error)\n\(script.prefix(200))")
            }
            outcome = result
            finished.fulfill()
        }
        test.wait(for: [finished], timeout: 10)
        return outcome
    }

    func bool(_ script: String) -> Bool { evaluate(script) as? Bool ?? false }

    func string(_ script: String) -> String? { evaluate(script) as? String }

    func number(_ script: String) -> Double {
        (evaluate(script) as? NSNumber)?.doubleValue ?? .nan
    }

    /// A JS string literal for `value` (JSON-quoted, so interpolation stays honest).
    static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: - App-scheme navigation (the setup-celebration hand-off)

    /// Runs `trigger` and waits for the page to attempt a `luna…://` navigation,
    /// which the harness captures and cancels rather than letting it leave the
    /// fixture. Returns the URL the page tried to open.
    func awaitAppSchemeNavigation(triggeredBy trigger: () -> Void) -> String? {
        let navigated = test.expectation(description: "app-scheme navigation attempted")
        Self.navigation.onAppSchemeNavigation = { navigated.fulfill() }
        trigger()
        test.wait(for: [navigated], timeout: 10)
        return Self.navigation.appSchemeURL
    }

    // MARK: - Navigation delegate

    private final class Navigation: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        var appSchemeURL: String?
        var onAppSchemeNavigation: (() -> Void)?
        /// Read (and cleared) by the harness before it hands out the web view.
        var didTerminate = false

        private func finish() {
            let callback = onFinish
            onFinish = nil
            callback?()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) { finish() }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme ?? ""
            guard scheme.hasPrefix("luna") else {
                decisionHandler(.allow)
                return
            }
            appSchemeURL = navigationAction.request.url?.absoluteString
            decisionHandler(.cancel)
            let callback = onAppSchemeNavigation
            onAppSchemeNavigation = nil
            callback?()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            didTerminate = true
            finish()
        }
    }
}
