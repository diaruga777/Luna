//
//  InlineReaderPageViewController.swift
//  Clip
//

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
final class InlineReaderPageViewController: UIViewController, WKNavigationDelegate {

    let url: URL
    private let shareProvider: ReaderShareProviding?
    private let headerHeight: CGFloat

    /// Hands a link tapped inside the embedded reader to the host, which pushes it
    /// as the next page in the stack.
    var onLinkActivated: ((URL) -> Void)?
    /// Fired once the page is confirmed article-like (so the host can reveal the
    /// mode switcher for this page).
    var onBecameArticle: (() -> Void)?

    private let webView: WKWebView
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var articleProbe: Task<Void, Never>?
    private var articleContent: ArticleContent?
    private(set) var readerMode: ReadingListItem.ReaderMode = .scroll
    private weak var readerChild: UIViewController?

    /// Whether this page is rendering as an article (so the mode switcher applies).
    var isArticle: Bool { articleContent != nil }

    init(url: URL, shareProvider: ReaderShareProviding?, headerHeight: CGFloat) {
        self.url = url
        self.shareProvider = shareProvider
        self.headerHeight = headerHeight
        self.webView = WKWebView(frame: .zero, configuration: WebJunkBlocker.makeConfiguration())
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { articleProbe?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let themed = ReaderDepth.backgroundColor(for: 0)
        view.backgroundColor = themed

        // Themed, non-opaque web view: no white flash before load, and dark-capable
        // sites render dark when the device is in dark mode (the web view inherits
        // the app's interface style).
        webView.isOpaque = false
        webView.backgroundColor = themed
        webView.scrollView.backgroundColor = themed
        webView.underPageBackgroundColor = themed
        webView.scrollView.contentInset.top = headerHeight
        webView.scrollView.verticalScrollIndicatorInsets.top = headerHeight
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: headerHeight / 2),
        ])

        WebJunkBlocker.applyRuleList(to: webView.configuration.userContentController)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
        probeForArticle()
    }

    /// Switches the embedded reader to `mode` (no-op unless this page is an article).
    func setMode(_ mode: ReadingListItem.ReaderMode) {
        guard isArticle, mode != readerMode else { return }
        embedReader(mode: mode)
    }

    // MARK: - Article probe / reader embedding

    private func probeForArticle() {
        let target = url
        articleProbe = Task { [weak self] in
            let content: ArticleContent? = await Task.detached(priority: .userInitiated) {
                guard let html = try? await ArticleFetcher().fetchHTML(from: target) else { return nil }
                return try? ArticleExtractor().extract(html: html, baseURL: target)
            }.value
            guard let self, !Task.isCancelled, let content else { return }
            let blocks = content.blocks.filter { !$0.text.isEmpty }
            let totalText = blocks.reduce(0) { $0 + $1.text.count }
            guard totalText >= 600, blocks.count >= 3 else { return }   // article-like
            await MainActor.run { self.showReader(content) }
        }
    }

    private func showReader(_ content: ArticleContent) {
        guard isViewLoaded, articleContent == nil else { return }
        articleContent = content
        webView.stopLoading()
        webView.isHidden = true
        spinner.stopAnimating()
        embedReader(mode: readerMode)
        onBecameArticle?()
    }

    private func embedReader(mode: ReadingListItem.ReaderMode) {
        guard let content = articleContent else { return }
        if let old = readerChild {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        var transient = ReadingListItem(urlString: url.absoluteString)
        transient.state = .ready

        let child: UIViewController
        switch mode {
        case .scroll:
            let scroll = ScrollReaderViewController(item: transient, content: content, autoHighlight: false)
            scroll.onLinkActivated = { [weak self] in self?.onLinkActivated?($0) }
            child = scroll
        case .highlight:
            let scroll = ScrollReaderViewController(item: transient, content: content, autoHighlight: true)
            scroll.onLinkActivated = { [weak self] in self?.onLinkActivated?($0) }
            child = scroll
        case .rsvp:
            let rsvp = RSVPViewController(item: transient, content: content)
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if articleContent == nil { spinner.stopAnimating() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) { spinner.stopAnimating() }
}
