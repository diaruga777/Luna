//
//  OriginalPageViewController.swift
//  Clip
//

import UIKit
import WebKit

/// Displays the page snapshot written at ingest time. The web view only receives a
/// file URL inside the app-group Articles directory, so changing into this mode
/// never waits on (or replays) the publisher request.
final class OriginalPageViewController: UIViewController {
    private let item: ReadingListItem
    private let content: ArticleContent
    private let store: ReadingListStore
    private let webView: WKWebView

    init(item: ReadingListItem, content: ArticleContent, store: ReadingListStore) {
        self.item = item
        self.content = content
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
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

        loadSnapshot()
    }

    private func loadSnapshot() {
        var savedItem = store.item(withID: item.id) ?? item
        if store.originalPageURL(for: savedItem) == nil {
            store.saveOriginalPage(OfflinePageArchive.make(content: content), for: savedItem)
            savedItem = store.item(withID: item.id) ?? savedItem
        }
        if let pageURL = store.originalPageURL(for: savedItem) {
            webView.loadFileURL(pageURL, allowingReadAccessTo: store.articlesDirectory)
        } else {
            // The action extension reads a transient item that is not in the main
            // list. It still gets the same offline snapshot, just without writing
            // a list entry that it does not own.
            webView.loadHTMLString(OfflinePageArchive.make(content: content), baseURL: store.articlesDirectory)
        }
    }
}
