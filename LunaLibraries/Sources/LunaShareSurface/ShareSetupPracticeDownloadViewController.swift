//
//  ShareSetupPracticeDownloadViewController.swift
//  LunaShareSurface
//

import AVFoundation
import LunaDesignSystem
import LunaModels
import UIKit

/// The media sibling of `ShareSetupPracticePreviewViewController`.
///
/// A rehearsal has to rehearse the thing the app is FOR. The article preview is
/// the right answer for a practice link that stands for an article — and it was
/// the answer for all four apps, so the Downloader's save lesson ended on a page
/// of prose about a video the app had just been asked to fetch. What the
/// Downloader does with a saved link is download the video and hand it to you;
/// that is what this screen shows.
///
/// It is a REHEARSAL, deliberately, and not the media kind's own
/// `SavedNonTextualViewController`: the practice URL names no real post, so there
/// is nothing to resolve, nothing to transfer, and nothing that may be written
/// into the user's media library. It keeps that screen's grammar — the "Saved to
/// Luna" badge, the square preview with the progress bar drawn inside it, the
/// full-width Done — over a bundled clip and a fixed beat:
///
/// 1. `downloadDuration` of the progress bar filling under the media glyph;
/// 2. the clip's own first frame with a play badge over it.
///
/// Hosted (the onboarding save lesson), it also hands the clip to the session, so
/// the SAME video the Safari lesson taught plays over the sheet — the host's
/// `onMediaFileReady` path, which the real media screen uses for a real file.
/// In a real extension there is no session and the screen simply rests on step 2.
@MainActor
final class ShareSetupPracticeDownloadViewController: UIViewController,
    ShareSetupPracticePresenting {
    var onDone: (() -> Void)?

    /// How long the rehearsal spends downloading. Long enough to be a download
    /// that HAPPENED — a bar that fills in a frame reads as a screen changing
    /// its mind — and short enough that nobody waits through it twice.
    static let downloadDuration: TimeInterval = 1.5

    private let app: LunaApp
    private let videoURL: URL

    private let contentColumn = UILayoutGuide()
    private let previewContainer = UIView()
    private let posterView = UIImageView()
    private let pendingIcon = UIImageView()
    private let playBadge = UIView()
    private let progress = MoonHorizonProgressBar()
    private let status = UILabel()
    private let doneButton = UIButton(type: .system)

    /// Cancels the pending beats of a pass that has been replaced — the lesson
    /// loops, and a stale completion landing over a newer pass would put the
    /// finished state up while the bar was still filling.
    private var generation = 0

    init(app: LunaApp, videoURL: URL) {
        self.app = app
        self.videoURL = videoURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// This screen carries its own badge and its own Done, so the host's
    /// navigation bar would be an empty strip above them — the same reason the
    /// media screen hides it.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        ReadableColumn.install(
            contentColumn, in: view, preferring: view.layoutMarginsGuide)
        NSLayoutConstraint.activate([
            contentColumn.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentColumn.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        let badge = GlassConfirmationBadge(
            title: L10n.string("Common_savedToLuna"))
        buildPreview()

        status.text = L10n.string("Downloader_media_preview_downloadingStatus")
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.textColor = LunaColors.secondaryText
        status.textAlignment = .center

        let topStack = UIStackView(
            arrangedSubviews: [badge, previewContainer, status])
        topStack.axis = .vertical
        topStack.spacing = 14
        topStack.setCustomSpacing(24, after: badge)
        topStack.setCustomSpacing(18, after: previewContainer)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topStack)

        doneButton.configuration = GlassStyle.primaryActionButtonConfiguration(
            title: L10n.string("Common_done"), symbol: "checkmark",
            tint: LunaSurfacePalette.baseColor)
        doneButton.addAction(
            UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(
                equalTo: contentColumn.topAnchor, constant: 20),
            topStack.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            doneButton.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            doneButton.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            doneButton.bottomAnchor.constraint(
                equalTo: contentColumn.bottomAnchor,
                constant: -ExtensionExitButton.edgeInset),
            // On a short sheet the square gives way rather than pushing Done off.
            topStack.bottomAnchor.constraint(
                lessThanOrEqualTo: doneButton.topAnchor, constant: -16),
        ])

        HostedShareSession.current?.onReplayBeat = { [weak self] in
            self?.beginDownloadBeat()
        }
        beginDownloadBeat()
    }

    private func buildPreview() {
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = LunaColors.secondaryBackground
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true
        // Nothing on this screen answers a tap but Done. The preview is a
        // picture of a preview; the video it stands for plays over the sheet.
        previewContainer.isUserInteractionEnabled = false

        posterView.contentMode = .scaleAspectFit
        posterView.clipsToBounds = true
        posterView.isHidden = true
        posterView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(posterView)

        pendingIcon.image = UIImage(
            systemName: "play.rectangle.on.rectangle",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 48, weight: .regular))
        pendingIcon.tintColor = LunaColors.tertiaryText
        pendingIcon.contentMode = .center
        pendingIcon.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(pendingIcon)

        // Drawn INSIDE the placeholder, where the media will appear — the media
        // screen's own arrangement, for the same reason: progress belongs to the
        // thing being fetched, not to a strip of chrome.
        progress.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(progress)

        playBadge.isUserInteractionEnabled = false
        playBadge.isHidden = true
        playBadge.translatesAutoresizingMaskIntoConstraints = false
        Self.styleAsPlayBadge(playBadge, diameter: 60)
        previewContainer.addSubview(playBadge)

        let square = previewContainer.heightAnchor.constraint(
            equalTo: previewContainer.widthAnchor)
        square.priority = .defaultHigh
        NSLayoutConstraint.activate([
            square,
            previewContainer.heightAnchor.constraint(
                lessThanOrEqualTo: previewContainer.widthAnchor),
            posterView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            posterView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            posterView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            posterView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            pendingIcon.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            pendingIcon.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            progress.leadingAnchor.constraint(
                equalTo: previewContainer.leadingAnchor, constant: 28),
            progress.trailingAnchor.constraint(
                equalTo: previewContainer.trailingAnchor, constant: -28),
            progress.topAnchor.constraint(
                equalTo: pendingIcon.bottomAnchor, constant: 22),
            progress.heightAnchor.constraint(equalToConstant: 22),
            playBadge.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            playBadge.widthAnchor.constraint(equalToConstant: 60),
            playBadge.heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    // MARK: - The beat

    /// Back to the top: the bar at zero under the media glyph. Re-entered on
    /// every pass of a looping lesson.
    private func beginDownloadBeat() {
        generation += 1
        pendingIcon.isHidden = false
        posterView.isHidden = true
        playBadge.isHidden = true
        progress.isHidden = false
        progress.setProgress(0, animated: false)
        status.text = L10n.string("Downloader_media_preview_downloadingStatus")
        status.isHidden = false
        HostedShareSession.current?.awaitsMediaPlayback = true
        runDownloadRamp(generation: generation)
    }

    /// The bar filling over `downloadDuration` — but not one moment of it before
    /// the sheet carrying this screen has finished opening.
    ///
    /// The surface is built and loaded DETACHED, well before the lesson's sheet
    /// slides up (that split is what lets the real save's fetch overlap the
    /// conversation), so a beat started at `viewDidLoad` would be over before
    /// anyone saw it. `revealDate` is the same gate the media screen waits on,
    /// and it is re-armed by `beginReveal()` on every pass.
    private func runDownloadRamp(generation: Int) {
        guard generation == self.generation else { return }
        if let session = HostedShareSession.current, session.revealDate == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.runDownloadRamp(generation: generation)
            }
            return
        }

        // Two steps rather than one long animation: the bar draws its own ease,
        // and a single 1.5s ramp reads as a progress bar nobody is driving.
        progress.setProgress(0.62, animated: true)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.downloadDuration * 0.55
        ) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.progress.setProgress(1, animated: true)
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.downloadDuration
        ) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.finishDownloadBeat()
        }
    }

    /// The file is "on disk": the clip's own first frame under a play badge, and
    /// — hosted — the clip itself, for the host to play over the sheet.
    private func finishDownloadBeat() {
        progress.isHidden = true
        status.isHidden = true
        pendingIcon.isHidden = true
        posterView.image = Self.posterFrame(of: videoURL)
        posterView.isHidden = posterView.image == nil
        pendingIcon.isHidden = !posterView.isHidden
        playBadge.isHidden = false

        guard let session = HostedShareSession.current else { return }
        session.onMediaFileReady?(videoURL)
    }

    // MARK: -

    /// The clip's own opening frame, so the poster is unmistakably the thing
    /// that is about to play rather than a stand-in for it.
    private static func posterFrame(of url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(value: 0, timescale: 1), actualTime: nil)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// iOS's own inline play button: a blurred dark circle with a white
    /// triangle, matching what the media screen puts over a downloaded video.
    private static func styleAsPlayBadge(_ badge: UIView, diameter: CGFloat) {
        badge.layer.cornerRadius = diameter / 2
        badge.clipsToBounds = true

        let blur = UIVisualEffectView(
            effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.isUserInteractionEnabled = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(blur)

        let triangle = UIImageView(image: UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: diameter * 0.42, weight: .medium)))
        triangle.tintColor = .white
        triangle.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(triangle)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: badge.topAnchor),
            blur.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
            // Optically centred: a triangle's mass sits left of its bounds.
            triangle.centerXAnchor.constraint(
                equalTo: badge.centerXAnchor, constant: diameter * 0.04),
            triangle.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
    }
}
