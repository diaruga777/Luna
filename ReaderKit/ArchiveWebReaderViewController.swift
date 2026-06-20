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
    /// An opaque, themed cover (spinner) shown OVER the web view to hide the raw
    /// archive.today navigation (home page, form fill/submit, snapshot load). It's
    /// removed only while a CAPTCHA is up — the one moment the user must see and
    /// touch the page. The web view stays un-hidden and full-size beneath it
    /// (covered, not hidden — so iOS never throttles its JS/navigation), which is
    /// what keeps the automated flow running while it's visually concealed. When the
    /// flow can't proceed (rate-limited, or the page can't be archived) the cover
    /// stays up and shows the message + an Open-in-Safari escape — not a popup.
    private let loadingOverlay = UIView()
    private let overlaySpinner = UIActivityIndicatorView(style: .large)
    private let overlayLabel = UILabel()
    /// An "Open in Safari" escape shown INSIDE the overlay alongside an error /
    /// guidance message. Hidden in extensions (no `UIApplication`).
    private let overlaySafariButton = UIButton(type: .system)
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
    /// Consecutive poll ticks where the opaque overlay is covering the page without
    /// progress; past `stallPollLimit` we surface the rate-limit guidance so the
    /// user is never stranded on a permanent "Unlocking…" screen (e.g. a homepage
    /// whose submit token never appears). Reset whenever the overlay is down.
    private var coveredPollCount = 0
    private static let stallPollLimit = 23   // ≈ 30s at the 1.3s poll interval
    /// Consecutive poll ticks on archive.today's "enable JS / disable ad blocker"
    /// gate. It doesn't clear in a WKWebView, so past `blockedPollLimit` we treat it
    /// as terminal (the un-archivable message + Safari escape).
    private var blockedPollCount = 0
    private static let blockedPollLimit = 3   // ≈ 4s — tolerate a transient flash
    /// The ordered WKWebView pre-stage URLs to try BEFORE the archive.today flow —
    /// derived from `BypassStrategySelector` filtered to the strategies worth a real
    /// browser (the trailing-dot host variant, smry.ai, removepaywall(s).com). Each
    /// is loaded in turn; a readable extraction from any of them finishes via the
    /// normal `onExtracted` path with no archive.today at all. Empty → straight to
    /// archive.today. The silent strategies already ran (and failed) in the
    /// background path, so only the JS-rendered ones are repeated here.
    private let webPreStageURLs: [URL]
    /// Index of the pre-stage currently loaded; advances as each one times out.
    private var currentPreStageIndex = 0
    /// True while loading/extracting a pre-stage page (before any archive.today
    /// navigation).
    private var isAttemptingDirectBypass = false
    /// Poll ticks spent on the current pre-stage page; past `bypassPollLimit` without
    /// a readable extraction we advance to the next pre-stage (or the archive flow).
    private var bypassPollCount = 0
    private static let bypassPollLimit = 7   // ≈ 9s at the 1.3s poll interval
    /// Set once we surface a terminal message in the overlay (rate-limit or
    /// un-archivable). Stops polling/extraction and any further overlay toggling.
    private var didShowTerminalMessage = false
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
        "Your network is being rate-limited right now.\n\nTry one of these, then reopen:\n"
        + "•  Wait ~30 minutes\n"
        + "•  Switch networks or turn on a VPN\n"
        + "•  Tap Open in Safari below and view there"

    /// Shown when archive.today returns an error AFTER the user solved the CAPTCHA
    /// (a stale/invalid capture session, an un-archivable page) — solving again
    /// won't help, so we stop and tell the user plainly rather than spin forever.
    private static let cannotArchiveMessage =
        "This site can't be archived right now. Try again in a little while, or open it in Safari."

    init(articleURL: URL, itemID: UUID?, store: ReadingListStore = .shared) {
        self.articleURL = articleURL
        self.itemID = itemID
        self.store = store
        self.webPreStageURLs = Self.webPreStageURLs(for: articleURL)
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // archive.today refuses clients it thinks have JS off; make it explicit (and
        // we install no content blocker, so its "disable ad blocker" gate isn't us).
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
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

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        setUpLoadingOverlay()

        progress.startAnimating()
        startPolling()
        if !webPreStageURLs.isEmpty {
            // Walk the WKWebView pre-stage list (trailing-dot, then any third-party
            // reader pages) before the archive.today flow; a readable extraction from
            // any of them finishes via the normal `onExtracted` path.
            isAttemptingDirectBypass = true
            loadCurrentPreStage()
        } else {
            loadArchive()
            resolveSnapshotInParallel()
        }
    }

    /// Loads the pre-stage URL at `currentPreStageIndex` and resets its poll counter.
    private func loadCurrentPreStage() {
        guard currentPreStageIndex < webPreStageURLs.count else {
            fallBackToArchiveFromBypass()
            return
        }
        bypassPollCount = 0
        let url = webPreStageURLs[currentPreStageIndex]
        SharedDiagnosticLog.record(
            "archive: pre-stage \(currentPreStageIndex + 1)/\(webPreStageURLs.count) \(url.absoluteString)",
            category: "archive")
        webView.load(URLRequest(url: url))
    }

    /// Resolves the specific newest archive.today snapshot via the TimeMap in
    /// PARALLEL (clean read endpoint, no startup delay). If it lands before the
    /// homepage clears, `checkStage` loads it; otherwise we submit the homepage
    /// form. Skipped during the direct-bypass pre-stage (only needed once we're on
    /// the archive.today path).
    private func resolveSnapshotInParallel() {
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
        // Alpha on the BACKGROUND only (not the whole view) so the spinner/label
        // stay crisp while the experimental setting can make the cover see-through
        // for debugging. 0.99 = effectively opaque.
        loadingOverlay.backgroundColor = .systemBackground.withAlphaComponent(
            CGFloat(ReaderSettings.archiveOverlayAlpha))
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false

        overlaySpinner.color = GlassStyle.readingAccent
        overlaySpinner.startAnimating()

        overlayLabel.text = "Unlocking article…"
        overlayLabel.textColor = .secondaryLabel
        overlayLabel.font = .preferredFont(forTextStyle: .callout)
        overlayLabel.textAlignment = .center
        overlayLabel.numberOfLines = 0

        var safariConfig = UIButton.Configuration.borderedProminent()
        safariConfig.title = "Open in Safari"
        safariConfig.image = UIImage(systemName: "safari")
        safariConfig.imagePadding = 6
        safariConfig.cornerStyle = .large
        overlaySafariButton.configuration = safariConfig
        overlaySafariButton.isHidden = true   // only shown with a terminal message
        overlaySafariButton.addAction(UIAction { [weak self] _ in self?.openInBrowser() }, for: .touchUpInside)

        // A centered stack: hiding the spinner (and showing the button) recenters
        // the message cleanly, since stacks ignore hidden arranged subviews.
        let stack = UIStackView(arrangedSubviews: [overlaySpinner, overlayLabel, overlaySafariButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        loadingOverlay.addSubview(stack)
        view.addSubview(loadingOverlay)
        NSLayoutConstraint.activate([
            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: loadingOverlay.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: loadingOverlay.trailingAnchor, constant: -32),
            overlayLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
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

    /// The ordered WKWebView pre-stage URLs for `articleURL`: the strategy list from
    /// `BypassStrategySelector`, filtered to the JS-rendered strategies worth a real
    /// browser (`.trailingDotHost`, `.thirdPartyWeb`) and mapped to a loadable URL.
    /// archive.today is excluded — it's the terminal flow, not a pre-stage. Silent
    /// strategies are excluded (they already ran in the background path). Pure +
    /// static so the ordering is unit-testable without a web view.
    static func webPreStageURLs(for articleURL: URL) -> [URL] {
        // A URL already on archive.today goes straight to the snapshot flow.
        guard !ArticleFetcher.isArchiveTodayURL(articleURL) else { return [] }
        let strategies = BypassStrategySelector.strategies(for: articleURL, directHTML: nil)
        return strategies.compactMap { strategy -> URL? in
            switch strategy {
            case .trailingDotHost:
                return TrailingDotBypass.trailingDotURL(for: articleURL)
            case let .thirdPartyWeb(service):
                return service.url(for: articleURL)
            default:
                // Silent strategies + archive.today are not WKWebView pre-stages.
                return nil
            }
        }
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
        if isAttemptingDirectBypass { checkDirectBypassStage(); return }
        // Returns "error" (Invalid interception ID), "homepage:<len>" (the search
        // form is present → type the URL + submit), "challenge:<len>" (a Cloudflare/
        // reCAPTCHA gate, detected by WIDGET not just text so the overlay reliably
        // lifts), or "page:<len>".
        //
        // The homepage check comes FIRST: archive.today's own save form can carry a
        // spam-protection reCAPTCHA, which must NOT be mistaken for a blocking
        // challenge (the manual flow submits without solving it). No submitid gate —
        // submitting on `input[name=url]` is the proven flow; if the capture session
        // goes stale it surfaces "Error -32602: Invalid InterceptionId", which we
        // catch and show as a terminal error.
        let probe = """
        (function () {
            var t = document.body ? document.body.innerText : '';
            // archive.today's capture-session error, e.g. "Error: Error -32602:
            // Invalid InterceptionId." — match the code and the phrase (note: the
            // real string is one word "InterceptionId", with optional space).
            if (/-32602|invalid interception ?id/i.test(t)) { return 'error'; }
            // archive.today's "Please enable JS and disable any ad blocker" gate — a
            // short interstitial that does NOT auto-clear in a WKWebView. Matched on
            // a SHORT body so a real article that merely mentions ad blockers / JS
            // can't trip it. Checked before the homepage box so it wins if the gate
            // also carries the site chrome.
            var lc = t.toLowerCase();
            if (lc.length < 800
                && (lc.indexOf('enable js') >= 0 || lc.indexOf('enable javascript') >= 0)
                && (lc.indexOf('ad blocker') >= 0 || lc.indexOf('adblocker') >= 0)) {
                return 'blocked';
            }
            if (document.querySelector('input[name="url"]')) { return 'homepage:' + t.length; }
            var challengeWidget = document.querySelector(
                'iframe[src*="recaptcha"], iframe[src*="challenges.cloudflare.com"], '
                + 'iframe[title*="recaptcha" i], iframe[title*="challenge" i], '
                + '.g-recaptcha, [data-sitekey], .cf-turnstile, #cf-please-wait, '
                + '#challenge-form, #challenge-running, #cf-challenge-running, '
                + 'form[action*="chk_captcha"], form[action*="cdn-cgi"]');
            if (challengeWidget) { return 'challenge'; }
            if (/Why do I have to complete a CAPTCHA|Checking your browser|Just a moment|Verifying you are human|needs to review the security/i.test(t)) {
                return 'challenge';
            }
            return 'page:' + t.length;
        })()
        """
        webView.evaluateJavaScript(probe) { [weak self] result, _ in
            guard let self, let stage = result as? String else { return }
            // A terminal message is up (rate-limit / un-archivable) — the flow has
            // stopped; ignore any in-flight probe so it can't re-cover/re-drive.
            if self.didShowTerminalMessage { return }
            SharedDiagnosticLog.record(
                "archive: stage \(stage) @ \(self.webView.url?.absoluteString ?? "")", category: "archive")
            // Reveal the web view ONLY for the CAPTCHA; cover every automated step.
            self.loadingOverlay.isHidden = (stage == "challenge")
            // Stall guard: if the overlay has covered the page for too long without
            // progress (e.g. a homepage whose submit token never appears), surface
            // the rate-limit guidance so the user isn't stranded on "Unlocking…".
            if self.loadingOverlay.isHidden {
                self.coveredPollCount = 0
            } else {
                self.coveredPollCount += 1
                if self.coveredPollCount > Self.stallPollLimit { self.showRateLimit(); return }
            }
            // Track how long we've sat on the "enable JS / ad blocker" gate so
            // `decideStage` can give up on it after a brief tolerance.
            self.blockedPollCount = (stage == "blocked") ? self.blockedPollCount + 1 : 0
            switch Self.decideStage(
                stage,
                didLeaveHomepage: self.didLeaveHomepage,
                hasResolvedSnapshot: self.resolvedSnapshotURL != nil,
                blockedCount: self.blockedPollCount,
                blockedLimit: Self.blockedPollLimit
            ) {
            case .wait, .challenge:
                break   // not ready / user solving the CAPTCHA — keep polling
            case .submitHomepage:
                self.didLeaveHomepage = true   // set synchronously so a poll tick mid-submit can't re-fire
                self.submitURLOnHomepage()
            case .loadResolvedSnapshot:
                self.didLeaveHomepage = true
                if let snapshot = self.resolvedSnapshotURL {
                    SharedDiagnosticLog.record(
                        "archive: homepage cleared → loading resolved snapshot \(snapshot.absoluteString)",
                        category: "archive")
                    self.webView.load(URLRequest(url: snapshot))
                }
            case .cannotArchive:
                SharedDiagnosticLog.record("archive: error → cannot archive", category: "archive")
                self.showCannotArchive()
            case .attemptExtract:
                self.isExtracting = true
                self.extractAndSave()
            }
        }
    }

    /// What `checkStage` should do for a probed page `stage`, given flow state.
    /// Pure + `Equatable` so the decision is unit-testable without a live web view.
    ///
    /// Crucially, after the homepage has been submitted (`didLeaveHomepage`), a
    /// page that still shows the `input[name=url]` box (reported as `homepage:<len>`)
    /// is NOT treated as the homepage again — every archive.today page carries that
    /// box in its chrome, so it would otherwise pin us on a spinner forever once the
    /// `/wip/` progress shell renders the real article. We fall through to the
    /// length gate and let `extractAndSave`'s readability check be the final arbiter.
    enum StageDecision: Equatable {
        case wait                  // challenge held, or page too short — keep polling
        case challenge             // a CAPTCHA gate is up — reveal the page for the user
        case submitHomepage        // on the homepage form, not yet submitted — submit the URL
        case loadResolvedSnapshot  // homepage cleared and a TimeMap snapshot is resolved — load it
        case cannotArchive         // archive.today error / un-clearable gate — terminal
        case attemptExtract        // page has real text — try extracting the article
    }

    static func decideStage(
        _ stage: String,
        didLeaveHomepage: Bool,
        hasResolvedSnapshot: Bool,
        blockedCount: Int = 0,
        blockedLimit: Int = 3,
        minExtractLength: Int = 1500
    ) -> StageDecision {
        if stage == "challenge" { return .challenge }
        if stage == "blocked" {
            // archive.today's "enable JS / disable ad blocker" gate doesn't clear in
            // a WKWebView (JS is on; we add no blocker). Tolerate a transient flash,
            // then treat as terminal so the user falls back to real Safari.
            return blockedCount >= blockedLimit ? .cannotArchive : .wait
        }
        // archive.today's "Error -32602: Invalid InterceptionId" (the capture session
        // went stale) — terminal; retrying/solving won't help, so show the error.
        if stage == "error" { return .cannotArchive }
        if stage.hasPrefix("homepage"), !didLeaveHomepage {
            return hasResolvedSnapshot ? .loadResolvedSnapshot : .submitHomepage
        }
        let length = Int(stage.split(separator: ":").last ?? "") ?? 0
        return length > minExtractLength ? .attemptExtract : .wait
    }

    /// A WKWebView pre-stage page: the page is the (hopefully un-paywalled) article
    /// itself (no archive, no CAPTCHA), so just poll its text length and try
    /// extracting. If the current pre-stage doesn't yield a readable article within
    /// `bypassPollLimit` ticks (the trick stopped working / a paywall is still up /
    /// the service didn't render), advance to the next pre-stage — or fall back to
    /// the archive.today flow once the list is exhausted.
    private func checkDirectBypassStage() {
        bypassPollCount += 1
        if bypassPollCount > Self.bypassPollLimit {
            advanceToNextPreStage()
            return
        }
        let probe = "(function(){return document.body ? document.body.innerText.length : 0;})()"
        webView.evaluateJavaScript(probe) { [weak self] result, _ in
            guard let self, self.isAttemptingDirectBypass, !self.didExtract, !self.isExtracting else { return }
            let length = (result as? NSNumber)?.intValue ?? 0
            guard length > 1500 else { return }   // still rendering — try again next tick
            self.isExtracting = true
            self.extractAndSave()   // readable → save + onExtracted; not readable → resets, retries
        }
    }

    /// Advances to the next WKWebView pre-stage, or runs the archive.today flow when
    /// the pre-stage list is exhausted.
    private func advanceToNextPreStage() {
        guard isAttemptingDirectBypass else { return }
        currentPreStageIndex += 1
        if currentPreStageIndex < webPreStageURLs.count {
            loadCurrentPreStage()
        } else {
            fallBackToArchiveFromBypass()
        }
    }

    /// Gives up on the pre-stages and runs the normal archive.today flow.
    private func fallBackToArchiveFromBypass() {
        guard isAttemptingDirectBypass else { return }
        isAttemptingDirectBypass = false
        SharedDiagnosticLog.record(
            "archive: pre-stages didn't yield a readable article → archive.today flow", category: "archive")
        didLeaveHomepage = false
        loadArchive()
        resolveSnapshotInParallel()
    }

    /// Replicates the manual flow: type the article URL into the homepage's
    /// `input[name=url]` box and submit its form (POSTs to `/submit/` with the form's
    /// hidden `submitid`, which for an already-archived page 302-redirects straight
    /// to the existing snapshot). Submits as soon as the box exists — the proven
    /// flow; a stale capture session surfaces "Invalid InterceptionId", caught as a
    /// terminal error.
    private func submitURLOnHomepage() {
        let target = ArticleFetcher.canonicalForArchiving(articleURL).absoluteString
        let literal = Self.jsStringLiteral(target)
        let fill = """
        (function () {
            var i = document.querySelector('input[name="url"]');
            if (!i) { return 'no-input'; }
            i.value = \(literal);
            if (i.form) { i.form.submit(); return 'submitted'; }
            return 'no-form';
        })()
        """
        SharedDiagnosticLog.record("archive: homepage → typing URL + submitting form", category: "archive")
        webView.evaluateJavaScript(fill) { result, _ in
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

    /// archive.today is rate-limiting the network — solving the CAPTCHA won't pass.
    private func showRateLimit() { showTerminalMessage(Self.rateLimitMessage) }

    /// archive.today returned an error after the CAPTCHA (un-archivable page / stale
    /// session) — solving again won't help.
    private func showCannotArchive() { showTerminalMessage(Self.cannotArchiveMessage) }

    /// Surfaces a terminal message IN the overlay (not a popup): stops the spinner,
    /// shows the message text, and — in the main app — an Open-in-Safari escape.
    /// Stops polling so the flow can't re-cover or re-drive the page afterward.
    private func showTerminalMessage(_ message: String) {
        guard !didShowTerminalMessage else { return }
        didShowTerminalMessage = true
        pollTimer?.invalidate()
        pollTimer = nil
        progress.stopAnimating()
        overlaySpinner.stopAnimating()
        overlayLabel.text = message
        overlayLabel.textColor = .label
        overlaySafariButton.isHidden = (onOpenInBrowser == nil)
        // Fully opaque so the message reads clearly regardless of the experimental
        // overlay-alpha setting, and kept above the (now idle) web view.
        loadingOverlay.backgroundColor = .systemBackground
        loadingOverlay.isHidden = false
        view.bringSubviewToFront(loadingOverlay)
    }
}
