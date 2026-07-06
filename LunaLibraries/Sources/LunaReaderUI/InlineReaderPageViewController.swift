//
//  InlineReaderPageViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import LunaFetch
import LunaHTMLClassification
import LunaModels
import UIKit
import WebKit

/// One page in the inline reader's navigation stack (hosted by
/// `SplitWebOverlayViewController`). It loads a URL in a themed web view, probes the
/// page for article content off-main, and — when the page is article-like — swaps
/// the web view for the app's reader (mode-switchable). A link tapped inside the
/// embedded reader is handed up via `onLinkActivated` so the host pushes it as a
/// NEW page rather than nesting another overlay; links in the raw web view navigate
/// the web view in place.
///
/// The content sits below the host's floating glass header (a top content inset on
/// the web view; the reader child is pinned below the header), so the header always
/// reads over the page.
public final class InlineReaderPageViewController: UIViewController, WKNavigationDelegate {

    public let url: URL
    private let headerHeight: CGFloat

    /// Hands a link tapped inside the embedded reader to the host, which pushes it
    /// as the next page in the stack.
    public var onLinkActivated: ((URL) -> Void)?
    /// Fired once the page is confirmed article-like (so the host can reveal the
    /// mode switcher for this page).
    public var onBecameArticle: (() -> Void)?

    private let spinner = DotMatrixSpinnerView()
    private var articleProbe: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var articleContent: ArticleContent?
    /// What the probe decided (reader vs raw web). Stashed because the probe is
    /// kicked off in `init` to overlap the host's open animation, so it can finish
    /// before `viewDidLoad` has built the view to show it in.
    private enum ProbeDecision { case reader(ArticleContent); case web }
    private var pendingDecision: ProbeDecision?
    private(set) var readerMode: ReadingListItem.ReaderMode = .scroll
    private weak var readerChild: UIViewController?
    /// Created LAZILY in `showWebView` (not init) — instantiating a WKWebView spins
    /// up the web content process, which would lag the overlay's open animation.
    private var webView: WKWebView?
    /// Set once the probe has committed to reader OR web view (so neither is
    /// applied twice).
    private var didDecide = false
    private static let preloadRefreshInterval: TimeInterval = 48 * 60 * 60

    /// Whether this page is rendering as an article (so the mode switcher applies).
    public var isArticle: Bool { articleContent != nil }

    /// A preloaded article resolved synchronously in `init` (no spinner ever shows).
    /// nil when the page wasn't in the preload cache (memory or disk).
    private let preloadedContent: ArticleContent?

    public init(url: URL, headerHeight: CGFloat) {
        self.url = url
        self.headerHeight = headerHeight
        // Synchronous preload check FIRST (in-memory hit, else a size-bounded disk
        // decode): if this link was preloaded, we have its content right now and can
        // render the reader on the first frame with no spinner — even on the first tap
        // after a relaunch (cold memory cache, warm disk). Only a genuine miss kicks
        // off the async fetch+probe (which shows the spinner). This is the whole point
        // of preloading — an instant open.
        let cached = PreloadStore.shared.synchronousArticleContent(for: url)
        self.preloadedContent = (cached?.isArticleLike == true) ? cached : nil
        super.init(nibName: nil, bundle: nil)
        if let preloadedContent {
            articleContent = preloadedContent   // marks isArticle for the host header
            SharedDiagnosticLog.record(
                "rendered from cache (sync, no network blocked display): \(url.absoluteString)",
                category: "preload-tap")
        } else {
            SharedDiagnosticLog.record(
                "MISS → awaiting network (spinner will show this first open only): \(url.absoluteString)",
                category: "preload-tap")
            // Begin fetching immediately so the network round-trip overlaps the host's
            // open animation rather than starting only once the view has loaded.
            probeForArticle()
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        articleProbe?.cancel()
        refreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReaderDepth.backgroundColor(for: 0)
        NotificationCenter.default.addObserver(
            self, selector: #selector(cancelRefreshForBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: headerHeight / 2),
        ])

        // Preloaded? Render the reader on the first frame — no spinner, no async hop.
        if let preloadedContent {
            embedPreloadedReader(preloadedContent)
            return
        }

        // Cache miss: show ONLY a themed background + spinner until the probe decides
        // reader vs web view — never flash the raw web view first then swap to reader.
        spinner.startAnimating()
        // The probe (kicked off in init) may already have a decision waiting.
        applyDecisionIfPossible()
    }

    /// Synchronously shows the reader for content already in hand (a preload hit),
    /// then refreshes the on-disk cache in the background for next time.
    private func embedPreloadedReader(_ content: ArticleContent) {
        didDecide = true
        articleContent = content
        embedReader(mode: readerMode)
        // Content is fully embedded/laid out on this (the first) frame, BEFORE the
        // host's open animation runs in `viewIsAppearing` — so the pixelated transition
        // reveals already-loaded content, never a spinner.
        SharedDiagnosticLog.record(
            "content ready (laid out before transition begins): \(url.absoluteString)",
            category: "preload-tap")
        onBecameArticle?()
        refreshPreloadedCache(url)
    }

    /// Adds and loads the themed web view (only once the probe rules OUT a reader),
    /// keeping the spinner until the first navigation finishes.
    private func showWebView() {
        guard isViewLoaded, !didDecide else { return }
        didDecide = true
        installWebView()
    }

    /// Builds + loads the themed live web view (idempotent). Used both for the
    /// initial "not an article" decision and the article switcher's Original/Web mode.
    private func installWebView() {
        guard webView == nil else { return }
        // Create the (expensive) web view only now that we know we need it.
        let webView = WKWebView(frame: .zero, configuration: WebJunkBlocker.makeConfiguration())
        self.webView = webView
        let themed = ReaderDepth.backgroundColor(for: 0)
        // Non-opaque + themed: no white flash, and dark-capable sites render dark
        // when the device is in dark mode (the web view inherits the app's style).
        webView.isOpaque = false
        webView.backgroundColor = themed
        webView.scrollView.backgroundColor = themed
        webView.underPageBackgroundColor = themed
        webView.scrollView.contentInset.top = headerHeight
        webView.scrollView.verticalScrollIndicatorInsets.top = headerHeight
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, belowSubview: spinner)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        WebJunkBlocker.applyRuleList(to: webView.configuration.userContentController)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    /// The host's open animation has finished — tell the embedded scroll reader to do
    /// its progressive-load Phase 2 (render the full article + swap it in) now, so the
    /// heavy glyph generation lands AFTER the open rather than stalling behind it.
    /// No-op unless the embedded child is the scroll reader (idempotent there).
    public func entryAnimationDidFinish() {
        (readerChild as? ScrollReaderViewController)?.prepareFullContent()
    }

    /// Switches the embedded reader to `mode` (no-op unless this page is an article).
    public func setMode(_ mode: ReadingListItem.ReaderMode) {
        guard isArticle, mode != readerMode else { return }
        embedReader(mode: mode)
    }

    // MARK: - Article probe / reader embedding

    private func probeForArticle() {
        let target = url
        articleProbe = Task { [weak self] in
            // Everything off the main thread so the spinner never blocks the UI (the
            // overlay stays dismissable). `materialize` first reuses an existing cache
            // entry (a within-session warm); on a genuine miss it fetches + extracts +
            // downloads images + PERSISTS the result to disk under the durable
            // `tappedLinkOwner`, so the NEXT open of this tapped link — this session OR
            // after a relaunch — is an instant synchronous cache hit (no spinner ever
            // again). The very first open of a never-before-seen link is the only one
            // that can await the network.
            let content: ArticleContent? = await Task.detached(priority: .userInitiated) {
                await RabbitHolePreloader.materialize(
                    url: target, owner: PreloadStore.tappedLinkOwner)
            }.value
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                if let content, content.isArticleLike {
                    SharedDiagnosticLog.record(
                        "awaited network, now persisted to disk (next open instant): "
                        + "\(target.absoluteString)", category: "preload-tap")
                    self.pendingDecision = .reader(content)
                } else {
                    SharedDiagnosticLog.record(
                        "awaited network, not article-like → web view: \(target.absoluteString)",
                        category: "preload-tap")
                    self.pendingDecision = .web   // not article-like → show the page
                }
                self.applyDecisionIfPossible()
            }
        }
    }

    /// Re-fetches a preloaded article in the background and updates its on-disk cache
    /// so the NEXT open is fresh. Does not disturb the currently-shown reader.
    private func refreshPreloadedCache(_ target: URL) {
        guard UIApplication.shared.applicationState == .active,
              PreloadStore.shared.articleRefreshDue(
                for: target, minimumAge: Self.preloadRefreshInterval)
        else { return }
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) {
            guard UIApplication.shared.applicationState == .active else { return }
            guard let html = try? await ArticleFetcher().fetchHTML(from: target),
                  !Task.isCancelled,
                  let fresh = try? ArticleExtractor().extract(html: html, baseURL: target),
                  fresh.isArticleLike,
                  UIApplication.shared.applicationState == .active
            else { return }
            PreloadStore.shared.refreshArticle(for: target, content: fresh)
        }
    }

    @objc private func cancelRefreshForBackground() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Applies the probe's decision once the view exists to host it. Safe to call
    /// from either the probe completion or `viewDidLoad`, whichever happens last.
    private func applyDecisionIfPossible() {
        guard isViewLoaded, !didDecide, let decision = pendingDecision else { return }
        switch decision {
        case .reader(let content): showReader(content)
        case .web: showWebView()
        }
    }

    private func showReader(_ content: ArticleContent) {
        guard isViewLoaded, !didDecide else { return }
        didDecide = true
        articleContent = content
        spinner.stopAnimating()
        embedReader(mode: readerMode)
        onBecameArticle?()
    }

    private func removeReaderChild() {
        if let old = readerChild {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            readerChild = nil
        }
    }

    /// Tears down the live web view used by the Original/Web mode (not the initial
    /// non-article web view, which has no reader to switch back to).
    private func removeLiveWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private func embedReader(mode: ReadingListItem.ReaderMode) {
        guard let content = articleContent else { return }
        // Original/Web mode: show the live page in a web view instead of the reader.
        if mode == .original {
            guard readerMode != .original else { return }   // self-defend re-entry
            removeReaderChild()
            spinner.stopAnimating()
            installWebView()
            readerMode = mode
            return
        }
        removeLiveWebView()          // switching back from Original to a reader mode
        removeReaderChild()
        var transient = ReadingListItem(urlString: url.absoluteString)
        transient.state = .ready

        let child: UIViewController
        switch mode {
        case .scroll, .original:
            let scroll = ScrollReaderViewController(item: transient, content: content)
            scroll.onLinkActivated = { [weak self] in self?.onLinkActivated?($0) }
            child = scroll
        case .rsvp, .highlight:
            // The retired .highlight (chunking) view now lives as RSVP → Phrases.
            let rsvp = RSVPViewController(
                item: transient, content: content,
                initialDisplayMode: mode == .highlight ? .phrases : nil)
            rsvp.onLinkActivated = { [weak self] in self?.onLinkActivated?($0) }
            child = rsvp
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor, constant: headerHeight),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
        readerChild = child
        readerMode = mode
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if articleContent == nil { spinner.stopAnimating() }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }
    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { spinner.stopAnimating() }
}
