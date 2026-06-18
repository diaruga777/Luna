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
        self.webView = WKWebView(frame: .zero, configuration: configuration)
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
        webView.load(URLRequest(url: archiveURL))
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A 429 is archive.today's rate-limit; surface it so the user knows to wait.
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode == 429 {
            showRateLimit()
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimating()
        // Only try to extract once a real snapshot (not the landing/CAPTCHA page) has
        // loaded — gauged by how much article text the page now holds.
        webView.evaluateJavaScript("document.body ? document.body.innerText.length : 0") {
            [weak self] result, _ in
            guard let self, !self.didExtract,
                  let length = result as? Int, length > 1500 else { return }
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
            guard let content = try? ArticleExtractor().extract(html: html, baseURL: self.articleURL),
                  content.blocks.reduce(0, { $0 + $1.text.count }) >= 600,
                  let item = self.store.item(withID: itemID) else { return }
            self.didExtract = true
            _ = self.store.saveContent(content, for: item)
            self.onExtracted?()
        }
    }

    private func showRateLimit() {
        progress.stopAnimating()
        rateLimitView.isHidden = false
        view.bringSubviewToFront(rateLimitView)
    }
}
