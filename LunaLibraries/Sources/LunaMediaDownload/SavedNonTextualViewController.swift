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
/// the URL is already saved, so this confirms the save and — for shareable links,
/// when there are friends — shows a scrolling friend list; tapping a friend QUEUES
/// the send to the App Group (the app delivers it on next launch). The confirmation
/// content sits near the top to leave room for the friend list. No eBook / system
/// share. Done dismisses the extension.
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
public final class SavedNonTextualViewController: UIViewController {

    private let articleURLString: String
    private let onDone: () -> Void

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

    /// The on-disk preview file that still needs cleanup: set when media becomes
    /// `.ready`, cleared once it's saved to Photos (PhotoKit moves/consumes the
    /// file). Deleted in `deinit` so a downloaded-but-never-saved preview doesn't
    /// linger in the temp dir after the screen closes. (A startup sweep,
    /// `MediaDownloadStorage.purgeAll()`, catches files orphaned by a kill.)
    private var unsavedPreviewFileURL: URL?

    // A fixed-height media preview area. Reserves space from load so the layout
    // never shifts as the media state resolves: it hosts the still image / video
    // poster, the play overlay, the pending media icon, the download progress
    // bar, and any load-failure placeholder.
    private let previewContainer = UIView()
    private let previewImageView = UIImageView()
    /// A large media icon shown in the pending state (before any download starts).
    private let pendingIconView = UIImageView()
    /// A play overlay shown when the downloaded media is a video.
    private let playOverlay = UIView()
    /// Shown (grey box + message) when media exists but its preview couldn't render.
    private let previewPlaceholder = UILabel()
    private static let previewHeight: CGFloat = 220

    // The action row: a primary button that is "Download media" (pending) /
    // hidden (downloading, ready), then Share + "Save to Photos" side by side
    // (enabled once a file exists) over the destructive Delete. A status label
    // carries errors. All hold layout space from load.
    private let downloadButton = UIButton(type: .system)
    private let downloadButtonSlot = UIView()
    private let shareButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    /// Drawn inside the media placeholder, not under the buttons — see the type
    /// comment. Hidden except while the file is streaming to disk.
    private let downloadProgress = MoonHorizonProgressBar()
    private let downloadStatus = UILabel()
    private var didSaveToPhotos = false
    private var isDeleting = false
    private var libraryPersistenceTask: Task<String?, Never>?
    /// The player behind the currently-presented full-screen video, held weakly
    /// (the player VC owns it) so we can pause it while a share sheet is up.
    private weak var activePlayer: AVPlayer?

    public init(articleURLString: String, onDone: @escaping () -> Void) {
        self.articleURLString = articleURLString
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        // Delete a downloaded-but-never-saved preview file when the screen closes
        // (any dismissal path), so previews don't accumulate in the temp dir.
        if let url = unsavedPreviewFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The screen carries its own header pill and its own floating exit button,
    /// so the host's navigation bar would be an empty strip above them.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        // The header states the one fact this screen exists to report. It used
        // to be a 44pt checkmark, the word "Saved", AND a navigation title
        // hard-coded to "Luna Downloader" (wrong in the three other apps that
        // present this screen) — three pieces of chrome for one sentence.
        let savedBadge = GlassConfirmationBadge(title: L10n.string("Saved to Luna"))

        // Confirmation + download controls sit at the TOP.
        // All platforms use the same confirmation header. Downloadable media,
        // including YouTube videos, renders only in the extension playback area
        // below so there is one resolver, one preview, and one set of controls.
        let topStack = UIStackView(arrangedSubviews: [savedBadge] + mediaDownloadViews())
        topStack.axis = .vertical
        topStack.spacing = 14
        topStack.setCustomSpacing(24, after: savedBadge)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topStack)
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            topStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            topStack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            // A wide extension sheet on iPad would otherwise stretch the media
            // preview and its two buttons the whole way across.
            topStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: LunaLayout.readableWidth),
        ])

        ExtensionExitButton.install(in: self) { [weak self] in self?.onDone() }

        beginMediaFlow()
    }

    // MARK: - Media preview UI

    /// The inline media preview + the Download / Save-to-Photos buttons + (hidden)
    /// progress bar / status, shown only for downloadable platforms. The preview
    /// reserves fixed space so nothing above or the friend list below shifts as the
    /// media state resolves. Non-downloadable items still get the destructive exit
    /// action, but omit the media preview controls.
    private func mediaDownloadViews() -> [UIView] {
        configureDeleteButton()
        guard MediaDownloadablePlatform.supports(articleURLString) else {
            return [deleteButton]
        }

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = LunaColors.secondaryBackground
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true

        previewImageView.contentMode = .scaleAspectFit
        previewImageView.clipsToBounds = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewImageView)

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

        previewPlaceholder.text = L10n.string("Unable to preview media")
        previewPlaceholder.font = .preferredFont(forTextStyle: .subheadline)
        previewPlaceholder.textColor = LunaColors.secondaryText
        previewPlaceholder.textAlignment = .center
        previewPlaceholder.numberOfLines = 0
        previewPlaceholder.isHidden = true
        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewPlaceholder)

        // Tap the preview to play the downloaded video.
        previewContainer.isUserInteractionEnabled = true
        previewContainer.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(previewTapped)))

        NSLayoutConstraint.activate([
            previewContainer.heightAnchor.constraint(equalToConstant: Self.previewHeight),
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

        downloadButton.configuration = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Download media"), symbol: "arrow.down.circle",
            prominent: true, tint: Self.tint)
        downloadButton.addAction(
            UIAction { [weak self] _ in self?.startMediaDownload() }, for: .touchUpInside)
        downloadButtonSlot.translatesAutoresizingMaskIntoConstraints = false
        downloadButtonSlot.addSubview(downloadButton)
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            downloadButtonSlot.heightAnchor.constraint(equalToConstant: 50),
            downloadButton.topAnchor.constraint(equalTo: downloadButtonSlot.topAnchor),
            downloadButton.bottomAnchor.constraint(equalTo: downloadButtonSlot.bottomAnchor),
            downloadButton.leadingAnchor.constraint(equalTo: downloadButtonSlot.leadingAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: downloadButtonSlot.trailingAnchor),
        ])

        shareButton.configuration = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Share"), symbol: "square.and.arrow.up", tint: Self.tint)
        shareButton.addAction(
            UIAction { [weak self] _ in self?.shareDownloadedMedia() }, for: .touchUpInside)
        shareButton.isEnabled = false
        // Hold layout space (visible but disabled) so the row height is stable.

        setSaveButton(savedToPhotos: false)
        saveButton.addAction(
            UIAction { [weak self] _ in self?.saveToPhotos() }, for: .touchUpInside)
        saveButton.isEnabled = false
        // Hold layout space (visible but disabled) so the row height is stable.

        let mediaActions = UIStackView(arrangedSubviews: [shareButton, saveButton])
        mediaActions.axis = .horizontal
        mediaActions.spacing = 10
        mediaActions.distribution = .fillEqually

        downloadStatus.isHidden = true
        downloadStatus.font = .preferredFont(forTextStyle: .subheadline)
        downloadStatus.textColor = LunaColors.secondaryText
        downloadStatus.textAlignment = .center
        downloadStatus.numberOfLines = 0

        return [
            previewContainer, downloadButtonSlot, mediaActions, deleteButton, downloadStatus
        ]
    }

    private func configureDeleteButton() {
        guard deleteButton.configuration == nil else { return }
        var config = GlassStyle.actionButtonConfiguration(
            title: L10n.string("Delete and exit"), symbol: "trash", tint: Self.tint)
        // Quiet glass, but the label and glyph stay unmistakably destructive.
        config.baseForegroundColor = LunaColors.errorAccent
        deleteButton.configuration = config
        deleteButton.addAction(
            UIAction { [weak self] _ in self?.deleteAndExit() }, for: .touchUpInside)
    }

    // MARK: - Media flow (state machine)

    /// Entry point after layout: auto-download immediately when the setting is ON,
    /// otherwise rest in the pending state until the user taps Download.
    private func beginMediaFlow() {
        guard MediaDownloadablePlatform.supports(articleURLString) else { return }
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
        switch state {
        case .downloading:
            session.awaitsMediaPlayback = true
        case .pending, .failed:
            session.awaitsMediaPlayback = false
        case let .ready(media):
            let fileURL = media.fileURL
            session.retain(media) {
                try? FileManager.default.removeItem(at: fileURL)
            }
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

    /// Renders the UI for a state. The single source of truth for what each control
    /// shows, so transitions stay consistent.
    private func applyMediaState(_ state: MediaState) {
        mediaState = state
        // Track the live preview file for teardown cleanup (only `.ready` has one).
        if case .ready(let media) = state {
            unsavedPreviewFileURL = media.fileURL
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
            saveButton.isEnabled = false
            downloadStatus.text = L10n.string("Downloading…")
            downloadStatus.textColor = LunaColors.secondaryText
            downloadStatus.isHidden = false

        case .ready(let media):
            pendingIconView.isHidden = true
            downloadButton.isHidden = true
            downloadProgress.isHidden = true
            downloadStatus.isHidden = true
            shareButton.isEnabled = true
            setSaveButton(savedToPhotos: didSaveToPhotos)
            showReadyPreview(media)
            persistToDownloaderLibraryIfNeeded(media)

        case .alreadyDownloaded(let item):
            pendingIconView.isHidden = true
            downloadButton.isHidden = true
            downloadProgress.isHidden = true
            downloadStatus.isHidden = true
            shareButton.isEnabled = true
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
                let message = (error as? MediaDownloadError)?.message ?? L10n.string("Couldn't download the media.")
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
        let creator = readingItem?.channelName
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
                    title: title,
                    creator: creator)
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
                            creator: creator, requiringItemID: pending.id)
                    }
                } else {
                    saved = try store.addDownloadedFile(
                        copy, kind: kind, sourceURLString: sourceURLString, title: title,
                        creator: creator, requiringItemID: pending.id)
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
                    let message = (error as? MediaDownloadError)?.message ?? L10n.string("Couldn't save the media.")
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
                    let message = (error as? MediaDownloadError)?.message ?? L10n.string("Couldn't save the media.")
                    await MainActor.run { self.finishSave(message: message, success: false) }
                }
            }
        default:
            break
        }
    }

    private func showSavingStatus() {
        downloadStatus.text = L10n.string("Saving to Photos…")
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

    /// The Photos button, in either state. It is the prominent action of its row
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
            ? L10n.string("Saved to Photos") : L10n.string("Save to Photos")
    }

    /// "Save to 🌸 Photos" — the Photos mark placed inline, at the position the
    /// localized string chooses (the marker is a format argument, so a
    /// translation can move it with the noun it belongs to).
    @MainActor
    private static func photosTitle(savedToPhotos: Bool) -> AttributedString {
        let marker = "\u{FFFC}"   // OBJECT REPLACEMENT CHARACTER
        let text = savedToPhotos
            ? L10n.string("Saved to \(marker) Photos")
            : L10n.string("Save to \(marker) Photos")
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
        guard !isDeleting else { return }
        isDeleting = true
        deleteButton.isEnabled = false
        downloadButton.isEnabled = false
        shareButton.isEnabled = false
        saveButton.isEnabled = false
        downloadStatus.text = L10n.string("Deleting…")
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
                    ?? L10n.string("Couldn't delete this media.")
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
