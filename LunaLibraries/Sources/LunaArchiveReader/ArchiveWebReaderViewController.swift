//
//  ArchiveWebReaderViewController.swift
//  ReaderKit
//

import LunaDesignSystem
import LunaStorage
import LunaPaywallBypass
import LunaFetch
import LunaHTMLClassification
import LunaModels
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
public final class ArchiveWebReaderViewController: UIViewController, WKNavigationDelegate {

    private let articleURL: URL
    private let itemID: UUID?
    private let store: ReadingListStore
    private let webView: WKWebView
    private let progress = DotMatrixSpinnerView()
    /// An opaque, themed cover (spinner) shown OVER the web view to hide the raw
    /// archive.today navigation (home page, form fill/submit, snapshot load). It's
    /// removed only while a CAPTCHA is up — the one moment the user must see and
    /// touch the page. The web view stays un-hidden and full-size beneath it
    /// (covered, not hidden — so iOS never throttles its JS/navigation), which is
    /// what keeps the automated flow running while it's visually concealed. When the
    /// flow can't proceed (rate-limited, or the page can't be archived) the cover
    /// stays up and shows the message + an Open-in-Safari escape — not a popup.
    private let loadingOverlay = UIView()
    /// Five deliberate taps reveal the archive page for troubleshooting without
    /// exposing a user-facing experimental setting. Once revealed, disabling the
    /// overlay's interaction lets scroll gestures reach the web view below.
    private var archiveCoverTapCount = 0
    private let overlaySpinner = DotMatrixSpinnerView(side: 36)
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
    private var isSubmittingHomepage = false
    /// The timeout is advisory, not terminal: archive.is can take a long time to
    /// finish a capture. Keep polling/extracting while giving the user Safari.
    private var didShowStuckNotice = false
    /// Consecutive poll ticks where the opaque overlay is covering the page without
    /// progress; past `stallPollLimit` we surface the rate-limit guidance so the
    /// user is never stranded on a permanent "Unlocking…" screen (e.g. a homepage
    /// whose submit token never appears). Reset whenever the overlay is down.
    private var coveredPollCount = 0
    private static let stallPollLimit = 86   // ≈ 30s at the 0.35s poll interval
    /// Consecutive poll ticks on archive.today's "enable JS / disable ad blocker"
    /// gate. It doesn't clear in a WKWebView, so past `blockedPollLimit` we treat it
    /// as terminal (the un-archivable message + Safari escape).
    private var blockedPollCount = 0
    private static let blockedPollLimit = 12  // ≈ 4s — tolerate a transient flash
    /// The ordered WKWebView pre-stage URLs to try BEFORE the archive.today flow —
    /// derived from `BypassStrategySelector` filtered to the strategies worth a real
    /// browser. The archive-only policy leaves this empty, taking every detected
    /// paywall straight to archive.is with no proxy or reader-service pre-stage.
    private let webPreStageURLs: [URL]
    /// True when the plan includes the `.directUnlock` WKWebView technique (toggle
    /// on): the paywall-vendor content-blocker + DOM cleanup are installed.
    private let usesDirectUnlock: Bool
    /// The `Referer` to send on the direct-unlock load (a site that unlocks for a
    /// specific referrer — e.g. WSJ → Drudge Report — or a Google search). The UA is
    /// left as the real device Safari UA; only the referrer is spoofed.
    private let directUnlockReferer: String?
    /// Index of the pre-stage currently loaded; advances as each one times out.
    private var currentPreStageIndex = 0
    /// True while loading/extracting a pre-stage page (before any archive.today
    /// navigation).
    private var isAttemptingDirectBypass = false
    /// True once a bot/verification CAPTCHA was seen on a direct-unlock pre-stage.
    private var sawPreStageChallenge = false
    /// True once we've reloaded the article with the site's referer AFTER the user
    /// cleared a CAPTCHA — the site's own post-CAPTCHA reload drops our custom Referer,
    /// so we re-issue the request (now carrying the clearance cookie AND the referer).
    /// Guards against a reload loop.
    private var didPostChallengeReload = false
    /// Poll ticks spent on the current pre-stage page; past `bypassPollLimit` without
    /// a readable extraction we advance to the next pre-stage (or the archive flow).
    private var bypassPollCount = 0
    /// ≈12s at the 0.35s poll interval. A heavy SPA article (NYT et al.) hydrates its
    /// full article DOM well after first paint, so the pre-stage needs a real budget to
    /// let the body fill in before we give up and route to archive.today — the old
    /// 7-tick (~2.45s) limit gave up before the text was extractable.
    private static let bypassPollLimit = 34
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
    public var onClose: (() -> Void)?
    /// Called once the article has been extracted and saved (the CAPTCHA was
    /// solved and a real snapshot loaded). Extensions use this to show their
    /// success checkmark and finish; the main app leaves it nil and lets the user
    /// keep reading the loaded snapshot.
    public var onExtracted: (() -> Void)?
    /// Escape hatch for when archive.today keeps CAPTCHA-looping in the embedded
    /// web view: opens the same archive URL in real Safari (which may already hold
    /// a valid `cf_clearance`). Main-app-only — set by the presenter; left nil in
    /// extensions (no `UIApplication` there), where the button is hidden.
    public var onOpenInBrowser: ((URL) -> Void)?

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

    private static let mayBeStuckMessage =
        "This archive is taking longer than usual. It may be stuck, but we’re still waiting."

    public init(articleURL: URL, itemID: UUID?, store: ReadingListStore = .shared) {
        self.articleURL = articleURL
        self.itemID = itemID
        self.store = store
        // Build the plan once so we know both the pre-stage URLs and whether the
        // reference paywall rules `.directUnlock` WKWebView technique is in play.
        let plan = BypassPlan.make(for: articleURL, directHTML: nil)
        self.usesDirectUnlock = plan.webPreStages.contains(.directUnlock)
        self.directUnlockReferer = Self.directUnlockReferer(for: articleURL)
        self.webPreStageURLs = plan.webPreStages.compactMap {
            BypassURLs.loadURL(for: $0, article: articleURL)
        }
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // archive.today refuses clients it thinks have JS off; make it explicit (and
        // we install no content blocker, so its "disable ad blocker" gate isn't us).
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Referer-unlock sites (WSJ/FT) serve the full article to a FRESH client (no
        // prior metering cookie) arriving from the unlock referrer — a browser
        // carrying a used-up non-subscriber cookie gets the teaser regardless. So use
        // a fresh in-memory store there (empty of stale cookies; the CAPTCHA clearance
        // set during THIS session still persists in memory across the reload). Every
        // other flow uses the persistent store (Cloudflare `cf_clearance` survives).
        configuration.websiteDataStore = directUnlockReferer != nil
            ? .nonPersistent() : .default()
        // Best-effort masking of the JS signals Cloudflare cross-references against
        // the Safari UA we present (see init below). We can't BE the Safari process
        // like SFSafariViewController, but defining `navigator.standalone` — present
        // in real Safari, `undefined` in a bare WKWebView — removes the single most
        // reliable "this is an embedded web view" tell. No `WKScriptMessageHandler`
        // is registered, so `window.webkit.messageHandlers` also stays absent.
        let contentController = WKUserContentController()
        contentController.addUserScript(Self.safariImpersonationScript())
        // The the reference paywall rules DOM cleanup (overlay removal / unhide / scroll
        // restore). It self-guards off archive.today hosts, so it only acts on the
        // `.directUnlock` (and trailing-dot) pages, never the CAPTCHA flow.
        if usesDirectUnlock {
            contentController.addUserScript(PaywallUnlockRules.cleanupUserScript())
            // A bespoke per-site cleanup snippet on top of the generic one, when we
            // have one for this host.
            if let siteScript = SiteCleanupScripts.userScript(for: articleURL) {
                contentController.addUserScript(siteScript)
            }
        }
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

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
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
            // Walk the WKWebView pre-stage list (directUnlock, trailing-dot) before the
            // archive.today flow; a readable extraction from any of them finishes via
            // the normal `onExtracted` path. For `.directUnlock`, first install the
            // paywall-vendor content-blocker so the meter scripts can't run.
            isAttemptingDirectBypass = true
            if usesDirectUnlock {
                PaywallUnlockRules.compiledRuleList(for: articleURL) { [weak self] list in
                    guard let self else { return }
                    if let list { self.webView.configuration.userContentController.add(list) }
                    self.loadCurrentPreStage()
                }
            } else {
                loadCurrentPreStage()
            }
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
        var request = URLRequest(url: url)
        // Spoof the site's unlock referrer on the direct-unlock load of the original
        // page (UA untouched). Only when loading the article's own host.
        if let referer = directUnlockReferer, url.host == articleURL.host {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        webView.load(request)
    }

    /// The `Referer` a site's rule says unlocks it (a custom referrer such as Drudge
    /// Report, or a Google search), or nil. Only the referrer is spoofed — the web
    /// view keeps its genuine Safari User-Agent.
    private static func directUnlockReferer(for url: URL) -> String? {
        guard let rule = SiteUnlockRules.rule(for: url) else { return nil }
        if let custom = rule.refererCustom { return custom }
        if rule.referer == "google" { return "https://www.google.com/" }
        return nil
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.checkStage()
        }
    }

    deinit { pollTimer?.invalidate() }

    public override func viewDidDisappear(_ animated: Bool) {
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
        // The cover is effectively opaque until its five-tap escape hatch is used.
        // Only its background is translucent so the loading controls stay crisp.
        loadingOverlay.backgroundColor = .systemBackground.withAlphaComponent(0.99)
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        let revealGesture = UITapGestureRecognizer(
            target: self, action: #selector(archiveCoverTapped(_:)))
        loadingOverlay.addGestureRecognizer(revealGesture)

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

    @objc private func archiveCoverTapped(_ gesture: UITapGestureRecognizer) {
        archiveCoverTapCount += 1
        guard archiveCoverTapCount == 5 else { return }

        loadingOverlay.backgroundColor = .systemBackground.withAlphaComponent(0.1)
        loadingOverlay.isUserInteractionEnabled = false
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
    public static func archiveURL(for articleURL: URL) -> URL? {
        if ArticleFetcher.isArchiveTodayURL(articleURL) { return articleURL }
        let target = ArticleFetcher.canonicalForArchiving(articleURL).absoluteString
        guard let url = URL(string: "https://archive.is/newest/\(target)"),
              ArticleFetcher.isArchiveTodayURL(url)   // reject a smuggled non-archive host
        else { return nil }
        return url
    }

    /// The ordered WKWebView pre-stage URLs for `articleURL`, taken from the SAME
    /// `BypassPlan` factory the resolver's silent leg uses (so the two paths can't
    /// diverge) — its `webPreStages` leg mapped to loadable URLs via `BypassURLs`.
    /// archive.today is excluded (the terminal flow, not a pre-stage); a trailing-dot
    /// that already ran silently is excluded by the plan (it doesn't benefit from a JS
    /// retry, so NYT skips the ~9s redundant pre-stage). Pure + static so the ordering
    /// is unit-testable without a web view.
    public static func webPreStageURLs(for articleURL: URL) -> [URL] {
        // A URL already on archive.today goes straight to the snapshot flow.
        guard !ArticleFetcher.isArchiveTodayURL(articleURL) else { return [] }
        let plan = BypassPlan.make(for: articleURL, directHTML: nil)
        return plan.webPreStages.compactMap { BypassURLs.loadURL(for: $0, article: articleURL) }
    }

    /// Opens the archive in real Safari (the proven-working path when the embedded
    /// web view can't pass the CAPTCHA). Uses the currently-loaded URL when present.
    private func openInBrowser() {
        guard let url = webView.url ?? Self.archiveURL(for: articleURL) else { return }
        onOpenInBrowser?(url)
    }

    // MARK: - WKNavigationDelegate

    public func webView(
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
        if navigationAction.targetFrame?.isMainFrame ?? true,
           isSubmittingHomepage,
           !Self.isArchiveHomepageURL(navigationAction.request.url) {
            didLeaveHomepage = true
            isSubmittingHomepage = false
        }
        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A 429 is archive.today's rate-limit. The first one still carries a CAPTCHA
        // that MIGHT be solvable, so let the user try it; only once it has looped
        // (repeated 429s) do we conclude solving won't pass and show the guidance.
        // Only a MAIN-FRAME 429 from archive.today itself counts: sub-resource 429s
        // (challenge iframes, trackers) and pre-stage 429s from the article's own
        // site must not put up the terminal rate-limit message — the latter would
        // abandon the flow before archive.today was even tried.
        if let http = navigationResponse.response as? HTTPURLResponse {
            SharedDiagnosticLog.record(
                "archive: response \(http.statusCode) \(http.url?.absoluteString ?? "")", category: "archive")
            if http.statusCode == 429, navigationResponse.isForMainFrame,
               let url = http.url, ArticleFetcher.isArchiveTodayURL(url) {
                challengeCount += 1
                if challengeCount >= Self.loopThreshold { showRateLimit() }
            }
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimating()
        checkStage()
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // The form stays in archive.is's chrome even on a completed snapshot. A
        // main-frame navigation away from the actual root homepage is the durable
        // signal that the target was submitted; never infer it from page text.
        if let url = webView.url, !Self.isArchiveHomepageURL(url) {
            didLeaveHomepage = true
            isSubmittingHomepage = false
        }
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
        // Returns only structural state. In particular, no text length is used:
        // archive.is's idle homepage and its request-log shell can both be long.
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
            if ((lc.indexOf('enable js') >= 0 || lc.indexOf('enable javascript') >= 0)
                && (lc.indexOf('ad blocker') >= 0 || lc.indexOf('adblocker') >= 0)) {
                return 'blocked';
            }
            var homeForm = document.querySelector('input[name="url"]');
            var onRootHomepage = location.pathname === '/' || location.pathname === '';
            if (onRootHomepage && homeForm && homeForm.form) { return 'homepage'; }
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
            // A snapshot becomes eligible only when it exposes a semantic content
            // root. The extractor is the final authority; this merely keeps archive
            // request/status text outside the extraction path.
            var root = document.querySelector(
                'article, [itemprop="articleBody"], main article, [class*="article-body"], #CONTENT');
            return root ? 'content-root' : 'waiting';
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
                if self.coveredPollCount > Self.stallPollLimit { self.showStuckNotice() }
            }
            // Track how long we've sat on the "enable JS / ad blocker" gate so
            // `decideStage` can give up on it after a brief tolerance.
            self.blockedPollCount = (stage == "blocked") ? self.blockedPollCount + 1 : 0
            switch Self.decideStage(
                stage,
                didLeaveHomepage: self.didLeaveHomepage,
                isSubmittingHomepage: self.isSubmittingHomepage,
                hasResolvedSnapshot: self.resolvedSnapshotURL != nil,
                blockedCount: self.blockedPollCount,
                blockedLimit: Self.blockedPollLimit
            ) {
            case .wait, .challenge:
                break   // not ready / user solving the CAPTCHA — keep polling
            case .submitHomepage:
                self.isSubmittingHomepage = true
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
    /// page that still shows the `input[name=url]` box is NOT treated as the
    /// homepage again — every archive.today page carries that box in its chrome.
    public enum StageDecision: Equatable {
        case wait                  // waiting for a semantic page transition/root
        case challenge             // a CAPTCHA gate is up — reveal the page for the user
        case submitHomepage        // on the homepage form, not yet submitted — submit the URL
        case loadResolvedSnapshot  // homepage cleared and a TimeMap snapshot is resolved — load it
        case cannotArchive         // archive.today error / un-clearable gate — terminal
        case attemptExtract        // page has real text — try extracting the article
    }

    public static func decideStage(
        _ stage: String,
        didLeaveHomepage: Bool,
        isSubmittingHomepage: Bool,
        hasResolvedSnapshot: Bool,
        blockedCount: Int = 0,
        blockedLimit: Int = 3
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
        if stage == "homepage", isSubmittingHomepage {
            return .wait
        }
        if stage == "homepage", !didLeaveHomepage {
            return hasResolvedSnapshot ? .loadResolvedSnapshot : .submitHomepage
        }
        return stage == "content-root" && didLeaveHomepage ? .attemptExtract : .wait
    }

    /// A WKWebView pre-stage page: the page is the (hopefully un-paywalled) article
    /// itself (no archive, no CAPTCHA), so just poll its text + try extracting. Two
    /// ways to leave the current pre-stage early instead of stalling:
    /// - a "please enable JavaScript" gate: detected on a SHORT body so a real
    ///   article that merely mentions JavaScript can't trip it → advance immediately.
    /// - otherwise, `bypassPollLimit` ticks without a readable extraction (the trick
    ///   stopped working / a paywall is still up / the service didn't render) →
    ///   advance to the next pre-stage, or fall back to archive.today when exhausted.
    private func checkDirectBypassStage() {
        // The pre-stage uses semantic extraction as its readiness test too: a long
        // status page must not become an article merely because it has verbose text.
        // It ALSO detects a bot/verification CAPTCHA on the original site (DataDome,
        // reCAPTCHA, Cloudflare, hCaptcha) so the overlay can be lifted for the user
        // to solve it — the same courtesy the archive.today flow gives.
        let probe = """
        (function () {
            // CONTENT FIRST: if the article body already rendered, the page ISN'T gated —
            // extract it, even when a reCAPTCHA/consent iframe is ALSO on the page. A
            // client-side-unlocked article (New Statesman, Piano blocked) still loads ad
            // slots (dianomi/Google) that embed `recaptcha` iframes; the old challenge-
            // first order mistook those AD reCAPTCHAs for an access gate, revealed the
            // page, and paused forever without ever extracting the visible article.
            if (document.querySelector('article, [itemprop=articleBody], main article, [class*=article-body], #CONTENT')) {
                return 'content-root';
            }
            var t = document.body ? document.body.innerText : '';
            // A referer-unlocked site (WSJ) can render the full article body without any
            // of the recognized article-container selectors, so a selector-only readiness
            // test never fires and the flow times out into archive.today even though the
            // real text is right there under the overlay. Treat substantial paragraph
            // prose under an <h1> as ready too (mirrors the Safari extension's
            // `looksLikeArticle`); the whole-document extraction + readable-length gate
            // downstream are still the final authority, so a short teaser is rejected.
            var ps = document.querySelectorAll('p'), textLen = 0;
            for (var i = 0; i < ps.length; i++) { textLen += (ps[i].innerText || '').length; }
            if (textLen > 1500 && document.querySelector('h1')) { return 'content-root'; }
            // No article rendered yet — NOW a real access CAPTCHA blocking the page matters,
            // so reveal it for the user to solve.
            if (document.querySelector(
                'iframe[src*="captcha-delivery.com"], iframe[src*="geo.captcha-delivery"], '
                + '#captcha__frame, iframe[src*="recaptcha"], iframe[src*="challenges.cloudflare.com"], '
                + 'iframe[src*="hcaptcha.com"], .g-recaptcha, [data-sitekey], .cf-turnstile, '
                + '#cf-challenge-running')) { return 'challenge'; }
            if (/verification required|verify (you are|you're)( a)? human|complete the security check|please verify you are (a )?human|checking your browser|why do i have to complete a captcha/i.test(t)) {
                return 'challenge';
            }
            return t;
        })()
        """
        webView.evaluateJavaScript(probe) { [weak self] result, _ in
            guard let self, self.isAttemptingDirectBypass, !self.didExtract, !self.isExtracting else { return }
            let text = (result as? String) ?? ""
            // A CAPTCHA is up on the site itself → reveal the page so the user can
            // solve it, and PAUSE the pre-stage timeout while they do (so it doesn't
            // give up and fall through to archive.today mid-solve).
            if text == "challenge" {
                if !self.loadingOverlay.isHidden {
                    SharedDiagnosticLog.record(
                        "archive: pre-stage CAPTCHA → revealing page for the user", category: "archive")
                }
                self.loadingOverlay.isHidden = true
                self.sawPreStageChallenge = true
                self.bypassPollCount = 0
                return
            }
            // The CAPTCHA just cleared: the site's own post-CAPTCHA reload dropped our
            // referer, so re-issue the article request ONCE — now with the clearance
            // cookie set AND the referer the site unlocks for (e.g. WSJ → Drudge).
            if self.sawPreStageChallenge, !self.didPostChallengeReload,
               self.directUnlockReferer != nil {
                self.didPostChallengeReload = true
                SharedDiagnosticLog.record(
                    "archive: CAPTCHA cleared → reloading article with referer", category: "archive")
                self.loadingOverlay.isHidden = false
                self.loadCurrentPreStage()   // reloads the article URL with the referer header
                return
            }
            // An automated step — keep the page covered and run the timeout.
            self.loadingOverlay.isHidden = false
            self.bypassPollCount += 1
            if self.bypassPollCount > Self.bypassPollLimit {
                self.advanceToNextPreStage()
                return
            }
            if Self.isJavaScriptRequiredGate(text: text) {
                SharedDiagnosticLog.record(
                    "archive: pre-stage is a JS-required gate → advancing", category: "archive")
                self.advanceToNextPreStage()
                return
            }
            guard text == "content-root" else { return }
            self.isExtracting = true
            self.extractAndSave()   // readable → save + onExtracted; not readable → resets, retries
        }
    }

    /// Whether `text` is a "please enable JavaScript" interstitial. Pure + static
    /// so it remains unit-testable if future first-party pre-stages are added.
    ///
    /// Gated on a SHORT body — a real, rendered article that happens to mention
    /// "JavaScript" (e.g. a tech post) is long, so it can't trip this. This is the
    /// generalized form of the archive.today "enable JS / disable ad blocker" gate:
    /// the ad-blocker phrase is NOT required, since most JS-required interstitials
    /// only mention JavaScript.
    public static func isJavaScriptRequiredGate(text: String) -> Bool {
        let lowercased = text.lowercased()
        guard lowercased.count < 800 else { return false }
        let mentionsJavaScript = lowercased.contains("enable javascript")
            || lowercased.contains("enable js")
            || lowercased.contains("javascript is required")
            || lowercased.contains("requires javascript")
            || lowercased.contains("please enable javascript")
        return mentionsJavaScript
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
        // Drop the paywall content-blocker before the archive.today flow so it can't
        // interfere with archive.today / the CAPTCHA assets.
        if usesDirectUnlock {
            webView.configuration.userContentController.removeAllContentRuleLists()
        }
        SharedDiagnosticLog.record(
            "archive: pre-stages didn't yield a readable article → archive.today flow", category: "archive")
        didLeaveHomepage = false
        isSubmittingHomepage = false
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
        webView.evaluateJavaScript(fill) { [weak self] result, _ in
            SharedDiagnosticLog.record(
                "archive: form submit result=\(result as? String ?? "nil")", category: "archive")
            if result as? String != "submitted" { self?.isSubmittingHomepage = false }
        }
    }

    /// A JS string literal with proper escaping (via JSON), e.g. `"https://…"`.
    private static func jsStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())   // strip the surrounding [ ]
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimating()
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { progress.stopAnimating() }

    // MARK: - Extraction

    /// Pulls the article out of the loaded snapshot's DOM and saves it to the item, so
    /// future opens use the fast in-app reader. The user keeps reading the web view now.
    private func extractAndSave() {
        guard let itemID else { isExtracting = false; return }
        let baseURL = articleURL
        // For the direct-unlock pre-stage the loaded page IS the real article, so hand
        // the WHOLE document to the extractor — exactly what the proven Safari hand-off
        // does. Pre-selecting a single `article`/`#CONTENT` node is fragile on sites
        // (WSJ) that wrap teaser cards in their OWN `<article>` — `querySelector` returns
        // that first, tiny node, whose body never clears the readable threshold, so the
        // real article is never recognized. It also drops the `<head>` (JSON-LD
        // `articleBody`, og:image) the extractor falls back on. The archive.today snapshot
        // flow keeps the node isolation, which walls off archive.today's own page chrome.
        let wholeDocument = isAttemptingDirectBypass
        let snapshotHTML = wholeDocument ? """
        (function () {
            return document.documentElement ? document.documentElement.outerHTML : null;
        })()
        """ : """
        (function () {
            var root = document.querySelector('article, [itemprop="articleBody"], main article, [class*="article-body"], #CONTENT');
            if (!root) { return null; }
            return '<html><head><title>' + document.title + '</title></head><body>' + root.outerHTML + '</body></html>';
        })()
        """
        webView.evaluateJavaScript(snapshotHTML) { [weak self] result, _ in
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
                    // Reveal the unlocked page so the user reads it (the main app keeps
                    // the loaded article up; extensions finish via `onExtracted`).
                    self.loadingOverlay.isHidden = true
                    _ = self.store.saveContent(content, for: item)
                    self.captureUnlockedWebArchive(for: item)
                    SharedDiagnosticLog.record(
                        "archive: extracted + saved (bodyLen=\(content.bodyTextLength))", category: "archive")
                    self.onExtracted?()
                }
            }
        }
    }

    /// Captures the fully-loaded, unlocked page now on screen as the item's
    /// `.webarchive`, so the reader's Original/archive mode shows the SAME full
    /// article the scroll/RSVP readers do. Without this, a paywalled save has no
    /// archive of its own: `OriginalPageViewController` falls back to re-loading the
    /// live URL — and `backfillMissingWebArchives` re-fetches it — both of which hit
    /// the paywall again and render only the truncated teaser. Capturing off THIS web
    /// view (which already holds every subresource of the unlocked snapshot) is the
    /// one moment the full page is in hand. Best-effort: a failure or a too-small
    /// archive leaves Original on its live-page fallback rather than saving a stub.
    private func captureUnlockedWebArchive(for item: ReadingListItem) {
        webView.createWebArchiveData { [weak self] result in
            guard let self, let data = try? result.get(), data.count > 1024 else { return }
            self.store.saveWebArchive(data, for: item)
            SharedDiagnosticLog.record(
                "archive: captured unlocked .webarchive (\(data.count) bytes)", category: "archive")
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

    /// Unlike a terminal archive error, this keeps the automation alive. It is a
    /// user-visible nudge after a long quiet period, with the same Safari escape.
    private func showStuckNotice() {
        guard !didShowStuckNotice, !didShowTerminalMessage else { return }
        didShowStuckNotice = true
        view.bringSubviewToFront(loadingOverlay)
        loadingOverlay.isHidden = false
        overlayLabel.text = Self.mayBeStuckMessage
        overlayLabel.textColor = .secondaryLabel
        overlaySafariButton.isHidden = (onOpenInBrowser == nil)
        overlaySpinner.startAnimating()
    }

    private static func isArchiveHomepageURL(_ url: URL?) -> Bool {
        guard let url, ArticleFetcher.isArchiveTodayURL(url) else { return false }
        return url.path.isEmpty || url.path == "/"
    }

    /// Surfaces a terminal message IN the overlay (not a popup): stops the spinner,
    /// shows the message text, and — in the main app — an Open-in-Safari escape.
    /// Stops polling so the flow can't re-cover or re-drive the page afterward.
    private func showTerminalMessage(_ message: String) {
        guard !didShowTerminalMessage else { return }
        didShowTerminalMessage = true
        pollTimer?.invalidate()
        pollTimer = nil
        progress.stopAnimating()
        view.bringSubviewToFront(loadingOverlay)
        loadingOverlay.isHidden = false
        overlaySpinner.stopAnimating()
        overlayLabel.text = message
        overlayLabel.textColor = .label
        overlaySafariButton.isHidden = (onOpenInBrowser == nil)
        loadingOverlay.backgroundColor = .systemBackground.withAlphaComponent(0.99)
    }
}
