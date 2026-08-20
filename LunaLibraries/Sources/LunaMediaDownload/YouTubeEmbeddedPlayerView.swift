//
//  YouTubeEmbeddedPlayerView.swift
//  LunaMediaDownload
//

import LunaDesignSystem
import UIKit
import WebKit

/// Events Luna needs from the official YouTube iframe: readiness for live
/// verification and an error signal that swaps the surface back to its native
/// poster/open fallback.
@MainActor
public protocol YouTubeEmbeddedPlayerViewDelegate: AnyObject {
    func youTubeEmbeddedPlayerDidBecomeReady(_ player: YouTubeEmbeddedPlayerView)
    func youTubeEmbeddedPlayer(_ player: YouTubeEmbeddedPlayerView, didFailWithCode code: Int?)
}

public extension YouTubeEmbeddedPlayerViewDelegate {
    func youTubeEmbeddedPlayerDidBecomeReady(_ player: YouTubeEmbeddedPlayerView) {}
}

/// Shared thumbnail loading for every surface that represents a YouTube link.
/// The card's scrub-strip image and its full player placeholder therefore use
/// one decoded image rather than briefly re-downloading/re-decoding a still as
/// the carousel remounts a card.
@MainActor
public enum YouTubeThumbnailLoader {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 96
        return cache
    }()

    public static func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    public static func load(
        from url: URL, completion: @escaping (UIImage?) -> Void
    ) {
        if let image = cachedImage(for: url) {
            completion(image)
            return
        }
        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data)
            else {
                completion(nil)
                return
            }
            cache.setObject(image, forKey: url as NSURL)
            completion(image)
        }
    }
}

/// An official YouTube IFrame Player hosted in the system `WKWebView`.
///
/// YouTube requires embedded API clients to identify themselves through the
/// HTTP Referer. Their documented iOS/local-HTML integration is
/// `loadHTMLString(_:baseURL:)`, with an HTTPS URL whose host is the app's
/// bundle identifier. Loading `/embed/<id>` directly leaves WKWebView's Referer
/// empty and YouTube rejects it with player error 153.
@MainActor
public final class YouTubeEmbeddedPlayerView: UIView, WKScriptMessageHandler {

    public weak var delegate: (any YouTubeEmbeddedPlayerViewDelegate)?
    public let webView: WKWebView

    public init?(sourceURL: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard let document = YouTubeEmbeddedPlayerDocument(
            sourceURL: sourceURL, bundleIdentifier: bundleIdentifier)
        else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)

        configuration.userContentController.add(
            WeakScriptMessageHandler(target: self), name: Self.messageName)
        webView.isOpaque = false
        // Until YouTube renders its iframe, this view must stay transparent so
        // the card's cached thumbnail and centered-card spinner remain visible.
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        webView.loadHTMLString(document.html, baseURL: document.baseURL)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    deinit {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageName)
    }

    public func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName, let event = message.body as? String else { return }
        if event == "ready" {
            delegate?.youTubeEmbeddedPlayerDidBecomeReady(self)
            return
        }
        guard event.hasPrefix("error") else { return }
        let code = event.split(separator: ":", maxSplits: 1).last.flatMap { Int($0) }
        delegate?.youTubeEmbeddedPlayer(self, didFailWithCode: code)
    }

    private static let messageName = "lunaYouTubePlayer"
}

/// Pure document construction is separate so tests can pin the app identity,
/// inline player parameters, and timestamp handoff without loading the network.
struct YouTubeEmbeddedPlayerDocument {
    let html: String
    let baseURL: URL

    init?(sourceURL: URL, bundleIdentifier: String?) {
        guard let link = YouTubeLink(url: sourceURL), let videoID = link.videoID,
              let identifier = bundleIdentifier?.lowercased(),
              let baseURL = URL(string: "https://\(identifier)")
        else { return nil }
        self.baseURL = baseURL

        let start = Int(link.timeRange?.startSeconds ?? 0)
        let end = link.timeRange?.endSeconds.map(Int.init)
        let endLine = end.map { "end: \($0)," } ?? ""
        html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <meta name="referrer" content="strict-origin-when-cross-origin">
          <style>
            html, body, #player { width:100%; height:100%; margin:0; padding:0; overflow:hidden; background:transparent; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            function send(event) {
              window.webkit.messageHandlers.lunaYouTubePlayer.postMessage(event);
            }
            function onYouTubeIframeAPIReady() {
              new YT.Player('player', {
                width: '100%', height: '100%', videoId: '\(videoID)',
                playerVars: {
                  playsinline: 1,
                  rel: 0,
                  start: \(start),
                  \(endLine)
                  origin: '\(baseURL.absoluteString)'
                },
                events: {
                  onReady: function() { send('ready'); },
                  onError: function(event) { send('error:' + event.data); }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }
}
