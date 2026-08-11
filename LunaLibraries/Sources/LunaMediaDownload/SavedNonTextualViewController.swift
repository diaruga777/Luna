//
//  SavedNonTextualViewController.swift
//  LunaMediaDownload
//

import LunaModels
import LunaDesignSystem
import LunaShareSurface
import LunaStorage
import AVKit
import CoreMedia
import Photos
import UIKit

/// Shown by the action extension for non-textual content (a video, post, etc.):
/// the URL is already saved, so this confirms the save — the confirmation pill
/// sits at the top, and Done dismisses the extension.
///
/// For downloadable platforms (X / Instagram / TikTok / Facebook) the media is
/// fetched and shown INLINE: when the "Auto-download media" setting is ON the file
/// downloads automatically on appear; when OFF the preview starts PENDING (media
/// icon + "Download" button) and downloads only on tap. Progress belongs to the
/// thing being fetched, so the bar is drawn INSIDE the media placeholder, under
/// the media icon — there is no separate spinner (two indicators for one wait).
/// A video gets a play-button overlay (tap → AVPlayer); an image just
/// displays. Once downloaded (auto or manual) a "Save to Photos" button enables;
/// saving writes to the Photos library AND marks the item read in the reading list.
///
/// The controls are two stacks in one column (`contentColumn`): the
/// confirmation, the media, and the media's OWN action (Download / Save to
/// Photos) sit at the top, and the ways OUT of the screen stack up from the
/// bottom — a full-width Done under a full-width Delete, with the system-share
/// affordance a floating glass circle above them (action extension only; the
/// share extension's sheet already sits inside a share flow).
public final class SavedNonTextualViewController: UIViewController {

    private let articleURLString: String
    private let onDone: () -> Void
    /// Whether to offer the system share sheet for the downloaded file. The
    /// ACTION extension does (it's a destination in its own right); the share
    /// extension doesn't — the user arrived from a share sheet.
    private let showsSystemShare: Bool
    /// A bundled onboarding file runs the production result UI without a live
    /// post to resolve. It is deliberately display-only: the rehearsal must
    /// never write to the reading list, Photos, or Downloader's library.
    private let practiceVideoURL: URL?
    private var isPracticePreview: Bool { practiceVideoURL != nil }

    /// Whether this screen carries the inline media half at all — the square
    /// preview, its player, the Download / Save-to-Photos slot, the Share
    /// circle.
    ///
    /// A real save asks the platform table, which is the right question: there
    /// is nothing to fetch from a host Luna cannot pull media out of. The
    /// REHEARSAL already has its file in hand, and its link names a fictional
    /// host (`instatok.com`) that matches no platform rule and carries no media
    /// extension — so asking the table answered "not downloadable", the preview
    /// was never built, `beginMediaFlow` returned before applying the file, and
    /// the Downloader's save lesson ended on a bare "Saved to Luna" badge with
    /// no video in it at all. A practice video IS downloadable media by
    /// construction; it is the one case the table cannot be asked about.
    private var showsInlineMedia: Bool {
        isPracticePreview || MediaDownloadablePlatform.supports(articleURLString)
    }

    /// The app's own colour — the extensions inherit their host app's tint, so
    /// the Downloader's buttons read orange and the central app's indigo.
    private static var tint: UIColor { LunaSurfacePalette.baseColor }

    // MARK: - Downloadable-media state machine

    /// The lifecycle of the inline media preview for a downloadable platform.
    private enum MediaState {
        /// Auto-download is OFF: nothing fetched yet; show a media icon + Download button.
        case pending
        /// The media file is streaming to disk; show a spinner.
        case downloading
        /// The file is on disk and shown inline; "Save to Photos" is enabled.
        case ready(DownloadedMedia)
        /// This link is a duplicate of media already downloaded to the Downloader's
        /// library (matched by URL or durable platform item id) — shown inline from
        /// the EXISTING local file / Photos asset with no network fetch at all.
        case alreadyDownloaded(SavedMediaItem)
        /// Download failed; show the error and let the user retry.
        case failed(message: String)
    }

    private var mediaState: MediaState = .pending
    private let downloadService = MediaDownloadService()

    /// Guards the one-time auto-persist into the Downloader's app-owned media
    /// library (see `persistToDownloaderLibraryIfNeeded`).
    private var didPersistToLibrary = false

    /// Guards the one-time handover of the preview file to a `HostedShareSession`
    /// — a looping demonstration re-applies `.ready` on every pass, and each
    /// retention carries a delete.
    private var didRetainHostedPreview = false

    /// The on-disk preview file that still needs cleanup: set when media becomes
    /// `.ready`, cleared once it's saved to Photos (PhotoKit moves/consumes the
    /// file). Deleted in `deinit` so a downloaded-but-never-saved preview doesn't
    /// linger in the temp dir after the screen closes. (A startup sweep,
    /// `MediaDownloadStorage.purgeAll()`, catches files orphaned by a kill.)
    private var unsavedPreviewFileURL: URL?

    // A SQUARE media preview area, sized from the content column and filled
    // aspect-fit. Its side depends on nothing the download resolves, so the
    // media's vertical centre — and everything anchored below it — is fixed from
    // load. It hosts the still image / video poster, the play overlay, the
    // pending media icon, the download progress bar, and any load-failure
    // placeholder.
    private let previewContainer = UIView()
    private let previewImageView = UIImageView()
    /// The bundled onboarding clip stays inside this result surface instead of
    /// taking a transient full-screen player hop.
    private let practicePlayerView = InlinePlayerLayerView()
    private var practicePlayer: AVQueuePlayer?
    private var practiceLooper: AVPlayerLooper?
    /// A large media icon shown in the pending state (before any download starts).
    private let pendingIconView = UIImageView()
    /// A play overlay shown when the downloaded media is a video.
    private let playOverlay = UIView()
    /// Shown (grey box + message) when media exists but its preview couldn't render.
    private let previewPlaceholder = UILabel()

    /// The one column both stacks are laid out in: the view's margins, capped at
    /// the readable width so a wide iPad sheet doesn't stretch the media.
    private let contentColumn = UILayoutGuide()
    /// Distance from the safe area to the bottom control stack — the same inset
    /// the floating exit button used to keep.
    private static let bottomInset = ExtensionExitButton.edgeInset
    /// The Photos button is inset one further standard margin on each side, so it
    /// reads as the media's own action rather than another full-width control.
    private static let photosButtonInset: CGFloat = 16

    // The media's own action, in a fixed-height slot directly under the preview:
    // "Download media" while nothing is on disk, "Save to Photos" once something
    // is (never both — the slot holds the space either way). A status label
    // carries errors under it. The ways out of the screen — the floating Share
    // circle, Delete, Done — stack up from the bottom instead.
    private let downloadButton = UIButton(type: .system)
    private let primaryActionSlot = UIView()
    private let shareButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    /// Drawn inside the media placeholder, not under the buttons — see the type
    /// comment. Hidden except while the file is streaming to disk.
    private let downloadProgress = MoonHorizonProgressBar()
    /// What fills that bar for a REHEARSAL, which has its file in hand and so no
    /// transfer to report. Unused by a real save, whose progress is the
    /// download's own.
    private lazy var practiceDownloadRamp = PracticeDownloadRamp(
        bar: downloadProgress)
    private let downloadStatus = UILabel()
    private var didSaveToPhotos = false
    private var isDeleting = false
    private var libraryPersistenceTask: Task<String?, Never>?
    /// The player behind the currently-presented full-screen video, held weakly
    /// (the player VC owns it) so we can pause it while a share sheet is up.
    private weak var activePlayer: AVPlayer?

    public init(
        articleURLString: String, showsSystemShare: Bool = false,
        practiceVideoURL: URL? = nil,
        onDone: @escaping () -> Void
    ) {
        self.articleURLString = articleURLString
        self.showsSystemShare = showsSystemShare
        self.practiceVideoURL = practiceVideoURL
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        practicePlayer?.pause()
        // Delete a downloaded-but-never-saved preview file when the screen closes
        // (any dismissal path), so previews don't accumulate in the temp dir.
        if let url = unsavedPreviewFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The screen carries its own header pill and its own Done button, so the
    /// host's navigation bar would be an empty strip above them.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        installContentColumn()

        // The header states the one fact this screen exists to report. It used
        // to be a 44pt checkmark, the word "Saved", AND a navigation title
        // hard-coded to "Luna Downloader" (wrong in the three other apps that
        // present this screen) — three pieces of chrome for one sentence.
        let savedBadge = GlassConfirmationBadge(title: L10n.string("Common_savedToLuna"))

        // Confirmation + the media + the media's own action sit at the TOP.
        // All platforms use the same confirmation header. Downloadable media,
        // including YouTube videos, renders only in the extension playback area
        // below so there is one resolver, one preview, and one set of controls.
        let topStack = UIStackView(arrangedSubviews: [savedBadge] + mediaPreviewViews())
        topStack.axis = .vertical
        topStack.spacing = 14
        topStack.setCustomSpacing(24, after: savedBadge)
        if topStack.arrangedSubviews.contains(previewContainer) {
            // The Photos button hangs off the bottom of the square, close enough
            // to belong to it.
            topStack.setCustomSpacing(18, after: previewContainer)
        }
        topStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topStack)

        // The exits stack UP from the bottom safe area, so an absent Share
        // circle is not a gap above Delete.
        let bottomStack = UIStackView(arrangedSubviews: exitControlViews())
        bottomStack.axis = .vertical
        bottomStack.spacing = 10
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: contentColumn.topAnchor, constant: 20),
            topStack.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
            bottomStack.bottomAnchor.constraint(
                equalTo: contentColumn.bottomAnchor, constant: -Self.bottomInset),
            // On a short sheet the square preview gives way rather than sliding
            // the exits off the bottom.
            topStack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomStack.topAnchor, constant: -16),
        ])

        beginMediaFlow()
    }

    /// The single width both stacks share: the view's margins on a phone, capped
    /// at the readable width so a wide iPad sheet doesn't stretch the media
    /// preview or its buttons the whole way across.
    private func installContentColumn() {
        // Margin-wide by preference, readable-width capped, and never wider than
        // the safe area whatever the labels inside ask for — that last clamp is
        // what keeps the floating Share circle, which sits on the column's
        // trailing edge, from riding off the screen (`ReadableColumn`).
        ReadableColumn.install(
            contentColumn, in: view, preferring: view.layoutMarginsGuide)
        NSLayoutConstraint.activate([
            contentColumn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentColumn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: - Media preview UI

    /// The inline media preview + the Download / Save-to-Photos slot + (hidden)
    /// progress bar / status, shown only for downloadable platforms. The preview
    /// reserves a square from load, so nothing shifts as the media state
    /// resolves. Non-textual items from a platform Luna can't download show the
    /// confirmation and the exits alone.
    private func mediaPreviewViews() -> [UIView] {
        guard showsInlineMedia else { return [] }

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = LunaColors.secondaryBackground
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true

        previewImageView.contentMode = .scaleAspectFit
        previewImageView.clipsToBounds = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewImageView)

        if isPracticePreview {
            practicePlayerView.playerLayer.videoGravity = .resizeAspectFill
            practicePlayerView.isHidden = true
            practicePlayerView.translatesAutoresizingMaskIntoConstraints = false
            previewContainer.addSubview(practicePlayerView)
        }

        pendingIconView.image = UIImage(
            systemName: "play.rectangle.on.rectangle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .regular))
        pendingIconView.tintColor = LunaColors.tertiaryText
        pendingIconView.contentMode = .center
        pendingIconView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(pendingIconView)

        // Progress lives IN the placeholder, low enough to read as the media's
        // own loading state rather than a control.
        downloadProgress.translatesAutoresizingMaskIntoConstraints = false
        downloadProgress.isHidden = true
        previewContainer.addSubview(downloadProgress)

        // A system-style play badge over the still — revealed only for video media;
        // tapping the preview then plays it.
        playOverlay.isUserInteractionEnabled = false
        playOverlay.isHidden = true
        playOverlay.translatesAutoresizingMaskIntoConstraints = false
        Self.styleAsSystemPlayButton(playOverlay, diameter: 60)
        previewContainer.addSubview(playOverlay)

        previewPlaceholder.text = L10n.string("Downloader_media_preview_unavailableMessage")
        previewPlaceholder.font = .preferredFont(forTextStyle: .subheadline)
        previewPlaceholder.textColor = LunaColors.secondaryText
        previewPlaceholder.textAlignment = .center
        previewPlaceholder.numberOfLines = 0
        previewPlaceholder.isHidden = true
        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewPlaceholder)

        // Real saves retain their full-screen viewer on tap. The rehearsal
        // plays on this surface itself, so a demo never escapes into AVKit.
        previewContainer.isUserInteractionEnabled = !isPracticePreview
        if !isPracticePreview {
            previewContainer.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(previewTapped)))
        }

        // Square, by preference: the media's own proportions never move its
        // centre. `lessThanOrEqualTo` is the one that must hold — a short sheet
        // shrinks the box instead of pushing the exits off the bottom.
        let square = previewContainer.heightAnchor.constraint(
            equalTo: previewContainer.widthAnchor)
        square.priority = .defaultHigh
        NSLayoutConstraint.activate([
            square,
            previewContainer.heightAnchor.constraint(
                lessThanOrEqualTo: previewContainer.widthAnchor),
            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            pendingIconView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            pendingIconView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            previewPlaceholder.leadingAnchor.constraint(
                equalTo: previewContainer.leadingAnchor, constant: 12),
            previewPlaceholder.trailingAnchor.constraint(
                equalTo: previewContainer.trailingAnchor, constant: -12),
            previewPlaceholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            downloadProgress.leadingAnchor.constraint(
                equalTo: previewContainer.leadingAnchor, constant: 20),
            downloadProgress.trailingAnchor.constraint(
                equalTo: previewContainer.trailingAnchor, constant: -20),
            downloadProgress.bottomAnchor.constraint(
                equalTo: previewContainer.bottomAnchor, constant: -18),
            downloadProgress.heightAnchor.constraint(equalToConstant: 20),
            playOverlay.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            playOverlay.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
        ])
        if isPracticePreview {
            NSLayoutConstraint.activate([
                practicePlayerView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                practicePlayerView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
                practicePlayerView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                practicePlayerView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            ])
        }

        downloadButton.configuration = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Downloader_media_preview_downloadButtonTitle"), symbol: "arrow.down.circle",
            prominent: true, tint: Self.tint)
        downloadButton.addAction(
            UIAction { [weak self] _ in self?.startMediaDownload() }, for: .touchUpInside)

        setSaveButton(savedToPhotos: false)
        saveButton.addAction(
            UIAction { [weak self] _ in self?.saveToPhotos() }, for: .touchUpInside)
        saveButton.isEnabled = false

        // Download and Save-to-Photos are the same slot in two states — the media
        // either isn't here yet or is. The slot keeps its height either way, so
        // the status line below it never moves. Save is inset a further margin on
        // each side: wide, but plainly not one of the full-width controls.
        primaryActionSlot.translatesAutoresizingMaskIntoConstraints = false
        primaryActionSlot.addSubview(downloadButton)
        primaryActionSlot.addSubview(saveButton)
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            primaryActionSlot.heightAnchor.constraint(equalToConstant: 50),
            downloadButton.topAnchor.constraint(equalTo: primaryActionSlot.topAnchor),
            downloadButton.bottomAnchor.constraint(equalTo: primaryActionSlot.bottomAnchor),
            downloadButton.leadingAnchor.constraint(equalTo: primaryActionSlot.leadingAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: primaryActionSlot.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: primaryActionSlot.topAnchor),
            saveButton.bottomAnchor.constraint(equalTo: primaryActionSlot.bottomAnchor),
            saveButton.leadingAnchor.constraint(
                equalTo: primaryActionSlot.leadingAnchor, constant: Self.photosButtonInset),
            saveButton.trailingAnchor.constraint(
                equalTo: primaryActionSlot.trailingAnchor, constant: -Self.photosButtonInset),
        ])

        downloadStatus.isHidden = true
        downloadStatus.font = .preferredFont(forTextStyle: .subheadline)
        downloadStatus.textColor = LunaColors.secondaryText
        downloadStatus.textAlignment = .center
        downloadStatus.numberOfLines = 0

        return [previewContainer, primaryActionSlot, downloadStatus]
    }

    // MARK: - The exits

    /// The ways out, bottom-up: Done (full width, the app's tinted glass — the
    /// affirmative exit this screen is reached by), Delete above it, and — in the
    /// action extension, and only where a file could exist to share — a floating
    /// glass Share circle above that.
    private func exitControlViews() -> [UIView] {
        configureDeleteButton()
        configureDoneButton()
        guard showsSystemShare, showsInlineMedia else {
            return [deleteButton, doneButton]
        }
        return [floatingShareRow(), deleteButton, doneButton]
    }

    private func configureDeleteButton() {
        guard deleteButton.configuration == nil else { return }
        var config = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Common_delete"), symbol: "trash", tint: Self.tint)
        // Quiet glass, but the label and glyph stay unmistakably destructive.
        config.baseForegroundColor = LunaColors.errorAccent
        deleteButton.configuration = config
        deleteButton.addAction(
            UIAction { [weak self] _ in self?.deleteAndExit() }, for: .touchUpInside)
    }

    private func configureDoneButton() {
        guard doneButton.configuration == nil else { return }
        doneButton.configuration = GlassStyle.primaryActionButtonConfiguration(
            title: L10n.string("Common_done"), symbol: "checkmark", tint: Self.tint)
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone() }, for: .touchUpInside)
    }

    /// The Share circle, sitting against the trailing edge the pills under it
    /// end at. It stays visible but disabled until a file exists, so the action
    /// extension's bottom chrome doesn't rearrange itself mid-download.
    private func floatingShareRow() -> UIView {
        shareButton.isEnabled = false
        ExtensionFloatingGlassButton.style(
            shareButton, symbol: "square.and.arrow.up",
            accessibilityLabel: L10n.string("Common_share"))
        shareButton.addAction(
            UIAction { [weak self] _ in self?.shareDownloadedMedia() }, for: .touchUpInside)

        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(shareButton)
        NSLayoutConstraint.activate([
            shareButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            shareButton.topAnchor.constraint(equalTo: row.topAnchor),
            // A little more air under the circle than the pills keep between
            // themselves, so it floats rather than joining the stack.
            shareButton.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
        ])
        return row
    }

    // MARK: - Media flow (state machine)

    /// Entry point after layout: auto-download immediately when the setting is ON,
    /// otherwise rest in the pending state until the user taps Download.
    private func beginMediaFlow() {
        guard showsInlineMedia else { return }
        if let practiceVideoURL {
            // The result screen remains the real `SavedNonTextual` controller;
            // only its input is bundled mock data. Resolve it after the hosted
            // sheet has revealed so the inline download/result transition is
            // still visible in the iMessage lesson.
            beginPracticeDownloadBeat(
                DownloadedMedia(fileURL: practiceVideoURL, kind: .video))
            return
        }
        if let existing = SavedMediaStore.shared.existingDownloadedItem(forURLString: articleURLString) {
            // Already in the library under this URL or the same platform item id
            // (e.g. a share-link token whose resolved permalink was saved earlier) —
            // show it as-is instead of re-fetching from the network.
            didPersistToLibrary = true
            applyResolvedMediaState(.alreadyDownloaded(existing))
        } else if let preloaded = MediaPreloadCache.shared.take(
            urlString: articleURLString) {
            // Somebody already asked for this file (the onboarding save lesson
            // starts the fetch the moment the user taps into it, while its sheet
            // is still opening). Join that transfer rather than starting a
            // second one — and take its progress with it, so the bar picks up
            // where the download is instead of at zero.
            MediaPreloadCache.shared.observeProgress(
                urlString: articleURLString
            ) { [weak self] fraction in
                self?.downloadProgress.setProgress(Float(fraction), animated: true)
            }
            startMediaDownload(joining: preloaded)
        } else if AutoDownloadSettings.autoDownloadMediaInPreview {
            startMediaDownload()
        } else {
            applyMediaState(.pending)
        }
    }

    // MARK: - Hosted (in-app rehearsal) pacing

    /// Applies a RESULT, but never before the screen carrying it has finished
    /// appearing.
    ///
    /// In a real extension this is `applyMediaState` and nothing else. Under a
    /// `HostedShareSession` — the onboarding save lesson, whose sheet slides up
    /// over a conversation — the file is often already on disk (preloaded) before
    /// the sheet has opened, so the download indication would appear and vanish
    /// inside a frame or two and the lesson would demonstrate nothing. The result
    /// waits for the reveal plus `minimumDownloadIndication`; the downloading UI
    /// holds the screen meanwhile, which is the truth for a preload that has not
    /// actually finished either.
    private func applyResolvedMediaState(_ state: MediaState) {
        guard let session = HostedShareSession.current else {
            applyMediaState(state)
            return
        }
        if case .downloading = mediaState {} else { applyMediaState(.downloading) }
        guard let earliest = session.earliestDownloadResolution else {
            // Still opening. Nothing may resolve yet; look again shortly.
            scheduleHostedResolution(state, after: 0)
            return
        }
        let wait = earliest.timeIntervalSinceNow
        guard wait <= 0 else {
            scheduleHostedResolution(state, after: wait)
            return
        }
        applyMediaState(state)
    }

    private func scheduleHostedResolution(
        _ state: MediaState, after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(delay, 0.05)
        ) { [weak self] in
            self?.applyResolvedMediaState(state)
        }
    }

    /// Tells a hosted host what the media kind still owes it, and hands over the
    /// downloaded file so real playback can run over the sheet.
    ///
    /// A ready VIDEO is the one case the host waits on beyond the state itself:
    /// the point of the media lesson is that the thing you saved is now yours,
    /// which a still poster does not say. It also takes ownership of the preview
    /// file — the demonstration loops, and this screen's `deinit` would otherwise
    /// delete it between passes and charge the next one another download.
    private func reportMediaState(_ state: MediaState) {
        guard let session = HostedShareSession.current else { return }
        // Whatever this screen last resolved to, it can show again from what it
        // already holds — that is what makes a looping lesson free.
        session.onReplayBeat = { [weak self] in self?.replayHostedBeat() }
        switch state {
        case .downloading:
            session.awaitsMediaPlayback = true
        case .pending, .failed:
            session.awaitsMediaPlayback = false
        case let .ready(media):
            let fileURL = media.fileURL
            // The onboarding clip is already playing in this controller's
            // preview rectangle. Do not ask the host to layer a second player
            // over the sheet — that was the brief full-screen-looking hop — but
            // do keep the sheet up while it plays, or the lesson's terminal hold
            // is the whole of the playback and the video is a blink.
            if isPracticePreview {
                holdSheetForPracticePlayback()
                return
            }
            if !isPracticePreview, !didRetainHostedPreview {
                didRetainHostedPreview = true
                session.retain(media) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            // The session owns the file now; this screen's `deinit` must not take
            // it away between demonstration passes.
            unsavedPreviewFileURL = nil
            guard media.kind == .video else {
                session.awaitsMediaPlayback = false
                return
            }
            session.onMediaFileReady?(fileURL)
        case let .alreadyDownloaded(item):
            guard item.kind == .video, let fileURL = item.fileURL else {
                session.awaitsMediaPlayback = false
                return
            }
            session.onMediaFileReady?(fileURL)
        }
    }

    /// How long the rehearsal's clip plays in the preview square before the
    /// hosted sheet may leave. Long enough to read as playback rather than a
    /// poster that twitched — the same beat the host spends on a REAL saved
    /// video, spent here instead because this clip never leaves this screen.
    static let practicePlaybackDuration: TimeInterval = 2.0

    /// Cancels the hold of a pass that has been replaced: the lesson loops, and
    /// a stale timer must not clear a newer pass's wait mid-download.
    private var practicePlaybackGeneration = 0

    private func holdSheetForPracticePlayback() {
        HostedShareSession.current?.awaitsMediaPlayback = true
        practicePlaybackGeneration += 1
        let generation = practicePlaybackGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.practicePlaybackDuration
        ) { [weak self] in
            guard let self, generation == self.practicePlaybackGeneration else { return }
            HostedShareSession.current?.awaitsMediaPlayback = false
        }
    }

    /// The rehearsal's download, which has no transfer to report: the bar fills
    /// on `PracticeDownloadRamp`'s clock — the same one the kind-less practice
    /// screen fills on — and the bundled file resolves at the top of it.
    ///
    /// Without the ramp the bar sat at zero for the whole indication and then the
    /// finished screen replaced it, so the one thing the media lesson exists to
    /// show — that a download happened — was the one thing it never drew.
    private func beginPracticeDownloadBeat(_ media: DownloadedMedia) {
        applyMediaState(.downloading)
        practiceDownloadRamp.start { [weak self] in
            self?.applyResolvedMediaState(.ready(media))
        }
    }

    /// Plays the media beat over again, off the file already on disk: back to the
    /// download indication, through its minimum, then the same result. No
    /// resolve, no transfer, no second copy.
    private func replayHostedBeat() {
        switch mediaState {
        case let .ready(media):
            guard !isPracticePreview else {
                beginPracticeDownloadBeat(media)
                return
            }
            applyMediaState(.downloading)
            downloadProgress.setProgress(1, animated: true)
            applyResolvedMediaState(.ready(media))
        case let .alreadyDownloaded(item):
            applyMediaState(.downloading)
            downloadProgress.setProgress(1, animated: true)
            applyResolvedMediaState(.alreadyDownloaded(item))
        case .pending, .downloading, .failed:
            // Still working, or nothing to show — the first pass has not finished
            // and re-running it would only restart what is already in flight.
            break
        }
    }

    /// Renders the UI for a state. The single source of truth for what each control
    /// shows, so transitions stay consistent.
    private func applyMediaState(_ state: MediaState) {
        mediaState = state
        // Track the live preview file for teardown cleanup (only `.ready` has one).
        if case .ready(let media) = state {
            // The practice clip belongs to the app bundle. Treating it like a
            // downloaded temp file would attempt to delete a shipped resource
            // when the controller leaves the rehearsal.
            unsavedPreviewFileURL = isPracticePreview ? nil : media.fileURL
        } else {
            unsavedPreviewFileURL = nil
        }
        switch state {
        case .pending:
            pendingIconView.isHidden = false
            previewImageView.isHidden = true
            playOverlay.isHidden = true
            previewPlaceholder.isHidden = true
            downloadButton.isHidden = false
            downloadProgress.isHidden = true
            shareButton.isEnabled = false
            // Download owns the slot until a file exists.
            saveButton.isHidden = true
            saveButton.isEnabled = false
            downloadStatus.isHidden = true

        case .downloading:
            // The placeholder icon STAYS: the progress bar under it is the
            // media's own loading state, drawn where the media will appear.
            pendingIconView.isHidden = false
            previewImageView.isHidden = true
            playOverlay.isHidden = true
            previewPlaceholder.isHidden = true
            downloadButton.isHidden = true
            downloadProgress.setProgress(0, animated: false)
            downloadProgress.isHidden = false
            shareButton.isEnabled = false
            // The progress bar in the preview is the whole story; the slot below
            // it holds its space and says nothing.
            saveButton.isHidden = true
            saveButton.isEnabled = false
            downloadStatus.text = L10n.string("Downloader_media_preview_downloadingStatus")
            downloadStatus.textColor = LunaColors.secondaryText
            downloadStatus.isHidden = false

        case .ready(let media):
            pendingIconView.isHidden = true
            downloadButton.isHidden = true
            downloadProgress.isHidden = true
            downloadStatus.isHidden = true
            shareButton.isEnabled = true
            saveButton.isHidden = false
            setSaveButton(savedToPhotos: didSaveToPhotos)
            // Takes the slot back for audio, which Photos can't hold.
            showReadyPreview(media)
            if !isPracticePreview { persistToDownloaderLibraryIfNeeded(media) }

        case .alreadyDownloaded(let item):
            pendingIconView.isHidden = true
            downloadButton.isHidden = true
            downloadProgress.isHidden = true
            downloadStatus.isHidden = true
            shareButton.isEnabled = true
            saveButton.isHidden = false
            didSaveToPhotos = item.photosLocalIdentifier != nil
            setSaveButton(savedToPhotos: didSaveToPhotos)
            showAlreadyDownloadedPreview(item)

        case .failed(let message):
            pendingIconView.isHidden = false
            previewImageView.isHidden = true
            playOverlay.isHidden = true
            previewPlaceholder.isHidden = true
            downloadButton.isHidden = false
            downloadProgress.isHidden = true
            shareButton.isEnabled = false
            // Back to the retry, which owns the slot again.
            saveButton.isHidden = true
            saveButton.isEnabled = false
            downloadStatus.text = message
            downloadStatus.textColor = .systemRed
            downloadStatus.isHidden = false
        }
        reportMediaState(state)
    }

    /// Streams the first media item to a local file (memory-safe), updating the
    /// progress bar, then transitions to `.ready`. On failure shows `.failed`.
    ///
    /// `joining` adopts a transfer somebody already started
    /// (`MediaPreloadCache`) instead of opening a second one; awaiting a finished
    /// task simply returns.
    private func startMediaDownload(
        joining preloaded: Task<DownloadedMedia, Error>? = nil
    ) {
        guard let url = URL(string: articleURLString) else { return }
        applyMediaState(.downloading)
        Task { [weak self] in
            guard let self else { return }
            do {
                let media: DownloadedMedia
                if let preloaded {
                    media = try await preloaded.value
                } else {
                    media = try await downloadService.downloadFirstMediaToFile(from: url) { progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress.setProgress(Float(progress), animated: true)
                        }
                    }
                }
                await MainActor.run {
                    guard !self.isDeleting else {
                        try? FileManager.default.removeItem(at: media.fileURL)
                        return
                    }
                    self.applyResolvedMediaState(.ready(media))
                }
            } catch {
                let message = (error as? MediaDownloadError)?.message
                    ?? L10n.string("Downloader_media_error_downloadFailed")
                await MainActor.run {
                    guard !self.isDeleting else { return }
                    self.applyMediaState(.failed(message: message))
                }
            }
        }
    }

    /// Persists a Downloader preview according to the global storage policy. A copy
    /// is used so the inline preview remains playable while the durable backing is
    /// committed as either a PhotoKit identifier or an app-group file.
    private func persistToDownloaderLibraryIfNeeded(_ media: DownloadedMedia) {
        guard MediaAutoDownloader.isRunningInDownloader, !didPersistToLibrary else { return }
        didPersistToLibrary = true
        let sourceURLString = articleURLString
        let readingItem = ReadingListStore.shared.item(forURLString: sourceURLString)
        let title = readingItem?.title
        let previewURL = media.fileURL
        let kind = media.kind
        let persistence = Task.detached { () -> String? in
            let copy = MediaDownloadStorage.newFileURL(extension: previewURL.pathExtension)
            do {
                try FileManager.default.copyItem(at: previewURL, to: copy)
                let store = SavedMediaStore.shared
                let pending = try store.ensureUndownloaded(
                    id: readingItem?.id ?? UUID(),
                    sourceURLString: sourceURLString,
                    title: title)
                let saved: SavedMediaItem
                let photoSaver = PhotoLibrarySaver()
                if kind.canSaveToPhotos,
                   AutoDownloadSettings.autoSaveDownloadsToPhotos,
                   await photoSaver.requestReadAuthorization() {
                    do {
                        let identifier = try await photoSaver.save(
                            fileURL: copy, kind: kind, shouldMoveFile: false)
                        guard let item = try store.transitionToPhotosReference(
                            pending.id, localIdentifier: identifier, kind: kind)
                        else { throw MediaDownloadError.saveFailed }
                        saved = item
                        try? FileManager.default.removeItem(at: copy)
                    } catch {
                        saved = try store.addDownloadedFile(
                            copy, kind: kind, sourceURLString: sourceURLString, title: title,
                            requiringItemID: pending.id)
                    }
                } else {
                    saved = try store.addDownloadedFile(
                        copy, kind: kind, sourceURLString: sourceURLString, title: title,
                        requiringItemID: pending.id)
                }
                AutoDownloadSettings.markDownloaded(sourceURLString)
                return saved.photosLocalIdentifier
            } catch {
                try? FileManager.default.removeItem(at: copy)
                return nil
            }
        }
        libraryPersistenceTask = persistence
        Task { @MainActor [weak self] in
            let photosIdentifier = await persistence.value
            self?.libraryPersistenceTask = nil
            guard photosIdentifier != nil else { return }
            self?.didSaveToPhotos = true
            self?.setSaveButton(savedToPhotos: true)
        }
    }

    /// Shows the downloaded file inline: a still image renders directly; a video
    /// renders its first-frame poster with the play overlay (tap to play). Persists
    /// the still into the shared store so the app's platform card has a thumbnail.
    private func showReadyPreview(_ media: DownloadedMedia) {
        if isPracticePreview {
            showInlinePracticePlayback(url: media.fileURL)
            return
        }
        previewImageView.isHidden = false
        saveButton.isHidden = media.kind == .audio
        switch media.kind {
        case .image, .gif:
            playOverlay.isHidden = true
            // Explicit scale 1 (not the display scale `ImageDownsampling` normally
            // takes) reproduces this preview's existing pixel density.
            if let image = ImageDownsampling.decode(
                path: media.fileURL.path, scale: 1, maxPixelSize: 1400) {
                previewImageView.image = image
                previewPlaceholder.isHidden = true
                persistPreviewThumbnail(image)
            } else {
                previewImageView.isHidden = true
                previewPlaceholder.isHidden = false
            }
        case .video, .audio:
            playOverlay.isHidden = false
            guard media.kind == .video else {
                previewImageView.image = UIImage(systemName: "waveform")
                previewImageView.tintColor = LunaColors.secondaryText
                previewImageView.contentMode = .center
                previewPlaceholder.isHidden = true
                return
            }
            Task { [weak self] in
                let poster = await Self.videoPoster(for: media.fileURL)
                await MainActor.run {
                    guard let self else { return }
                    if let poster {
                        self.previewImageView.image = poster
                        self.persistPreviewThumbnail(poster)
                    } else {
                        self.previewImageView.backgroundColor = .black
                    }
                }
            }
        }
    }

    /// Mock data, production result UI: the practice clip starts in the real
    /// media-preview rectangle and loops there. It has no gesture recognizer,
    /// so it can never briefly present an AVKit full-screen controller during
    /// the iMessage lesson.
    private func showInlinePracticePlayback(url: URL) {
        previewImageView.isHidden = true
        pendingIconView.isHidden = true
        previewPlaceholder.isHidden = true
        playOverlay.isHidden = true
        practicePlayerView.isHidden = false
        guard practicePlayer == nil else {
            practicePlayer?.play()
            return
        }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        practicePlayer = player
        practiceLooper = AVPlayerLooper(
            player: player, templateItem: AVPlayerItem(url: url))
        practicePlayerView.playerLayer.player = player
        player.play()
    }

    /// Shows a link already downloaded to the Downloader's library, from the
    /// EXISTING file/Photos asset — no network fetch. Mirrors `showReadyPreview`'s
    /// visuals (still renders directly; video shows a poster + play overlay).
    private func showAlreadyDownloadedPreview(_ item: SavedMediaItem) {
        switch item.storageState {
        case .localFile:
            guard let fileURL = item.fileURL, let kind = item.kind else {
                previewImageView.isHidden = true
                previewPlaceholder.isHidden = false
                return
            }
            showReadyPreview(DownloadedMedia(fileURL: fileURL, kind: kind))
        case .photosReference(let identifier, _, _):
            previewImageView.isHidden = false
            playOverlay.isHidden = item.kind != .video
            Task { [weak self] in
                let image = await Self.photosPreviewImage(identifier: identifier)
                await MainActor.run {
                    guard let self else { return }
                    if let image {
                        self.previewImageView.image = image
                        self.previewPlaceholder.isHidden = true
                    } else {
                        self.previewImageView.isHidden = true
                        self.previewPlaceholder.isHidden = false
                    }
                }
            }
        case .undownloaded:
            previewImageView.isHidden = true
            previewPlaceholder.isHidden = false
        }
    }

    /// Tapping the preview plays the downloaded video in an AVPlayerViewController —
    /// from the fresh temp file (`.ready`) or the already-downloaded item's own
    /// local file / Photos asset (`.alreadyDownloaded`).
    @objc private func previewTapped() {
        switch mediaState {
        case .ready(let media) where media.kind == .video || media.kind == .audio:
            playVideo(url: media.fileURL)
        case .alreadyDownloaded(let item) where item.kind == .video || item.kind == .audio:
            if let fileURL = item.fileURL {
                playVideo(url: fileURL)
            } else if let identifier = item.photosLocalIdentifier {
                Task { [weak self] in
                    guard let asset = await Self.photosVideoAsset(identifier: identifier) else { return }
                    await MainActor.run { self?.playVideo(asset: asset) }
                }
            }
        default:
            break
        }
    }

    /// Presents an `AVPlayerViewController` for `url`, routed to `.playback` so the
    /// video's audio is heard even when the ring/silent switch is on — the extension
    /// otherwise inherits the default ambient session, which the hardware silent
    /// switch mutes (the "plays fine from Photos, silent in place" symptom).
    private func playVideo(url: URL) {
        playVideo(asset: AVURLAsset(url: url))
    }

    private func playVideo(asset: AVAsset) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        activePlayer = player
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        present(playerVC, animated: true) { player.play() }
    }

    /// Presents the system share sheet with the downloaded source media file — the
    /// fresh temp file (`.ready`), the already-downloaded item's own local file, or
    /// (Photos-backed) a short-lived local export of the Photos asset. All local
    /// reads/exports — never a network re-fetch.
    private func shareDownloadedMedia() {
        switch mediaState {
        case .ready(let media):
            presentShareSheet(for: media.fileURL)
        case .alreadyDownloaded(let item):
            if let fileURL = item.fileURL {
                presentShareSheet(for: fileURL)
            } else if let identifier = item.photosLocalIdentifier {
                Task { [weak self] in
                    guard let url = await Self.exportPhotosAsset(
                        identifier: identifier, kind: item.kind ?? .image)
                    else { return }
                    await MainActor.run { self?.presentShareSheet(for: url) }
                }
            }
        default:
            break
        }
    }

    private func presentShareSheet(for fileURL: URL) {
        let activity = UIActivityViewController(
            activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        activity.popoverPresentationController?.sourceRect = shareButton.bounds
        // Don't let a playing video keep running behind the share sheet.
        activePlayer?.pause()
        present(activity, animated: true)
    }

    /// Requests Photos add access and saves the downloaded file, then marks the item
    /// READ in the reading list (saving counts as consuming it). Only
    /// reachable for `.ready` (a fresh temp file PhotoKit moves) or an already-downloaded
    /// `.localFile` duplicate (a COPY is saved, then the library's own file is retired via
    /// `transitionToPhotosReference` — the button is disabled/hidden once already `.photosReference`).
    private func saveToPhotos() {
        // The onboarding screen is driven by a bundled mock file. Keep the
        // production control visible and let it reach its ordinary completed
        // visual state, without adding a rehearsal clip to the user's library.
        if isPracticePreview {
            finishSave(success: true)
            return
        }
        switch mediaState {
        case .ready(let media):
            saveButton.isEnabled = false
            showSavingStatus()
            Task { [weak self] in
                guard let self else { return }
                do {
                    let identifier = try await self.downloadService.saveDownloadedMediaToPhotos(media)
                    if let local = SavedMediaStore.shared.item(forURLString: self.articleURLString) {
                        _ = try SavedMediaStore.shared.transitionToPhotosReference(
                            local.id, localIdentifier: identifier, kind: media.kind)
                    }
                    // PhotoKit moved the file into the library — no temp file to clean up.
                    await MainActor.run { self.unsavedPreviewFileURL = nil }
                    AutoDownloadSettings.markDownloaded(self.articleURLString)
                    self.markItemRead()
                    await MainActor.run { self.finishSave(success: true) }
                } catch {
                    let message = (error as? MediaDownloadError)?.message
                        ?? L10n.string("Downloader_media_error_saveMediaFailed")
                    await MainActor.run { self.finishSave(message: message, success: false) }
                }
            }
        case .alreadyDownloaded(let item) where item.fileURL != nil:
            let fileURL = item.fileURL!
            let kind = item.kind ?? .image
            saveButton.isEnabled = false
            showSavingStatus()
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await SavedMediaPhotosSync.saveAndTransition(
                        itemID: item.id, fileURL: fileURL, kind: kind, shouldMoveFile: false,
                        saver: PhotoLibrarySaver(), store: SavedMediaStore.shared)
                    AutoDownloadSettings.markDownloaded(self.articleURLString)
                    self.markItemRead()
                    await MainActor.run { self.finishSave(success: true) }
                } catch {
                    let message = (error as? MediaDownloadError)?.message
                        ?? L10n.string("Downloader_media_error_saveMediaFailed")
                    await MainActor.run { self.finishSave(message: message, success: false) }
                }
            }
        default:
            break
        }
    }

    private func showSavingStatus() {
        downloadStatus.text = L10n.string("Downloader_media_preview_savingStatus")
        downloadStatus.textColor = LunaColors.secondaryText
        downloadStatus.isHidden = false
    }

    @MainActor
    private func finishSave(message: String = "", success: Bool) {
        if success {
            didSaveToPhotos = true
            setSaveButton(savedToPhotos: true)
            // The button is the completion state; don't add a transient
            // duplicate "Saved" status below the controls.
            downloadStatus.isHidden = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            downloadStatus.text = message
            downloadStatus.textColor = .systemRed
            downloadStatus.isHidden = false
            setSaveButton(savedToPhotos: didSaveToPhotos)
        }
    }

    /// The Photos button, in either state. It is the prominent action of its slot
    /// (the app's tint fills the glass) and BOTH states carry the Photos mark
    /// itself, set inline before the word "Photos" — the destination is the
    /// point of the button, so it shouldn't disappear the moment it's reached.
    private func setSaveButton(savedToPhotos: Bool) {
        var config = GlassStyle.actionButtonConfiguration(
            title: "", symbol: "checkmark", prominent: true, tint: Self.tint)
        // The title carries its own (multicolour) glyph; a second leading symbol
        // would just crowd the pill. Saved state keeps the checkmark.
        config.image = savedToPhotos ? UIImage(systemName: "checkmark") : nil
        config.attributedTitle = Self.photosTitle(savedToPhotos: savedToPhotos)
        saveButton.configuration = config
        saveButton.isEnabled = !savedToPhotos
        // The title carries an image attachment in place of a word, so spell the
        // label out rather than letting VoiceOver read around the glyph.
        saveButton.accessibilityLabel = savedToPhotos
            ? L10n.string("Downloader_media_preview_savedAccessibilityLabel")
            : L10n.string("Downloader_media_preview_saveAccessibilityLabel")
    }

    /// "Save to 🌸 Photos" — the Photos mark placed inline, at the position the
    /// localized string chooses (the marker is a format argument, so a
    /// translation can move it with the noun it belongs to).
    @MainActor
    private static func photosTitle(savedToPhotos: Bool) -> AttributedString {
        let marker = "\u{FFFC}"   // OBJECT REPLACEMENT CHARACTER
        let text = savedToPhotos
            ? L10n.string("Downloader_media_preview_savedButtonTitleFormat", marker)
            : L10n.string("Downloader_media_preview_saveButtonTitleFormat", marker)
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let string = NSMutableAttributedString(string: text, attributes: [.font: font])
        guard let range = text.range(of: marker) else { return AttributedString(string) }

        let side: CGFloat = 15
        let attachment = NSTextAttachment()
        attachment.image = PhotosAppGlyph.image(side: side)
        // Optically centre the glyph on the cap height rather than the baseline.
        attachment.bounds = CGRect(
            x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
        string.replaceCharacters(
            in: NSRange(range, in: text), with: NSAttributedString(attachment: attachment))
        return AttributedString(string)
    }

    private func deleteAndExit() {
        if isPracticePreview {
            onDone()
            return
        }
        guard !isDeleting else { return }
        isDeleting = true
        deleteButton.isEnabled = false
        downloadButton.isEnabled = false
        shareButton.isEnabled = false
        saveButton.isEnabled = false
        downloadStatus.text = L10n.string("Downloader_media_preview_deletingStatus")
        downloadStatus.textColor = LunaColors.secondaryText
        downloadStatus.isHidden = false

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = await self.libraryPersistenceTask?.value
                if let mediaItem = SavedMediaStore.shared.matchingItem(
                    forURLString: self.articleURLString) {
                    try await SavedMediaPhotosSync.deletePhotosAssetIfPresent(
                        mediaItem.photosLocalIdentifier, saver: PhotoLibrarySaver())
                    SavedMediaStore.shared.delete(mediaItem)
                }
                if let readingItem = ReadingListStore.shared.item(
                    forURLString: self.articleURLString) {
                    ReadingListStore.shared.delete(readingItem)
                }
                AutoDownloadSettings.unmarkDownloaded(self.articleURLString)
                await MainActor.run { self.onDone() }
            } catch {
                let message = (error as? MediaDownloadError)?.message
                    ?? L10n.string("Downloader_media_error_deleteFailed")
                await MainActor.run {
                    self.isDeleting = false
                    self.deleteButton.isEnabled = true
                    self.downloadStatus.text = message
                    self.downloadStatus.textColor = .systemRed
                    self.downloadStatus.isHidden = false
                }
            }
        }
    }

    /// Marks the saved reading-list item as read.
    private func markItemRead() {
        guard let item = ReadingListStore.shared.item(forURLString: articleURLString) else { return }
        ReadingListStore.shared.markReadState(.read, for: item.id)
    }

    /// The extension may be the first surface to resolve this media. Persist the
    /// downsampled still into the shared store so the main app's platform card has a
    /// thumbnail even though no article ingestion runs for a ready platform item.
    private func persistPreviewThumbnail(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.88),
              let item = ReadingListStore.shared.item(forURLString: articleURLString) else { return }
        ReadingListStore.shared.setThumbnail(data, for: item.id)
    }

    // MARK: - Image / video helpers

    /// Generates a poster frame from a local video file off the main actor.
    private static func videoPoster(for fileURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1400, height: 1400)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, cgImage, _, _, _ in
                if let cgImage {
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// A downsampled still/poster for a Photos-backed asset — a local Photos read,
    /// never a network fetch (the item is already in the user's library).
    private static func photosPreviewImage(
        identifier: String, maxPixelSize: CGFloat = 1400
    ) async -> UIImage? {
        guard await PhotoLibrarySaver().requestReadAuthorization(),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixelSize, height: maxPixelSize),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in continuation.resume(returning: image) }
        }
    }

    /// The playable `AVAsset` for a Photos-backed video, for tap-to-play.
    private static func photosVideoAsset(identifier: String) async -> AVAsset? {
        guard await PhotoLibrarySaver().requestReadAuthorization(),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    /// A short-lived local file for sharing a Photos-backed asset — an image is
    /// exported via its original data; a video reuses its backing file URL when
    /// PhotoKit provides one (it does for on-device assets, which a just-downloaded
    /// item always is) or falls back to an export session otherwise.
    private static func exportPhotosAsset(identifier: String, kind: MediaAsset.Kind) async -> URL? {
        guard await PhotoLibrarySaver().requestReadAuthorization(),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        if kind == .video {
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let avAsset: AVAsset? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    continuation.resume(returning: avAsset)
                }
            }
            if let urlAsset = avAsset as? AVURLAsset { return urlAsset.url }
            guard let avAsset,
                  let export = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality)
            else { return nil }
            let destination = MediaDownloadStorage.newFileURL(extension: "mov")
            try? FileManager.default.removeItem(at: destination)
            do {
                try await export.export(to: destination, as: .mov)
                return destination
            } catch {
                return nil
            }
        }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input)
            }
        }
        return input?.fullSizeImageURL
    }

    /// Styles `badge` as a system-style play button: a frosted dark circle with a
    /// white play glyph.
    private static func styleAsSystemPlayButton(_ badge: UIView, diameter: CGFloat) {
        badge.layer.cornerRadius = diameter / 2
        badge.clipsToBounds = true

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.isUserInteractionEnabled = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(blur)

        let triangle = UIImageView(image: UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter * 0.42, weight: .medium)))
        triangle.tintColor = .white
        triangle.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(triangle)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: diameter),
            badge.heightAnchor.constraint(equalToConstant: diameter),
            blur.topAnchor.constraint(equalTo: badge.topAnchor),
            blur.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
            // Optical-center the triangle (nudge a hair right of geometric center).
            triangle.centerXAnchor.constraint(equalTo: badge.centerXAnchor, constant: diameter * 0.04),
            triangle.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
    }

}

private final class InlinePlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
