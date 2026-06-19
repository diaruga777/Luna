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
    /// Non-blocking banner host for `rateLimitView` — shown OVER the web view (not
    /// instead of it) so the user can still attempt the CAPTCHA.
    private let rateLimitBanner = UIView()
    private var didExtract = false
    /// Set synchronously the moment we decide to extract, so the several
    /// `didFinish` events archive.today fires (sub-frames, JS reloads) can't each
    /// kick off a parallel extraction → double `saveContent` / double `onExtracted`.
    private var isExtracting = false
    /// Number of `429` challenge responses seen; once it loops past `loopThreshold`
    /// we stop letting the user re-solve a CAPTCHA that can't pass and show guidance.
    private var challengeCount = 0
    private static let loopThreshold = 3

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

    /// archive.today rate-limits aggressively (HTTP 429) and, once it does, won't
    /// honor CAPTCHA solves until the throttle clears — so surface actionable
    /// remedies rather than letting the user re-solve a CAPTCHA that can't pass.
    private static let rateLimitMessage =
        "archive.today is rate-limiting your network right now, so solving the CAPTCHA "
        + "won't get through.\n\nTry one of these, then reopen:\n"
        + "•  Wait ~30 minutes\n"
        + "•  Switch networks or turn on a VPN\n"
        + "•  Tap the Safari button (top right), then disable Safari's content/ad "
        + "blockers for archive.today"

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
        // Present as real mobile Safari MATCHING THIS DEVICE's iOS version. A
        // hardcoded/stale UA (e.g. claiming iOS 26 on an iOS 27 device) is a UA/OS
        // mismatch that Cloudflare's bot check flags → endless re-challenge, where
        // real Safari (consistent UA) passes.
        self.webView.customUserAgent = Self.deviceSafariUserAgent
        super.init(nibName: nil, bundle: nil)
    }

    /// A mobile-Safari User-Agent built from the running iOS version so it never
    /// mismatches the device (which would trip archive.today's Cloudflare check).
    private static var deviceSafariUserAgent: String {
        let version = UIDevice.current.systemVersion                       // e.g. "27.0"
        let osToken = version.replacingOccurrences(of: ".", with: "_")     // "27_0"
        let major = version.split(separator: ".").first.map(String.init) ?? version
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osToken) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
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
                primaryAction: UIAction { [weak self] _ in self?.openInBrowser() })
        }

        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        progress.hidesWhenStopped = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)

        rateLimitView.text = Self.rateLimitMessage
        rateLimitView.numberOfLines = 0
        rateLimitView.textAlignment = .natural
        rateLimitView.textColor = .label
        rateLimitView.font = .preferredFont(forTextStyle: .callout)

        var safariConfig = UIButton.Configuration.borderedProminent()
        safariConfig.title = "Open in Safari"
        safariConfig.image = UIImage(systemName: "safari")
        safariConfig.imagePadding = 6
        safariConfig.cornerStyle = .large
        let safariButton = UIButton(configuration: safariConfig)
        safariButton.addAction(UIAction { [weak self] _ in self?.openInBrowser() }, for: .touchUpInside)
        // No Safari handoff in the extensions (no UIApplication there).
        safariButton.isHidden = (onOpenInBrowser == nil)

        let bannerStack = UIStackView(arrangedSubviews: [rateLimitView, safariButton])
        bannerStack.axis = .vertical
        bannerStack.spacing = 12
        bannerStack.translatesAutoresizingMaskIntoConstraints = false

        rateLimitBanner.backgroundColor = .secondarySystemBackground
        rateLimitBanner.layer.cornerRadius = 12
        rateLimitBanner.layer.cornerCurve = .continuous
        rateLimitBanner.isHidden = true
        rateLimitBanner.translatesAutoresizingMaskIntoConstraints = false
        rateLimitBanner.addSubview(bannerStack)
        view.addSubview(rateLimitBanner)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            // A non-blocking banner pinned to the top — the web view (and CAPTCHA)
            // stays visible and interactive beneath it.
            rateLimitBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            rateLimitBanner.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            rateLimitBanner.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            bannerStack.topAnchor.constraint(equalTo: rateLimitBanner.topAnchor, constant: 12),
            bannerStack.bottomAnchor.constraint(equalTo: rateLimitBanner.bottomAnchor, constant: -12),
            bannerStack.leadingAnchor.constraint(equalTo: rateLimitBanner.leadingAnchor, constant: 14),
            bannerStack.trailingAnchor.constraint(equalTo: rateLimitBanner.trailingAnchor, constant: -14),
        ])

        progress.startAnimating()
        loadArchive()
    }

    private func loadArchive() {
        guard let archiveURL = Self.archiveURL(for: articleURL) else { return }
        SharedDiagnosticLog.record(
            "archive: loading \(archiveURL.absoluteString) ua=\(webView.customUserAgent ?? "default")",
            category: "archive")
        webView.load(URLRequest(url: archiveURL))
    }

    /// The archive.today URL to open. When the saved URL is ALREADY an archive
    /// snapshot, load that exact snapshot (the user got it from a working Safari
    /// session). Otherwise open `archive.is/newest/<canonical>` — archive.is is the
    /// domain that reliably clears its Cloudflare gate in Safari, and the target
    /// lives in the PATH so the user never types it into a form.
    static func archiveURL(for articleURL: URL) -> URL? {
        if ArticleFetcher.isArchiveTodayURL(articleURL) { return articleURL }
        let target = ArticleFetcher.canonicalForArchiving(articleURL).absoluteString
        guard let url = URL(string: "https://archive.is/newest/\(target)"),
              ArticleFetcher.isArchiveTodayURL(url)   // reject a smuggled non-archive host
        else { return nil }
        return url
    }

    /// Opens the archive in real Safari (the proven-working path when the embedded
    /// web view can't pass the CAPTCHA). Uses the currently-loaded URL when present.
    private func openInBrowser() {
        guard let url = webView.url ?? Self.archiveURL(for: articleURL) else { return }
        onOpenInBrowser?(url)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Logs WHO drives each main-frame navigation (user tap vs. the challenge
        // page reloading itself), so a future loop log is unambiguous.
        if navigationAction.targetFrame?.isMainFrame ?? true {
            SharedDiagnosticLog.record(
                "archive: navAction type=\(navigationAction.navigationType.rawValue) "
                + "\(navigationAction.request.url?.absoluteString ?? "")", category: "archive")
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A 429 is archive.today's rate-limit. The first one still carries a CAPTCHA
        // that MIGHT be solvable, so let the user try it; only once it has looped
        // (repeated 429s) do we conclude solving won't pass and show the guidance.
        if let http = navigationResponse.response as? HTTPURLResponse {
            SharedDiagnosticLog.record(
                "archive: response \(http.statusCode) \(http.url?.absoluteString ?? "")", category: "archive")
            if http.statusCode == 429 {
                challengeCount += 1
                if challengeCount >= Self.loopThreshold { showRateLimit() }
            }
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
            // `evaluateJavaScript` callbacks run serially on the main queue, so this
            // check-and-set is atomic against other `didFinish` events.
            guard !self.didExtract, !self.isExtracting, length > 1500 else { return }
            self.isExtracting = true
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
        guard let itemID else { isExtracting = false; return }
        let baseURL = articleURL
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self else { return }
            guard let html = result as? String else { self.isExtracting = false; return }
            // The Cloudflare challenge page can be long enough to clear the
            // innerText gate; never mistake it for the article.
            if Self.isChallengePage(html) {
                SharedDiagnosticLog.record("archive: still on CAPTCHA challenge page", category: "archive")
                self.isExtracting = false
                return
            }
            // Parse the (potentially large) snapshot DOM OFF the main thread; only
            // the store write + callback return to main.
            Task.detached(priority: .utility) { [weak self] in
                let content = try? ArticleExtractor().extract(html: html, baseURL: baseURL)
                await MainActor.run {
                    guard let self else { return }
                    guard let content, content.hasReadableBody,
                          let item = self.store.item(withID: itemID) else {
                        SharedDiagnosticLog.record(
                            "archive: extract not readable (bodyLen=\(content?.bodyTextLength ?? 0))",
                            category: "archive")
                        self.isExtracting = false
                        return
                    }
                    self.didExtract = true
                    _ = self.store.saveContent(content, for: item)
                    SharedDiagnosticLog.record(
                        "archive: extracted + saved (bodyLen=\(content.bodyTextLength))", category: "archive")
                    self.onExtracted?()
                }
            }
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
        // Show the guidance as a non-blocking banner — DON'T hide the web view, so
        // the user can keep trying to solve the CAPTCHA (hiding it stranded them).
        rateLimitBanner.isHidden = false
        view.bringSubviewToFront(rateLimitBanner)
    }
}
