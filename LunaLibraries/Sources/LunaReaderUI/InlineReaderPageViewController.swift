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
    private(set) var readerMode: ReadingListItem.ReaderMode = .scroll
    private weak var readerChild: UIViewController?
    /// Created lazily after the article probe rules out native reader content.
    private var webView: WKWebView?
    /// Set once the probe has committed to reader OR web view (so neither is
    /// applied twice).
    private var didDecide = false
    private static let preloadRefreshInterval: TimeInterval = 48 * 60 * 60

    @MainActor
    private static var isApplicationActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    /// Whether this page is rendering as an article (so the mode switcher applies).
    public var isArticle: Bool { articleContent != nil }

    /// Cached article content available without a network request.
    private let cachedContent: ArticleContent?

    public init(url: URL, headerHeight: CGFloat) {
        self.url = url
        self.headerHeight = headerHeight
        let cached = PreloadStore.shared.synchronousArticleContent(for: url)
        self.cachedContent = (cached?.isArticleLike == true) ? cached : nil
        super.init(nibName: nil, bundle: nil)
        if let cachedContent {
            articleContent = cachedContent
            SharedDiagnosticLog.record(
                "rendered from cache (sync, no network blocked display): \(url.absoluteString)",
                category: "preload-tap")
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

        if let cachedContent {
            embedCachedReader(cachedContent)
            return
        }

        SharedDiagnosticLog.record(
            "MISS → awaiting network: \(url.absoluteString)", category: "preload-tap")
        spinner.startAnimating()
        probeForArticle()
    }

    /// Synchronously shows the reader for content already in hand,
    /// then refreshes the on-disk cache in the background for next time.
    private func embedCachedReader(_ content: ArticleContent) {
        didDecide = true
        articleContent = content
        embedReader(mode: readerMode)
        SharedDiagnosticLog.record(
            "content ready from cache: \(url.absoluteString)",
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

    /// Switches the embedded reader to `mode` (no-op unless this page is an article).
    public func setMode(_ mode: ReadingListItem.ReaderMode) {
        guard isArticle, mode != readerMode else { return }
        embedReader(mode: mode)
    }

    // MARK: - Article probe / reader embedding

    private func probeForArticle() {
        let target = url
        articleProbe = Task { [weak self] in
            // Resolve off the main thread and cache successful article extraction for
            // later opens. The current open remains dismissible while the spinner shows.
            let content: ArticleContent? = await Task.detached(priority: .userInitiated) {
                await InlineReaderContentLoader.load(
                    url: target, owner: PreloadStore.tappedLinkOwner)
            }.value
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.isViewLoaded, !self.didDecide else { return }
                if let content, content.isArticleLike {
                    SharedDiagnosticLog.record(
                        "awaited network, now persisted to disk (next open instant): "
                        + "\(target.absoluteString)", category: "preload-tap")
                    self.showReader(content)
                } else {
                    SharedDiagnosticLog.record(
                        "awaited network, not article-like → web view: \(target.absoluteString)",
                        category: "preload-tap")
                    self.showWebView()
                }
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
            guard await Self.isApplicationActive else { return }
            guard let html = try? await ArticleFetcher().fetchHTML(from: target),
                  !Task.isCancelled,
                  let fresh = try? ArticleExtractor().extract(html: html, baseURL: target),
                  fresh.isArticleLike,
                  await Self.isApplicationActive
            else { return }
            PreloadStore.shared.refreshArticle(for: target, content: fresh)
        }
    }

    @objc private func cancelRefreshForBackground() {
        refreshTask?.cancel()
        refreshTask = nil
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
        (child as? ScrollReaderViewController)?
            .activateVisibleReader(deferFullContentUntilHostCompletion: false)
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
