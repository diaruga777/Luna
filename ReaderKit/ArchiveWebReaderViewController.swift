//
//  ArchiveWebReaderViewController.swift
//  ReaderKit
//

import UIKit
import WebKit

/// Reads a hard-paywalled / bot-blocked article (WSJ, FT, …) through its
/// **archive.today** snapshot, in a real `WKWebView` — which runs the site's JS and
/// can show the user a CAPTCHA when archive.today demands one (something a plain
/// `URLSession` fetch can't pass). The target URL is pre-filled in the path
/// (`archive.ph/newest/<url>`), so the user NEVER has to type or paste it — at most
/// they solve a CAPTCHA. Once the snapshot loads, the article is extracted off the
/// page's DOM and saved as the item's content so later opens use the in-app reader.
///
/// archive.today gates many clients behind a **Cloudflare reCAPTCHA** that, on
/// success, issues a `cf_clearance` cookie **bound to the exact User-Agent**. Two
/// things make solving actually stick (and stop the "solve → same CAPTCHA again"
/// infinite loop): a fixed real-mobile-Safari `customUserAgent` (the default
/// WKWebView UA lacks the `Safari/` token, so Cloudflare treats the post-solve
/// request as a different/automated client and re-challenges), and the persistent
/// default cookie store (so the clearance survives the reload — and later articles
/// reuse it without re-solving).
final class ArchiveWebReaderViewController: UIViewController, WKNavigationDelegate {

    private let articleURL: URL
    private let itemID: UUID?
    private let store: ReadingListStore
    private let webView: WKWebView
    private let progress = UIActivityIndicatorView(style: .medium)
    private let rateLimitView = UILabel()
    private var didExtract = false

    /// Called when the user dismisses (Done). The main app dismisses the modal;
    /// extensions use this to complete their extension request. Defaults to
    /// dismissing the presentation when nil.
    var onClose: (() -> Void)?
    /// Called once the article has been extracted and saved (the CAPTCHA was
    /// solved and a real snapshot loaded). Extensions use this to show their
    /// success checkmark and finish; the main app leaves it nil and lets the user
    /// keep reading the loaded snapshot.
    var onExtracted: (() -> Void)?
    /// Escape hatch for when archive.today keeps CAPTCHA-looping in the embedded
    /// web view: opens the same archive URL in real Safari (which may already hold
    /// a valid `cf_clearance`). Main-app-only — set by the presenter; left nil in
    /// extensions (no `UIApplication` there), where the button is hidden.
    var onOpenInBrowser: ((URL) -> Void)?

    /// archive.today rate-limits aggressively; this surfaces that to the user (who
    /// can then wait it out) rather than spinning forever.
    private static let rateLimitMessage =
        "archive.today is rate-limiting requests right now (you've archived a lot in a "
        + "short time). Wait a few minutes, then try again."

    init(articleURL: URL, itemID: UUID?, store: ReadingListStore = .shared) {
        self.articleURL = articleURL
        self.itemID = itemID
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // Persistent store so the Cloudflare `cf_clearance` cookie set on solving
        // survives the post-CAPTCHA reload AND later launches/articles.
        configuration.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        // Present as a real mobile Safari (UA with the `Safari/` token); the default
        // WKWebView UA omits it, which makes Cloudflare re-challenge after every
        // solve. Must match across all requests, so set it once here.
        self.webView.customUserAgent = ArticleFetcher.safariUserAgent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Archive"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                if let onClose = self.onClose { onClose() } else { self.dismiss(animated: true) }
            })
        if onOpenInBrowser != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "safari"),
                primaryAction: UIAction { [weak self] _ in
                    guard let self, let url = self.webView.url ?? URL(
                        string: "https://archive.ph/newest/\(self.articleURL.absoluteString)")
                    else { return }
                    self.onOpenInBrowser?(url)
                })
        }

        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        progress.hidesWhenStopped = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)

        rateLimitView.text = Self.rateLimitMessage
        rateLimitView.numberOfLines = 0
        rateLimitView.textAlignment = .center
        rateLimitView.textColor = .secondaryLabel
        rateLimitView.font = .preferredFont(forTextStyle: .callout)
        rateLimitView.isHidden = true
        rateLimitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rateLimitView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            rateLimitView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            rateLimitView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            rateLimitView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        progress.startAnimating()
        loadArchive()
    }

    private func loadArchive() {
        // The target URL lives in the PATH, so archive.today opens straight to this
        // article — the user never types it into a form.
        guard let archiveURL = URL(string: "https://archive.ph/newest/\(articleURL.absoluteString)") else {
            return
        }
        SharedDiagnosticLog.record(
            "archive: loading \(archiveURL.absoluteString) ua=\(webView.customUserAgent ?? "default")",
            category: "archive")
        webView.load(URLRequest(url: archiveURL))
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A 429 is archive.today's rate-limit; surface it so the user knows to wait.
        if let http = navigationResponse.response as? HTTPURLResponse {
            SharedDiagnosticLog.record(
                "archive: response \(http.statusCode) \(http.url?.absoluteString ?? "")", category: "archive")
            if http.statusCode == 429 { showRateLimit() }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimating()
        // Only try to extract once a real snapshot (not the landing/CAPTCHA page) has
        // loaded — gauged by how much article text the page now holds.
        webView.evaluateJavaScript("document.body ? document.body.innerText.length : 0") {
            [weak self] result, _ in
            guard let self else { return }
            let length = (result as? Int) ?? 0
            SharedDiagnosticLog.record(
                "archive: didFinish \(self.webView.url?.absoluteString ?? "") innerTextLen=\(length)",
                category: "archive")
            guard !self.didExtract, length > 1500 else { return }
            self.extractAndSave()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimating()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { progress.stopAnimating() }

    // MARK: - Extraction

    /// Pulls the article out of the loaded snapshot's DOM and saves it to the item, so
    /// future opens use the fast in-app reader. The user keeps reading the web view now.
    private func extractAndSave() {
        guard let itemID else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, let html = result as? String else { return }
            // The Cloudflare challenge page can be long enough to clear the
            // innerText gate; never mistake it for the article.
            if Self.isChallengePage(html) {
                SharedDiagnosticLog.record("archive: still on CAPTCHA challenge page", category: "archive")
                return
            }
            let content = try? ArticleExtractor().extract(html: html, baseURL: self.articleURL)
            guard let content, content.hasReadableBody, let item = self.store.item(withID: itemID) else {
                SharedDiagnosticLog.record(
                    "archive: extract not readable (bodyLen=\(content?.bodyTextLength ?? 0))",
                    category: "archive")
                return
            }
            self.didExtract = true
            _ = self.store.saveContent(content, for: item)
            SharedDiagnosticLog.record(
                "archive: extracted + saved (bodyLen=\(content.bodyTextLength))", category: "archive")
            self.onExtracted?()
        }
    }

    /// Whether the loaded HTML is archive.today's Cloudflare CAPTCHA gate rather
    /// than a real snapshot.
    private static func isChallengePage(_ html: String) -> Bool {
        html.contains("/cdn-cgi/l/chk_captcha")
            || html.contains("Why do I have to complete a CAPTCHA")
    }

    private func showRateLimit() {
        progress.stopAnimating()
        rateLimitView.isHidden = false
        view.bringSubviewToFront(rateLimitView)
    }
}
