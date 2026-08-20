//
//  YouTubePlaybackCardContentViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import WebKit

/// An official embedded-player card for YouTube pages Luna deliberately does
/// not download. The player owns playback; Luna never extracts or stores its
/// stream bytes.
@MainActor
final class YouTubePlaybackCardContentViewController: CardContentViewController {

    private let sourceURL: URL
    private var player: WKWebView?

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let embedURL = YouTubeLink(url: sourceURL)?.embedURL else { return }
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let player = WKWebView(frame: view.bounds, configuration: configuration)
        player.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        player.isOpaque = false
        player.backgroundColor = .black
        view.addSubview(player)
        self.player = player
        player.load(URLRequest(url: embedURL))
    }

    override func allowsCardTap(at point: CGPoint) -> Bool { false }
    override func longPressSelectsContent(at point: CGPoint) -> Bool { true }
}
