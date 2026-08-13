//
//  WebPageViewController.swift
//  LunaDesignSystem
//

import UIKit
import WebKit

/// A plain full-screen `WKWebView` on one URL, with the same chrome as the
/// archive unlock flow: **Done** top-left, an **Open in Safari** compass
/// top-right. Nothing else — no extraction, no polling, no paywall machinery.
///
/// Distinct from `InAppBrowser` (an `SFSafariViewController` sheet) on purpose:
/// the failed-save card wants Luna's own frame around the page it couldn't
/// read, and a real `WKWebView` frequently renders what a background
/// `URLSession` fetch could not — a JS-gated page, a bot-blocked front door, a
/// cookie wall the user is already through. Seeing the page is often the whole
/// answer to "why did this fail".
///
/// Presented through `present(url:from:)`, which supplies the navigation
/// controller the bar buttons need.
public final class WebPageViewController: UIViewController {

    private let url: URL
    private let webView: WKWebView
    private let progress = HorizonSpinnerView()

    public init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()   // the user's own cookies/logins
        configuration.allowsInlineMediaPlayback = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        title = url.host

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "safari"),
            primaryAction: UIAction { [weak self] _ in self?.openInBrowser() })

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
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

        progress.startAnimating()
        webView.load(URLRequest(url: url))
    }

    private func openInBrowser() {
        let target = webView.url ?? url
        dismiss(animated: true) {
            UIApplication.shared.open(target)
        }
    }

    /// Presents `url` full-screen inside its own navigation controller (which
    /// the Done / Safari bar buttons live in). Mirrors `ArchiveUnlockFlow.present`
    /// so both web surfaces are opened the same way.
    ///
    /// The bar buttons need no seam of their own: `dismiss(animated:)` on a
    /// pushed controller forwards to whoever presented the navigation
    /// controller.
    public static func present(url: URL, from presenter: UIViewController) {
        let controller = WebPageViewController(url: url)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        presenter.present(navigation, animated: true)
    }
}

extension WebPageViewController: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimating()
        if let pageTitle = webView.title, !pageTitle.isEmpty { title = pageTitle }
    }

    public func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        progress.stopAnimating()
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        progress.stopAnimating()
    }
}
