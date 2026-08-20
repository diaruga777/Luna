//
//  YouTubePlaybackCardContentViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import UIKit

/// The official inline YouTube player for long-form pages Luna deliberately
/// does not download, backed by a native poster and outbound button.
///
/// The web player occupies only the 16:9 media rectangle. It may own a press in
/// that rectangle, while the substantial blank card space around it remains the
/// carousel's context-menu target.
@MainActor
final class YouTubePlaybackCardContentViewController: CardContentViewController,
    YouTubeEmbeddedPlayerViewDelegate {

    private let sourceURL: URL
    private let openSourceURL: (URL) -> Void
    private let mediaFrame = UIView()
    private let posterView = UIImageView()
    private let posterButton = UIButton(type: .custom)
    private let playGlyph = UIImageView()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let openButton = UIButton(type: .system)
    private var playerView: YouTubeEmbeddedPlayerView?
    private var playerIsReady = false
    private var isCentered = false

    init(sourceURL: URL, openSourceURL: ((URL) -> Void)? = nil) {
        self.sourceURL = sourceURL
        self.openSourceURL = openSourceURL ?? { url in UIApplication.shared.open(url) }
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        mediaFrame.clipsToBounds = true
        mediaFrame.backgroundColor = .black
        mediaFrame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mediaFrame)

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.translatesAutoresizingMaskIntoConstraints = false
        mediaFrame.addSubview(posterView)

        posterButton.accessibilityIdentifier = "YouTubeCard.posterButton"
        posterButton.accessibilityLabel = L10n.string(
            "Downloader_media_preview_openInYouTubeButtonTitle")
        posterButton.addAction(
            UIAction { [weak self] _ in self?.openYouTube() }, for: .touchUpInside)
        posterButton.translatesAutoresizingMaskIntoConstraints = false
        mediaFrame.addSubview(posterButton)

        playGlyph.image = UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .bold))
        playGlyph.tintColor = .white
        playGlyph.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        playGlyph.contentMode = .center
        playGlyph.layer.cornerRadius = 30
        playGlyph.isUserInteractionEnabled = false
        playGlyph.translatesAutoresizingMaskIntoConstraints = false
        mediaFrame.addSubview(playGlyph)

        loadingIndicator.accessibilityIdentifier = "YouTubeCard.loadingIndicator"
        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        mediaFrame.addSubview(loadingIndicator)

        openButton.configuration = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Downloader_media_preview_openInYouTubeButtonTitle"),
            symbol: "arrow.up.forward.app", prominent: true,
            tint: LunaSurfacePalette.baseColor)
        openButton.accessibilityIdentifier = "YouTubeCard.openButton"
        openButton.addAction(
            UIAction { [weak self] _ in self?.openYouTube() }, for: .touchUpInside)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(openButton)

        NSLayoutConstraint.activate([
            mediaFrame.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mediaFrame.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mediaFrame.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            mediaFrame.heightAnchor.constraint(equalTo: mediaFrame.widthAnchor, multiplier: 9.0 / 16.0),
            mediaFrame.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
            mediaFrame.bottomAnchor.constraint(lessThanOrEqualTo: openButton.topAnchor, constant: -18),
            posterView.topAnchor.constraint(equalTo: mediaFrame.topAnchor),
            posterView.bottomAnchor.constraint(equalTo: mediaFrame.bottomAnchor),
            posterView.leadingAnchor.constraint(equalTo: mediaFrame.leadingAnchor),
            posterView.trailingAnchor.constraint(equalTo: mediaFrame.trailingAnchor),
            posterButton.topAnchor.constraint(equalTo: mediaFrame.topAnchor),
            posterButton.bottomAnchor.constraint(equalTo: mediaFrame.bottomAnchor),
            posterButton.leadingAnchor.constraint(equalTo: mediaFrame.leadingAnchor),
            posterButton.trailingAnchor.constraint(equalTo: mediaFrame.trailingAnchor),
            playGlyph.centerXAnchor.constraint(equalTo: mediaFrame.centerXAnchor),
            playGlyph.centerYAnchor.constraint(equalTo: mediaFrame.centerYAnchor),
            playGlyph.widthAnchor.constraint(equalToConstant: 60),
            playGlyph.heightAnchor.constraint(equalToConstant: 60),
            loadingIndicator.centerXAnchor.constraint(equalTo: mediaFrame.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: mediaFrame.centerYAnchor),
            openButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            openButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            openButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            openButton.heightAnchor.constraint(equalToConstant: 50),
        ])

        loadPoster()
        installPlayer()
    }

    /// The player/button own their taps. Blank taps must not enter the platform
    /// embed ladder and present a second player over this one.
    override func allowsCardTap(at point: CGPoint) -> Bool { false }

    /// Only the live HTML rectangle keeps its own long press. Everything around
    /// it—including the large blank region above/below—belongs to the card menu.
    override func longPressSelectsContent(at point: CGPoint) -> Bool {
        guard let playerView, !playerView.isHidden else { return false }
        return playerView.point(inside: view.convert(point, to: playerView), with: nil)
    }

    /// The IFrame owns drags only in its visible 16:9 rectangle. The rest of
    /// this card, including the native button beneath the player, pages like
    /// every other card surface.
    override func ownsHorizontalDrag(at point: CGPoint) -> Bool {
        guard let playerView, !playerView.isHidden else { return false }
        return playerView.point(inside: view.convert(point, to: playerView), with: nil)
    }

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        isCentered = true
        updateLoadingIndicator()
    }

    override func cardDidLeaveCenter() {
        super.cardDidLeaveCenter()
        isCentered = false
        updateLoadingIndicator()
    }

    func youTubeEmbeddedPlayerDidBecomeReady(_ player: YouTubeEmbeddedPlayerView) {
        guard player === playerView else { return }
        playerIsReady = true
        updateLoadingIndicator()
    }

    func youTubeEmbeddedPlayer(
        _ player: YouTubeEmbeddedPlayerView, didFailWithCode code: Int?
    ) {
        // Unembeddable/private/player-policy failures retain a useful native
        // poster and explicit YouTube launch instead of leaving an error canvas.
        player.removeFromSuperview()
        playerView = nil
        posterButton.isHidden = false
        playGlyph.isHidden = false
        updateLoadingIndicator()
    }

    private func installPlayer() {
        guard let player = YouTubeEmbeddedPlayerView(sourceURL: sourceURL) else { return }
        player.delegate = self
        player.accessibilityIdentifier = "YouTubeCard.inlinePlayer"
        player.translatesAutoresizingMaskIntoConstraints = false
        mediaFrame.addSubview(player)
        NSLayoutConstraint.activate([
            player.topAnchor.constraint(equalTo: mediaFrame.topAnchor),
            player.bottomAnchor.constraint(equalTo: mediaFrame.bottomAnchor),
            player.leadingAnchor.constraint(equalTo: mediaFrame.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: mediaFrame.trailingAnchor),
        ])
        playerView = player
    }

    private func openYouTube() {
        openSourceURL(sourceURL)
    }

    private func loadPoster() {
        guard let thumbnailURL = YouTubeLink(url: sourceURL)?.thumbnailURL else {
            showPosterFallback()
            return
        }
        YouTubeThumbnailLoader.load(from: thumbnailURL) { [weak self] image in
            guard let self else { return }
            if let image { self.posterView.image = image }
            else { self.showPosterFallback() }
        }
    }

    private func showPosterFallback() {
        posterView.image = UIImage(systemName: "play.rectangle.fill")
        posterView.tintColor = LunaColors.tertiaryText
        posterView.contentMode = .center
    }

    private func updateLoadingIndicator() {
        let shouldShow = isCentered && playerView != nil && !playerIsReady
        if shouldShow { loadingIndicator.startAnimating() }
        else { loadingIndicator.stopAnimating() }
    }
}
