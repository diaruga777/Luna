//
//  SavedNonTextualViewController.swift
//  ClipShare
//

import UIKit
import WebKit

/// Shown by the action extension for non-textual content (a video, etc.): the
/// URL is already saved to Click, so instead of the text reader we embed the
/// content for in-place playback and offer "Open in Click" (which launches the
/// main app via the `clickreader://` deep link). Done dismisses the extension.
final class SavedNonTextualViewController: UIViewController {

    private let articleURLString: String
    private let content: NonTextualContent
    private let onDone: () -> Void
    private var webView: WKWebView?

    init(articleURLString: String, content: NonTextualContent, onDone: @escaping () -> Void) {
        self.articleURLString = articleURLString
        self.content = content
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { webView?.stopLoading() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Saved to Click"

        let onDone = self.onDone
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in onDone() })

        // A confirmation badge with a checkmark + the platform name.
        let badge = UIImageView(image: UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)))
        badge.tintColor = GlassStyle.readingAccent
        badge.contentMode = .center

        let savedLabel = UILabel()
        savedLabel.text = "Saved \(content.kindLabel) to your Click reading list."
        savedLabel.font = .preferredFont(forTextStyle: .body)
        savedLabel.textColor = .secondaryLabel
        savedLabel.textAlignment = .center
        savedLabel.numberOfLines = 0

        var openConfig = UIButton.Configuration.filled()
        openConfig.title = "Open in Click"
        openConfig.image = UIImage(systemName: "arrow.up.forward.app")
        openConfig.imagePadding = 8
        openConfig.baseBackgroundColor = GlassStyle.readingAccent
        let openButton = UIButton(configuration: openConfig)
        openButton.addAction(UIAction { [weak self] _ in self?.openInApp() }, for: .touchUpInside)

        // YouTube embeds play inline; other platforms show the confirmation badge.
        let topView: UIView
        if let embedURL = content.embedURL {
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = []
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.isOpaque = false
            webView.backgroundColor = .black
            webView.scrollView.isScrollEnabled = false
            webView.layer.cornerRadius = 12
            webView.clipsToBounds = true
            webView.heightAnchor.constraint(equalTo: webView.widthAnchor, multiplier: 9.0 / 16.0).isActive = true
            self.webView = webView
            topView = webView
            var request = URLRequest(url: embedURL)
            request.setValue(content.embedReferer, forHTTPHeaderField: "Referer")
            webView.load(request)
        } else {
            topView = badge
        }

        let stack = UIStackView(arrangedSubviews: [topView, savedLabel, openButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    /// Opens the saved item in the main app via the deep link. `extensionContext.
    /// open` is the only sanctioned way to leave an extension; if the host
    /// declines it (returns false) we leave the user on this screen.
    private func openInApp() {
        guard let deepLink = ClickDeepLink.readLink(forArticleURL: articleURLString) else { return }
        extensionContext?.open(deepLink) { [weak self] success in
            if success { self?.onDone() }
        }
    }
}
