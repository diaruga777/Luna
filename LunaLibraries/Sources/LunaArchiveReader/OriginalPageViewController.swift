//
//  OriginalPageViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import LunaModels
import UIKit
import WebKit

/// Displays source material captured at save time: a WebKit `.webarchive` for web
/// pages, or an imported source document such as a PDF. It never rebuilds a page
/// from parsed reader content. It prefers the locally captured artifact and only
/// reaches back to the network as a fallback, when a web save's `.webarchive`
/// capture is missing (so the always-offered Original mode is never blank).
public final class OriginalPageViewController: UIViewController, WKNavigationDelegate {
    private var item: ReadingListItem?
    private var store: ReadingListStore
    private let webView: WKWebView
    /// The archive's OWN scroll position to restore once its content finishes loading,
    /// kept fully disjoint from the scroll/RSVP reading position. Consumed once per load.
    private var pendingRestoreOffset: Double?
    /// When true this reader restores from / persists to `item.lastOriginalScrollOffset`
    /// itself (the plain reader path). RabbitHole leaves this false and drives the
    /// offset through its per-layer descriptor instead.
    private let persistsScrollOffset: Bool

    public init(item: ReadingListItem, store: ReadingListStore,
                savedScrollOffset: Double? = nil, persistsScrollOffset: Bool = false) {
        self.item = item
        self.store = store
        self.persistsScrollOffset = persistsScrollOffset
        self.pendingRestoreOffset = savedScrollOffset ?? (persistsScrollOffset ? item.lastOriginalScrollOffset : nil)
        let configuration = WKWebViewConfiguration()
        // A web archive is the captured page, not merely static HTML. Publishers such
        // as The New Yorker install their CSS and finish layout from deferred script
        // bundles; disabling JavaScript leaves the archived DOM present but unstyled
        // (often with large empty lazy-layout regions). The archive already contains
        // the scripts captured from the page, so replay it with normal WebKit page
        // semantics just as it rendered at capture time.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    /// Creates an empty, laid-out original/archive reader shell. RabbitHole uses this
    /// to keep WebKit construction off the link-tap path, then supplies the item when
    /// Original mode is actually selected.
    public convenience init(store: ReadingListStore = .shared) {
        self.init(item: ReadingListItem(urlString: "about:blank"), store: store)
        self.item = nil
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public var contentScrollView: UIScrollView { webView.scrollView }
    #if DEBUG
    /// Regression seam: archived pages that install layout/CSS from script must be
    /// replayed with JavaScript enabled.
    public var allowsContentJavaScriptForTesting: Bool {
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript
    }
    #endif
    /// The archive's current disjoint scroll offset, normalized to zero while
    /// the card's in-content title is still onscreen.
    public var currentScrollOffset: Double {
        ReaderScrollPosition.normalizedForPersistence(
            Double(webView.scrollView.contentOffset.y),
            titleHeaderHeight: Double(topContentInset))
    }

    /// Stable space at the top of the archive scroll surface for card-hosted
    /// chrome. Like the scroll reader's `topChromeInset`, this is content inset
    /// rather than a frame offset so a card can install its title inside the
    /// archive's actual scrolling content without relayout on immersion.
    public var topContentInset: CGFloat = 0 {
        didSet {
            guard abs(topContentInset - oldValue) > 0.5 else { return }
            applyTopContentInset()
        }
    }

    public func configure(item: ReadingListItem, store: ReadingListStore = .shared,
                          savedScrollOffset: Double? = nil) {
        self.item = item
        self.store = store
        self.pendingRestoreOffset = savedScrollOffset
        guard isViewLoaded else { return }
        webView.stopLoading()
        loadOriginal()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = LunaColors.background
        webView.scrollView.backgroundColor = LunaColors.background
        webView.underPageBackgroundColor = LunaColors.background
        webView.navigationDelegate = self
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        HorizonScrollIndicator.install(on: webView.scrollView, in: view)
        applyTopContentInset()

        loadOriginal()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard persistsScrollOffset, let item else { return }
        store.saveReaderExitPosition(lastOriginalScrollOffset: currentScrollOffset, for: item.id)
    }

    /// Restore the archive's own saved offset once its content has laid out. A tiny
    /// deferral lets the scroll view settle its content size first so the offset lands.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let offset = pendingRestoreOffset, offset > 0 else { return }
        pendingRestoreOffset = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let scroll = self.webView.scrollView
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: min(CGFloat(offset), maxY)), animated: false)
        }
    }

    private func loadOriginal() {
        guard let item else { return }
        let savedItem = store.item(withID: item.id) ?? item
        if let archiveURL = store.webArchiveURL(for: savedItem),
           let data = try? Data(contentsOf: archiveURL) {
            // `createWebArchiveData` documents this MIME type as loadable directly
            // in WKWebView. The base URL is only used for the archive's own origin.
            webView.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8",
                         baseURL: savedItem.url ?? archiveURL)
        } else if let documentURL = store.originalDocumentURL(for: savedItem) {
            webView.loadFileURL(documentURL, allowingReadAccessTo: store.articlesDirectory)
        } else if savedItem.isShareable, let liveURL = savedItem.url {
            // The save is a web page but its `.webarchive` capture is missing (still
            // downloading, or it failed). Fall back to the live page so the Original
            // mode — which the reader always offers for web saves — is never blank.
            webView.load(URLRequest(url: liveURL))
        }
    }

    private func applyTopContentInset() {
        webView.scrollView.contentInset.top = topContentInset
        webView.scrollView.verticalScrollIndicatorInsets.top = topContentInset
    }
}
