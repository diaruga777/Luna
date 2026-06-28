//
//  YouTubePlayerViewController.swift
//  Clip
//

import ClipStorage
import UIKit
import WebKit

/// In-app YouTube playback via the IFrame Player API in a WKWebView, used when
/// the YouTube app isn't installed. Inline playback with the native fullscreen
/// controls (PiP is available from there on supported devices). When the video
/// ends, the item is marked read and the player dismisses.
final class YouTubePlayerViewController: UIViewController, WKScriptMessageHandler {

    private let videoID: String
    private let itemID: UUID
    private var webView: WKWebView?

    init(videoID: String, itemID: UUID) {
        self.videoID = videoID
        self.itemID = itemID
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "player")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "player")
        // The embed page is loaded directly (its own youtube.com origin —
        // loadHTMLString origins get rejected with error 152/153), so the
        // ended signal comes from the page's <video> element.
        let endedWatcher = WKUserScript(
            source: Self.endedWatcherJS, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true)
        configuration.userContentController.addUserScript(endedWatcher)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        self.webView = webView

        let closeButton = UIButton(type: .system)
        let closeImage = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30))
        closeButton.setImage(closeImage, for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        webView.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            webView.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9.0 / 16.0),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])

        var embedComponents = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")
        embedComponents?.queryItems = [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
        ]
        if let embedURL = embedComponents?.url {
            var request = URLRequest(url: embedURL)
            // YouTube rejects embeds without a referrer (error 153).
            request.setValue("https://clip-reader.app/", forHTTPHeaderField: "Referer")
            webView.load(request)
        }
    }

    /// Watches the embed page's <video> element and posts "ended" natively.
    private static let endedWatcherJS = """
        (function() {
          function attach() {
            var video = document.querySelector('video');
            if (!video) { setTimeout(attach, 500); return; }
            video.addEventListener('ended', function() {
              window.webkit.messageHandlers.player.postMessage('ended');
            });
          }
          attach();
        })();
        """

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "player", message.body as? String == "ended" else { return }
        ReadingListStore.shared.markReadState(.read, for: itemID)
        dismiss(animated: true)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
