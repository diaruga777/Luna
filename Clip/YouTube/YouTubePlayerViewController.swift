//
//  YouTubePlayerViewController.swift
//  Clip
//

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

        webView.loadHTMLString(Self.playerHTML(videoID: videoID), baseURL: URL(string: "https://www.youtube.com"))
    }

    /// IFrame API shell: posts "ended" to the native side via the message handler.
    private static func playerHTML(videoID: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>html,body{margin:0;background:#000;height:100%}#player{width:100%;height:100%}</style>
        </head>
        <body>
          <div id="player"></div>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            function onYouTubeIframeAPIReady() {
              new YT.Player('player', {
                videoId: '\(videoID)',
                playerVars: { playsinline: 1, autoplay: 1, rel: 0 },
                events: {
                  onStateChange: function(event) {
                    if (event.data === YT.PlayerState.ENDED) {
                      window.webkit.messageHandlers.player.postMessage('ended');
                    }
                  }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }

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
