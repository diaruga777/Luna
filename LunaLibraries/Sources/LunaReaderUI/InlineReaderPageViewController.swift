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

/// Notifications an `InlineReaderPageViewController` sends its host
/// (`SplitWebOverlayViewController`) — link taps, article confirmation, title
/// changes, and scroll-surface swaps.
public protocol InlineReaderPageDelegate: AnyObject {
    /// A link was tapped inside the embedded reader, at its center in the page's
    /// coordinate space. The host pushes it as the next page in the stack,
    /// originating the next eclipse at the actual link.
    func page(_ page: InlineReaderPageViewController, didActivateLink url: URL, at point: CGPoint)
    /// Fired once the page is confirmed article-like (so the host can reveal the
    /// mode switcher for this page).
    func pageDidBecomeArticle(_ page: InlineReaderPageViewController)
    /// Fired when extraction or WebKit supplies a better tab title.
    func pageDidChangeMetadata(_ page: InlineReaderPageViewController)
    /// Fired whenever mode/probe work replaces the scroll surface so the
    /// overlay can retarget its card-edge hosted horizon indicator.
    func pageDidChangeContentScrollView(_ page: InlineReaderPageViewController)
}

/// One page in the inline reader's navigation stack (hosted by
/// `SplitWebOverlayViewController`). It loads a URL in a themed web view, probes the
/// page for article content off-main, and — when the page is article-like — swaps
/// the web view for the app's reader (mode-switchable). A link tapped inside the
/// embedded reader is handed up to the delegate so the host pushes it as a NEW page
/// rather than nesting another overlay; links in the raw web view navigate the web
/// view in place.
///
/// The content sits below the host's ancestor-tab strip. Mode and audio controls
/// remain in the outer reader's stable chrome and are routed to this page.
public final class InlineReaderPageViewController: UIViewController, WKNavigationDelegate {

    public let url: URL
    private var headerHeight: CGFloat

    public weak var delegate: InlineReaderPageDelegate?

    private let spinner = DotMatrixSpinnerView()
    private var articleProbe: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var articleContent: ArticleContent?
    private(set) var readerMode: ReadingListItem.ReaderMode = .scroll
    public private(set) var isAudioOn = false
    private weak var readerChild: UIViewController?
    private var readerTopConstraint: NSLayoutConstraint?
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

    /// The live vertically scrolling surface. RSVP intentionally returns nil.
    public var contentScrollView: UIScrollView? {
        if readerMode == .rsvp { return nil }
        if let webView { return webView.scrollView }
        guard let readerChild else { return nil }
        return Self.firstScrollView(in: readerChild.view)
    }

    public var displayTitle: String {
        let candidates = [articleContent?.title, webView?.title]
        if let title = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return title
        }
        return url.host?.replacingOccurrences(of: "www.", with: "")
            ?? L10n.string("Reader")
    }

    /// Keeps page content flush with the host's one-row or two-row chrome.
    public func setHeaderHeight(_ height: CGFloat) {
        headerHeight = max(height, 0)
        readerTopConstraint?.constant = headerHeight
        webView?.scrollView.contentInset.top = headerHeight
        webView?.scrollView.verticalScrollIndicatorInsets.top = headerHeight
    }

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
        delegate?.pageDidBecomeArticle(self)
        delegate?.pageDidChangeMetadata(self)
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
        // The host already supplies an exact chrome inset; automatic safe-area
        // adjustment would add the status-bar inset a second time.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
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
        HorizonScrollIndicator.install(on: webView.scrollView, in: view)
        delegate?.pageDidChangeContentScrollView(self)
        WebJunkBlocker.applyRuleList(to: webView.configuration.userContentController)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    /// Switches the embedded reader to `mode` (no-op unless this page is an article).
    public func setMode(_ mode: ReadingListItem.ReaderMode) {
        guard isArticle, mode != readerMode else { return }
        embedReader(mode: mode)
    }

    public func toggleAudio() {
        guard isArticle else { return }
        isAudioOn.toggle()
        embedReader(mode: readerMode)
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
        delegate?.pageDidBecomeArticle(self)
        delegate?.pageDidChangeMetadata(self)
    }

    private func removeReaderChild() {
        if let old = readerChild {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            readerChild = nil
            readerTopConstraint = nil
            delegate?.pageDidChangeContentScrollView(self)
        }
    }

    /// Tears down the live web view used by the Original/Web mode (not the initial
    /// non-article web view, which has no reader to switch back to).
    private func removeLiveWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        delegate?.pageDidChangeContentScrollView(self)
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
            let scroll = ScrollReaderViewController(
                item: transient, content: content, audioEnabled: isAudioOn)
            scroll.onLinkActivatedWithRange = { [weak self, weak scroll] url, range in
                guard let self, let scroll else { return }
                let point = scroll.view.convert(
                    scroll.linkActivationPoint(forCharacterRange: range), to: self.view)
                self.delegate?.page(self, didActivateLink: url, at: point)
            }
            child = scroll
        default:
            let rsvp = RSVPViewController(
                item: transient, content: content, audioEnabled: isAudioOn)
            rsvp.onLinkActivatedAtPoint = { [weak self] url, point in
                guard let self else { return }
                self.delegate?.page(self, didActivateLink: url, at: self.view.convert(point, from: rsvp.view))
            }
            child = rsvp
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        let topConstraint = child.view.topAnchor.constraint(
            equalTo: view.topAnchor, constant: headerHeight)
        NSLayoutConstraint.activate([
            topConstraint,
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
        readerChild = child
        readerTopConstraint = topConstraint
        (child as? ScrollReaderViewController)?
            .activateVisibleReader(deferFullContentUntilHostCompletion: false)
        readerMode = mode
        delegate?.pageDidChangeContentScrollView(self)
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if articleContent == nil { spinner.stopAnimating() }
        delegate?.pageDidChangeMetadata(self)
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }
    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { spinner.stopAnimating() }
}
