//
//  PlatformEmbedViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import UIKit
import WebKit

/// Generalized in-app embed player (a WKWebView loading a platform's embed URL,
/// 16:9, with a close button). Optional `Referer` and an "ended" user-script
/// that marks the item read + dismisses.
public final class PlatformEmbedViewController: UIViewController, WKScriptMessageHandler {

    private let embed: PlatformEmbed
    private let itemID: UUID
    private var webView: WKWebView?

    public init(embed: PlatformEmbed, itemID: UUID) {
        self.embed = embed
        self.itemID = itemID
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        webView?.stopLoading()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if let endedJS = embed.endedWatcherJS {
            configuration.userContentController.add(WeakScriptMessageHandler(target: self), name: "player")
            configuration.userContentController.addUserScript(WKUserScript(
                source: endedJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        self.webView = webView

        let closeButton = UIButton(type: .system)
        closeButton.setImage(
            UIImage(systemName: "xmark.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)), for: .normal)
        closeButton.tintColor = .white
        closeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            dismiss(animated: true)
        }, for: .touchUpInside)

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

        var request = URLRequest(url: embed.url)
        if let referer = embed.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        webView.load(request)
    }

    public func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == "player", message.body as? String == "ended" else { return }
        SavesStore.shared.markReadState(.read, for: itemID)
        dismiss(animated: true)
    }

    /// Watches the embed page's `<video>` element and posts "ended" natively.
    public static let endedWatcherJS = """
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
}
