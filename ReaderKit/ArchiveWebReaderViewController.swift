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
    /// An opaque, themed cover (spinner) shown OVER the web view to hide the raw
    /// archive.today navigation (home page, form fill/submit, snapshot load). It's
    /// removed only while a CAPTCHA is up — the one moment the user must see and
    /// touch the page. The web view stays un-hidden and full-size beneath it
    /// (covered, not hidden — so iOS never throttles its JS/navigation), which is
    /// what keeps the automated flow running while it's visually concealed.
    private let loadingOverlay = UIView()
    private let overlaySpinner = UIActivityIndicatorView(style: .large)
    private let overlayLabel = UILabel()
    private var didExtract = false
    /// Set synchronously the moment we decide to extract, so the several
    /// `didFinish` events archive.today fires (sub-frames, JS reloads) can't each
    /// kick off a parallel extraction → double `saveContent` / double `onExtracted`.
    private var isExtracting = false
    /// Number of `429` challenge responses seen; once it loops past `loopThreshold`
    /// we stop letting the user re-solve a CAPTCHA that can't pass and show guidance.
    private var challengeCount = 0
    private static let loopThreshold = 3
    /// We load the archive.today HOMEPAGE first (clearance + the search form), then
    /// reach the snapshot the way the site itself does — typing the URL into the
    /// homepage's `input[name=url]` box and submitting the form — rather than the
    /// `…/newest/<url>` deep link, which triggers archive.today's self-reloading
    /// challenge loop. True once we've acted on the cleared homepage (once).
    private var didLeaveHomepage = false
    /// Guards a one-shot recovery from archive.today's "Invalid interception ID"
    /// error (a submit whose capture session went stale) — we re-submit once.
    private var didRecoverFromError = false
    /// Consecutive poll ticks where the opaque overlay is covering the page without
    /// progress; past `stallPollLimit` we reveal the page so the user is never
    /// stranded on a permanent "Unlocking…" screen (e.g. a homepage whose submit
    /// token never appears). Reset whenever the overlay is down (challenge/revealed).
    private var coveredPollCount = 0
    private static let stallPollLimit = 45   // ≈ 58s at the 1.3s poll interval
    /// Once we surface the rate-limit / stall guidance we stop re-covering the page,
    /// so the overlay can't slam back over a CAPTCHA or the guidance banner.
    private var didRevealForManualMode = false
    /// Polls the loaded page's stage every ~1.3s. A timer (not just `didFinish`)
    /// because clearing the CAPTCHA is often an in-page transition that fires no
    /// navigation-finished callback — so we'd otherwise never notice the homepage
    /// became ready.
    private var pollTimer: Timer?
    /// The specific newest-snapshot URL resolved via the Memento TimeMap (a clean
    /// read endpoint), used in preference to the loop-prone `…/newest/<url>`
    /// redirect once the homepage warm-up clears the gate. Nil → fall back to
    /// `/newest/`.
    private var resolvedSnapshotURL: URL?

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
        // Best-effort masking of the JS signals Cloudflare cross-references against
        // the Safari UA we present (see init below). We can't BE the Safari process
        // like SFSafariViewController, but defining `navigator.standalone` — present
        // in real Safari, `undefined` in a bare WKWebView — removes the single most
        // reliable "this is an embedded web view" tell. No `WKScriptMessageHandler`
        // is registered, so `window.webkit.messageHandlers` also stays absent.
        let contentController = WKUserContentController()
        contentController.addUserScript(Self.safariImpersonationScript())
        configuration.userContentController = contentController
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        // Present as real mobile Safari MATCHING THIS DEVICE's iOS version. A
        // hardcoded/stale UA (e.g. claiming iOS 26 on an iOS 27 device) is a UA/OS
        // mismatch that Cloudflare's bot check flags → endless re-challenge, where
        // real Safari (consistent UA) passes.
        self.webView.customUserAgent = Self.deviceSafariUserAgent
        super.init(nibName: nil, bundle: nil)
    }

    /// Defines `navigator.standalone` (which a bare WKWebView lacks but real
    /// mobile Safari exposes) at document start, in every frame, before the page's
    /// own scripts run — so the Cloudflare challenge's fingerprint check sees a
    /// signal consistent with the Safari User-Agent we send. Best-effort: it can't
    /// satisfy every Safari-only behavioral check, but it removes the documented
    /// give-away. Wrapped in try/catch so it can never break page scripts.
    private static func safariImpersonationScript() -> WKUserScript {
        let source = """
        (function () {
            try {
                if (typeof navigator.standalone === 'undefined') {
                    Object.defineProperty(navigator, 'standalone', {
                        get: function () { return false; }, configurable: true
                    });
                }
            } catch (e) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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

        setUpLoadingOverlay()

        progress.startAnimating()
        loadArchive()
        startPolling()
        // Resolve the specific newest snapshot via the TimeMap in PARALLEL (clean
        // read endpoint, no startup delay). If it lands before the homepage clears,
        // checkStage loads it; otherwise we submit the homepage form.
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await ArticleFetcher().resolveNewestArchiveSnapshot(for: self.articleURL)
            await MainActor.run {
                guard let snapshot, !self.didLeaveHomepage else { return }
                self.resolvedSnapshotURL = snapshot
                SharedDiagnosticLog.record(
                    "archive: TimeMap resolved snapshot \(snapshot.absoluteString)", category: "archive")
            }
        }
    }

    /// Stage-checks the page on a timer (in addition to `didFinish`) so we still
    /// react when the CAPTCHA clears via an in-page transition.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: true) { [weak self] _ in
            self?.checkStage()
        }
    }

    deinit { pollTimer?.invalidate() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Stop polling the web view once we're off-screen — otherwise the timer
        // keeps firing checkStage() (and could load/submit) on a dismissed flow.
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Builds the opaque cover (themed background + spinner + label) over the web
    /// view; visible from the start so the user never sees the raw archive page
    /// except when a CAPTCHA is up (`checkStage` reveals it then).
    private func setUpLoadingOverlay() {
        loadingOverlay.backgroundColor = .systemBackground
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false

        overlaySpinner.color = GlassStyle.readingAccent
        overlaySpinner.startAnimating()
        overlaySpinner.translatesAutoresizingMaskIntoConstraints = false

        overlayLabel.text = "Unlocking article…"
        overlayLabel.textColor = .secondaryLabel
        overlayLabel.font = .preferredFont(forTextStyle: .callout)
        overlayLabel.textAlignment = .center
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false

        loadingOverlay.addSubview(overlaySpinner)
        loadingOverlay.addSubview(overlayLabel)
        view.addSubview(loadingOverlay)
        NSLayoutConstraint.activate([
            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlaySpinner.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            overlaySpinner.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor),
            overlayLabel.topAnchor.constraint(equalTo: overlaySpinner.bottomAnchor, constant: 14),
            overlayLabel.leadingAnchor.constraint(equalTo: loadingOverlay.leadingAnchor, constant: 32),
            overlayLabel.trailingAnchor.constraint(equalTo: loadingOverlay.trailingAnchor, constant: -32),
        ])
    }

    private static let archiveHomepage = URL(string: "https://archive.is/")! // valid constant

    private func loadArchive() {
        // Load the homepage first (clearance + the search form); `checkStage` then
        // submits the URL into the form / loads the resolved snapshot once cleared.
        SharedDiagnosticLog.record(
            "archive: warming up \(Self.archiveHomepage.absoluteString) ua=\(webView.customUserAgent ?? "default")",
            category: "archive")
        webView.load(URLRequest(url: Self.archiveHomepage))
    }

    /// The snapshot URL to open AFTER the homepage warm-up. When the saved URL is
    /// already an archive snapshot, load that exact snapshot; otherwise
    /// `archive.is/newest/<canonical>` (target in the PATH so the user never types
    /// it into a form).
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
        checkStage()
    }

    /// Probes the loaded page and acts on its stage:
    /// - **challenge** → wait (the user is solving the CAPTCHA).
    /// - **homepage** (the search form `input[name=url]` is present) → reach the
    ///   snapshot the way the site does: load the TimeMap-resolved snapshot if we
    ///   have one, else type the URL into the box and submit the form (once).
    /// - **article** (substantial text, no search box) → extract.
    private func checkStage() {
        guard !didExtract, !isExtracting, viewIfLoaded?.window != nil else { return }
        // Returns "challenge", "error" (Invalid interception ID), "homepage:<len>"
        // (only once the submit token is ready), or "page:<len>".
        let probe = """
        (function () {
            var t = document.body ? document.body.innerText : '';
            if (/Why do I have to complete a CAPTCHA|Checking your browser|Just a moment|Verifying you are human/i.test(t)) {
                return 'challenge';
            }
            if (/invalid interception id/i.test(t)) { return 'error'; }
            var sid = document.querySelector('input[name="submitid"]');
            if (document.querySelector('input[name="url"]') && sid && sid.value) {
                return 'homepage:' + t.length;
            }
            return 'page:' + t.length;
        })()
        """
        webView.evaluateJavaScript(probe) { [weak self] result, _ in
            guard let self, let stage = result as? String else { return }
            SharedDiagnosticLog.record(
                "archive: stage \(stage) @ \(self.webView.url?.absoluteString ?? "")", category: "archive")
            // Reveal the web view ONLY for the CAPTCHA; cover every automated step.
            // Once we've handed over to manual mode (rate-limit/stall) we stop
            // re-covering so the overlay can't slam back over the page.
            if !self.didRevealForManualMode {
                self.loadingOverlay.isHidden = (stage == "challenge")
            }
            // Stall guard: if the overlay has covered the page for too long without
            // progress (e.g. a homepage whose submit token never appears), reveal
            // the page + guidance so the user isn't stranded on "Unlocking…".
            if self.loadingOverlay.isHidden {
                self.coveredPollCount = 0
            } else {
                self.coveredPollCount += 1
                if self.coveredPollCount > Self.stallPollLimit { self.showRateLimit() }
            }
            if stage == "challenge" { return }

            // archive.today lost the submit session — re-run the homepage submit once.
            if stage == "error" {
                guard !self.didRecoverFromError else { return }
                self.didRecoverFromError = true
                self.didLeaveHomepage = false
                SharedDiagnosticLog.record("archive: Invalid interception ID → retrying", category: "archive")
                self.webView.load(URLRequest(url: Self.archiveHomepage))
                return
            }

            if stage.hasPrefix("homepage") {
                guard !self.didLeaveHomepage else { return }
                if let snapshot = self.resolvedSnapshotURL {
                    self.didLeaveHomepage = true
                    SharedDiagnosticLog.record(
                        "archive: homepage cleared → loading resolved snapshot \(snapshot.absoluteString)",
                        category: "archive")
                    self.webView.load(URLRequest(url: snapshot))
                } else {
                    self.submitURLOnHomepage()   // sets didLeaveHomepage only if it actually submits
                }
                return
            }

            // page:<len> — a snapshot/article once it has real text.
            let length = Int(stage.split(separator: ":").last ?? "") ?? 0
            guard length > 1500 else { return }
            self.isExtracting = true
            self.extractAndSave()
        }
    }

    /// Replicates the manual flow: type the article URL into the homepage's
    /// `input[name=url]` box and submit the form (POSTs to `/submit/`, which for an
    /// already-archived page 302-redirects straight to the existing snapshot). Only
    /// submits once the hidden `submitid` token is present (submitting with a stale/
    /// missing token is what yields "Invalid interception ID").
    private func submitURLOnHomepage() {
        let target = ArticleFetcher.canonicalForArchiving(articleURL).absoluteString
        let literal = Self.jsStringLiteral(target)
        let fill = """
        (function () {
            var i = document.querySelector('input[name="url"]');
            var sid = document.querySelector('input[name="submitid"]');
            if (!i || !sid || !sid.value) { return 'wait'; }
            i.value = \(literal);
            if (i.form) { i.form.submit(); return 'submitted'; }
            return 'no-form';
        })()
        """
        SharedDiagnosticLog.record("archive: homepage cleared → submitting URL in form", category: "archive")
        webView.evaluateJavaScript(fill) { [weak self] result, _ in
            if (result as? String) == "submitted" { self?.didLeaveHomepage = true }
            SharedDiagnosticLog.record(
                "archive: form submit result=\(result as? String ?? "nil")", category: "archive")
        }
    }

    /// A JS string literal with proper escaping (via JSON), e.g. `"https://…"`.
    private static func jsStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())   // strip the surrounding [ ]
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
                    self.pollTimer?.invalidate()
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
        // Reveal the web view + show the guidance banner on top — the user needs to
        // see the page to act on the advice. Latch manual mode so the poll no longer
        // re-covers the page.
        didRevealForManualMode = true
        loadingOverlay.isHidden = true
        rateLimitBanner.isHidden = false
        view.bringSubviewToFront(rateLimitBanner)
    }
}
