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
/// pages, or an imported source document such as a PDF. It prefers the locally
/// captured artifact and falls back to a self-contained, styled snapshot of the
/// saved article content. It never loads a publisher URL: "Original" stays an
/// offline saved-document viewer even when archive capture failed or a legacy
/// archive is unsafe or unreadable.
public final class OriginalPageViewController: UIViewController, WKNavigationDelegate {
    private var item: ReadingListItem?
    private var store: ReadingListStore
    private let webView: WKWebView
    private enum LoadedDocument: Equatable {
        case archive
        case articleSnapshot
        case sourceDocument
        case unavailable
    }
    private var loadedDocument: LoadedDocument?
    private var didValidateCurrentArchive = false
    private var loadGeneration = 0
    private var currentNavigation: WKNavigation?
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
        let configuration = SavedArchiveWebConfiguration.makeReplayConfiguration()
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
    public var loadedDocumentForTesting: String? {
        switch loadedDocument {
        case .archive: return "archive"
        case .articleSnapshot: return "articleSnapshot"
        case .sourceDocument: return "sourceDocument"
        case .unavailable: return "unavailable"
        case nil: return nil
        }
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

    /// A frozen archive can still be a historical no-style capture. Inspect the
    /// actual computed article typography after load and switch to the local saved
    /// snapshot when WebKit only produced its default 16px Times document.
    ///
    /// Restore the saved offset only after that decision, so an archive-to-snapshot
    /// fallback doesn't consume the pending position on the discarded page.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let currentNavigation, navigation !== currentNavigation { return }
        if loadedDocument == .archive, !didValidateCurrentArchive {
            didValidateCurrentArchive = true
            validateRenderedArchive(generation: loadGeneration)
            return
        }
        restorePendingOffset()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Initial programmatic archive/document loads are `.other`. User clicks,
        // form submissions, and reload gestures must not turn the offline viewer
        // into a live browser.
        if navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType != .other {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    private func restorePendingOffset() {
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
        loadGeneration += 1
        let savedItem = store.item(withID: item.id) ?? item
        didValidateCurrentArchive = false
        performLoad(savedItem: savedItem)
    }

    private func performLoad(savedItem: ReadingListItem) {
        let content = store.content(for: savedItem)
        if let archiveURL = store.webArchiveURL(for: savedItem),
           let data = try? Data(contentsOf: archiveURL),
           let replayData = WebArchiveSanitizer.sanitized(data),
           content.map({
               WebArchiveSanitizer.containsReadableArticle(replayData, content: $0)
           }) ?? true {
            // Older archives may still contain the publisher's executable bundles.
            // Sanitize in memory on every replay. If sanitization fails, never load
            // the raw artifact; fall through to the local saved-content snapshot.
            loadedDocument = .archive
            // `createWebArchiveData` documents this MIME type as loadable directly
            // in WKWebView. The base URL is only used for the archive's own origin.
            currentNavigation = webView.load(
                replayData, mimeType: "application/x-webarchive",
                characterEncodingName: "utf-8", baseURL: savedItem.url ?? archiveURL)
        } else if let documentURL = store.originalDocumentURL(for: savedItem) {
            loadedDocument = .sourceDocument
            currentNavigation = webView.loadFileURL(
                documentURL, allowingReadAccessTo: store.articlesDirectory)
        } else if let content {
            loadArticleSnapshot(content, for: savedItem)
        } else {
            loadedDocument = .unavailable
            currentNavigation = webView.loadHTMLString(Self.unavailableHTML, baseURL: nil)
        }
    }

    private func validateRenderedArchive(generation: Int) {
        let script = """
        (function () {
          var candidates = Array.from(document.querySelectorAll(
            'article p, main p, [data-testid="BodyWrapper"] p, .article__body p'));
          var sample = candidates.find(function (p) {
            return (p.textContent || '').trim().length > 80;
          });
          if (!sample) { return false; }
          var style = getComputedStyle(sample);
          var size = parseFloat(style.fontSize || '0');
          var line = parseFloat(style.lineHeight || '0');
          var family = (style.fontFamily || '').toLowerCase();
          var defaultFamily = family.indexOf('times') >= 0;
          var defaultMetrics = size <= 16.1 && (!line || line <= 20);
          return !(defaultFamily && defaultMetrics);
        })()
        """
        let timeout = DispatchWorkItem { [weak self] in
            self?.handleArchiveValidation(false, generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            timeout.cancel()
            self?.handleArchiveValidation(
                result as? Bool == true, generation: generation)
        }
    }

    private func handleArchiveValidation(_ rendersWell: Bool, generation: Int) {
        guard generation == loadGeneration, loadedDocument == .archive else { return }
        if rendersWell {
            restorePendingOffset()
        } else if let item {
            let savedItem = store.item(withID: item.id) ?? item
            if let content = store.content(for: savedItem) {
                loadArticleSnapshot(content, for: savedItem)
            } else {
                restorePendingOffset()
            }
        }
    }

    private func loadArticleSnapshot(
        _ content: ArticleContent,
        for item: ReadingListItem
    ) {
        loadedDocument = .articleSnapshot
        didValidateCurrentArchive = true
        let html = SavedArticleSnapshotRenderer.html(
            content: content,
            sourceURL: item.url,
            imagesDirectory: store.articlesDirectory)
        currentNavigation = webView.loadHTMLString(html, baseURL: nil)
    }

    private static let unavailableHTML = """
    <!doctype html><html><head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <style>
        :root { color-scheme: light dark; }
        body { margin: 32px; color: CanvasText; background: Canvas;
               font: 17px/1.5 -apple-system, sans-serif; }
      </style>
    </head><body><p>This saved source is unavailable.</p></body></html>
    """

    private func applyTopContentInset() {
        webView.scrollView.contentInset.top = topContentInset
        webView.scrollView.verticalScrollIndicatorInsets.top = topContentInset
    }
}
