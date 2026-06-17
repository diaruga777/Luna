//
//  SavedNonTextualViewController.swift
//  ClipShare
//

import UIKit
import WebKit

/// Shown by the action extension for non-textual content (a video, post, etc.):
/// the URL is already saved, so this confirms the save ("Saved to your reading
/// list") and — for shareable links, when there are friends — offers to send it
/// to a friend. The send is QUEUED to the App Group and performed by the app on
/// next launch (the extension has no CloudKit/crypto). No eBook / system share
/// here. YouTube embeds still play inline. Done dismisses the extension.
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

        let badge = UIImageView(image: UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)))
        badge.tintColor = GlassStyle.readingAccent
        badge.contentMode = .center

        let savedLabel = UILabel()
        savedLabel.text = "Saved to your reading list."
        savedLabel.font = .preferredFont(forTextStyle: .body)
        savedLabel.textColor = .secondaryLabel
        savedLabel.textAlignment = .center
        savedLabel.numberOfLines = 0

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

        let arranged: [UIView] = [topView, savedLabel] + shareButtons()
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(24, after: savedLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    /// A "Send to a Friend" button when the link is shareable and friends exist.
    /// (The extension has no share-suggestion engine, so there's no one-tap
    /// suggested friend; the picker covers choosing who to send to.)
    private func shareButtons() -> [UIView] {
        guard articleURLString.hasPrefix("http"), !ExtensionFriendsReader.friends().isEmpty else {
            return []
        }
        // Muted (tinted, not a bright filled accent) so the confirmation stays calm.
        var config = UIButton.Configuration.tinted()
        config.title = "Send to a Friend…"
        config.image = UIImage(systemName: "person.2.fill")
        config.imagePadding = 8
        config.baseBackgroundColor = .secondaryLabel
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.presentFriendPicker() }, for: .touchUpInside)
        return [button]
    }

    private func presentFriendPicker() {
        let friends = ExtensionFriendsReader.friends()
        let sheet = UIAlertController(
            title: "Send to a Friend",
            message: "They'll get it in their Click reading list when you next open Click.",
            preferredStyle: .actionSheet)
        for friend in friends {
            sheet.addAction(UIAlertAction(title: friend.username, style: .default) { [weak self] _ in
                guard let self else { return }
                PendingFriendShareWriter.enqueue(friendUUID: friend.uuid, urlString: self.articleURLString)
                self.confirmQueued(friendName: friend.username)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func confirmQueued(friendName: String) {
        let alert = UIAlertController(
            title: "Will Send to \(friendName)",
            message: "Open Click to finish sending.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.onDone() })
        present(alert, animated: true)
    }
}
