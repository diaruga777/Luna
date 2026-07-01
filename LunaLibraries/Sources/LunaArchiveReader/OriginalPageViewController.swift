//
//  OriginalPageViewController.swift
//  Luna
//

import LunaStorage
import LunaModels
import UIKit
import WebKit

/// Displays source material captured at save time: a WebKit `.webarchive` for web
/// pages, or an imported source document such as a PDF. It never rebuilds a page
/// from parsed reader content. It prefers the locally captured artifact and only
/// reaches back to the network as a fallback, when a web save's `.webarchive`
/// capture is missing (so the always-offered Original mode is never blank).
public final class OriginalPageViewController: UIViewController {
    private var item: ReadingListItem?
    private var store: ReadingListStore
    private let webView: WKWebView

    public init(item: ReadingListItem, store: ReadingListStore) {
        self.item = item
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
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

    public func configure(item: ReadingListItem, store: ReadingListStore = .shared) {
        self.item = item
        self.store = store
        guard isViewLoaded else { return }
        webView.stopLoading()
        loadOriginal()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        loadOriginal()
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
}
