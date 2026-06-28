//
//  SavedNonTextualViewController.swift
//  ClipShare
//

import ClipMediaDownload
import ClipDesignSystem
import ClipStorage
import ClipURLClassification
import ClipModels
import AVKit
import CoreMedia
import ImageIO
import UIKit

/// Shown by the action extension for non-textual content (a video, post, etc.):
/// the URL is already saved, so this confirms the save and — for shareable links,
/// when there are friends — shows a scrolling friend list; tapping a friend QUEUES
/// the send to the App Group (the app delivers it on next launch). The confirmation
/// content sits near the top to leave room for the friend list. No eBook / system
/// share. YouTube embeds play inline. Done dismisses the extension.
///
/// For downloadable platforms (X / Instagram / TikTok / Facebook) the media is
/// fetched and shown INLINE: when the "Auto-download media" setting is ON the file
/// downloads automatically on appear (spinner while it streams to disk); when OFF
/// the preview starts PENDING (media icon + "Download" button) and downloads only
/// on tap. A video gets a play-button overlay (tap → AVPlayer); an image just
/// displays. Once downloaded (auto or manual) a "Save to Photos" button enables;
/// saving writes to the Photos library AND marks the item read in the reading list.
final class SavedNonTextualViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let articleURLString: String
    private let content: NonTextualContent
    private let onDone: () -> Void

    private let friends = ExtensionFriendsReader.friends()
    private let friendsTable = UITableView(frame: .zero, style: .plain)
    private let savedLabel = UILabel()

    // MARK: - Downloadable-media state machine

    /// The lifecycle of the inline media preview for a downloadable platform.
    private enum MediaState {
        /// Auto-download is OFF: nothing fetched yet; show a media icon + Download button.
        case pending
        /// The media file is streaming to disk; show a spinner.
        case downloading
        /// The file is on disk and shown inline; "Save to Photos" is enabled.
        case ready(DownloadedMedia)
        /// Download failed; show the error and let the user retry.
        case failed(message: String)
    }

    private var mediaState: MediaState = .pending
    private let downloadService = MediaDownloadService()

    /// The on-disk preview file that still needs cleanup: set when media becomes
    /// `.ready`, cleared once it's saved to Photos (PhotoKit moves/consumes the
    /// file). Deleted in `deinit` so a downloaded-but-never-saved preview doesn't
    /// linger in the temp dir after the screen closes. (A startup sweep,
    /// `MediaDownloadStorage.purgeAll()`, catches files orphaned by a kill.)
    private var unsavedPreviewFileURL: URL?

    // A fixed-height media preview area. Reserves space from load so the layout
    // never shifts as the media state resolves: it hosts the spinner, the still
    // image / video poster, the play overlay, the pending media icon, and any
    // load-failure placeholder.
    private let previewContainer = UIView()
    private let previewImageView = UIImageView()
    private let previewSpinner = UIActivityIndicatorView(style: .large)
    /// A large media icon shown in the pending state (before any download starts).
    private let pendingIconView = UIImageView()
    /// A YouTube-style play overlay shown when the downloaded media is a video.
    private let playOverlay = UIView()
    /// Shown (grey box + message) when media exists but its preview couldn't render.
    private let previewPlaceholder = UILabel()
    private static let previewHeight: CGFloat = 220

    // The action row: a primary button that is "Download media" (pending) /
    // "Downloading…" / hidden (ready), and a "Save to Photos" button enabled once a
    // file exists. A status label carries errors. All hold layout space from load.
    private let downloadButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let downloadProgress = UIProgressView(progressViewStyle: .default)
    private let downloadStatus = UILabel()

    init(articleURLString: String, content: NonTextualContent, onDone: @escaping () -> Void) {
        self.articleURLString = articleURLString
        self.content = content
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        // Delete a downloaded-but-never-saved preview file when the screen closes
        // (any dismissal path), so previews don't accumulate in the temp dir.
        if let url = unsavedPreviewFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Saved to Queue"

        let onDone = self.onDone
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in onDone() })

        let badge = UIImageView(image: UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)))
        badge.tintColor = GlassStyle.readingAccent
        badge.contentMode = .center

        savedLabel.text = "Saved to your reading list."
        savedLabel.font = .preferredFont(forTextStyle: .body)
        savedLabel.textColor = .secondaryLabel
        savedLabel.textAlignment = .center
        savedLabel.numberOfLines = 0

        // A video (YouTube) shows a STATIC poster + play button — never an autoplaying
        // player; other platforms show the confirmation badge.
        let topView: UIView
        if let posterURL = content.staticPreviewImageURL {
            topView = makeVideoPoster(thumbnailURL: posterURL)
        } else {
            topView = badge
        }

        // Confirmation + download controls sit at the TOP.
        let topStack = UIStackView(arrangedSubviews: [topView, savedLabel] + mediaDownloadViews())
        topStack.axis = .vertical
        topStack.spacing = 16
        topStack.setCustomSpacing(24, after: savedLabel)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topStack)
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            topStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        beginMediaFlow()

        // A scrolling friend list fills the rest — tapping one shares instantly.
        guard articleURLString.hasPrefix("http"), !friends.isEmpty else { return }
        let friendsHeader = UILabel()
        friendsHeader.text = "Send to a Friend"
        friendsHeader.font = .systemFont(ofSize: 15, weight: .semibold)
        friendsHeader.textColor = .secondaryLabel
        friendsHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(friendsHeader)

        friendsTable.dataSource = self
        friendsTable.delegate = self
        friendsTable.rowHeight = 52
        friendsTable.register(UITableViewCell.self, forCellReuseIdentifier: "friend")
        friendsTable.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(friendsTable)

        NSLayoutConstraint.activate([
            friendsHeader.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 28),
            friendsHeader.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            friendsHeader.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            friendsTable.topAnchor.constraint(equalTo: friendsHeader.bottomAnchor, constant: 6),
            friendsTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            friendsTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            friendsTable.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Media preview UI

    /// The inline media preview + the Download / Save-to-Photos buttons + (hidden)
    /// progress bar / status, shown only for downloadable platforms. The preview
    /// reserves fixed space so nothing above or the friend list below shifts as the
    /// media state resolves. Returns an empty array for non-downloadable platforms.
    private func mediaDownloadViews() -> [UIView] {
        guard MediaDownloadablePlatform.supports(articleURLString) else { return [] }

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = .secondarySystemBackground
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true

        previewImageView.contentMode = .scaleAspectFit
        previewImageView.clipsToBounds = true
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewImageView)

        pendingIconView.image = UIImage(
            systemName: "play.rectangle.on.rectangle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .regular))
        pendingIconView.tintColor = .tertiaryLabel
        pendingIconView.contentMode = .center
        pendingIconView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(pendingIconView)

        previewSpinner.hidesWhenStopped = true
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewSpinner)

        // A system-style play badge over the still — revealed only for video media;
        // tapping the preview then plays it.
        playOverlay.isUserInteractionEnabled = false
        playOverlay.isHidden = true
        playOverlay.translatesAutoresizingMaskIntoConstraints = false
        Self.styleAsSystemPlayButton(playOverlay, diameter: 60)
        previewContainer.addSubview(playOverlay)

        previewPlaceholder.text = "Unable to preview media"
        previewPlaceholder.font = .preferredFont(forTextStyle: .subheadline)
        previewPlaceholder.textColor = .secondaryLabel
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
            previewSpinner.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            playOverlay.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            playOverlay.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
        ])

        var dlConfig = UIButton.Configuration.filled()
        dlConfig.title = "Download media"
        dlConfig.image = UIImage(systemName: "arrow.down.circle")
        dlConfig.imagePadding = 8
        dlConfig.baseBackgroundColor = GlassStyle.readingAccent
        downloadButton.configuration = dlConfig
        downloadButton.addAction(
            UIAction { [weak self] _ in self?.startMediaDownload() }, for: .touchUpInside)

        var saveConfig = UIButton.Configuration.tinted()
        saveConfig.title = "Save to Photos"
        saveConfig.image = UIImage(systemName: "photo.badge.arrow.down")
        saveConfig.imagePadding = 8
        saveConfig.baseForegroundColor = GlassStyle.readingAccent
        saveButton.configuration = saveConfig
        saveButton.addAction(
            UIAction { [weak self] _ in self?.saveToPhotos() }, for: .touchUpInside)
        saveButton.isEnabled = false
        // Hold layout space (visible but disabled) so the row height is stable.

        downloadProgress.isHidden = true
        downloadProgress.progressTintColor = GlassStyle.readingAccent

        downloadStatus.isHidden = true
        downloadStatus.font = .preferredFont(forTextStyle: .subheadline)
        downloadStatus.textColor = .secondaryLabel
        downloadStatus.textAlignment = .center
        downloadStatus.numberOfLines = 0

        return [previewContainer, downloadButton, downloadProgress, saveButton, downloadStatus]
    }

    // MARK: - Media flow (state machine)

    /// Entry point after layout: auto-download immediately when the setting is ON,
    /// otherwise rest in the pending state until the user taps Download.
    private func beginMediaFlow() {
        guard MediaDownloadablePlatform.supports(articleURLString) else { return }
        if AutoDownloadSettings.autoDownloadMediaInPreview {
            startMediaDownload()
        } else {
            applyMediaState(.pending)
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
            previewSpinner.stopAnimating()
            pendingIconView.isHidden = false
            previewImageView.isHidden = true
            playOverlay.isHidden = true
            previewPlaceholder.isHidden = true
            downloadButton.isHidden = false
            downloadProgress.isHidden = true
            saveButton.isEnabled = false
            downloadStatus.isHidden = true

        case .downloading:
            previewSpinner.startAnimating()
            pendingIconView.isHidden = true
            previewImageView.isHidden = true
            playOverlay.isHidden = true
            previewPlaceholder.isHidden = true
            downloadButton.isHidden = true
            downloadProgress.progress = 0
            downloadProgress.isHidden = false
            saveButton.isEnabled = false
            downloadStatus.text = "Downloading…"
            downloadStatus.textColor = .secondaryLabel
            downloadStatus.isHidden = false

        case .ready(let media):
            previewSpinner.stopAnimating()
            pendingIconView.isHidden = true
            downloadButton.isHidden = true
            downloadProgress.isHidden = true
            downloadStatus.isHidden = true
            saveButton.isEnabled = true
            showReadyPreview(media)

        case .failed(let message):
            previewSpinner.stopAnimating()
            pendingIconView.isHidden = false
            previewImageView.isHidden = true
            playOverlay.isHidden = true
            previewPlaceholder.isHidden = true
            downloadButton.isHidden = false
            downloadProgress.isHidden = true
            saveButton.isEnabled = false
            downloadStatus.text = message
            downloadStatus.textColor = .systemRed
            downloadStatus.isHidden = false
        }
    }

    /// Streams the first media item to a local file (memory-safe), updating the
    /// progress bar, then transitions to `.ready`. On failure shows `.failed`.
    private func startMediaDownload() {
        guard let url = URL(string: articleURLString) else { return }
        applyMediaState(.downloading)
        Task { [weak self] in
            guard let self else { return }
            do {
                let media = try await downloadService.downloadFirstMediaToFile(from: url) { progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress.setProgress(Float(progress), animated: true)
                    }
                }
                await MainActor.run { self.applyMediaState(.ready(media)) }
            } catch {
                let message = (error as? MediaDownloadError)?.message ?? "Couldn't download the media."
                await MainActor.run { self.applyMediaState(.failed(message: message)) }
            }
        }
    }

    /// Shows the downloaded file inline: a still image renders directly; a video
    /// renders its first-frame poster with the play overlay (tap to play). Persists
    /// the still into the shared store so the app's platform card has a thumbnail.
    private func showReadyPreview(_ media: DownloadedMedia) {
        previewImageView.isHidden = false
        switch media.kind {
        case .image, .gif:
            playOverlay.isHidden = true
            if let image = downsampledImage(from: media.fileURL) {
                previewImageView.image = image
                previewPlaceholder.isHidden = true
                persistPreviewThumbnail(image)
            } else {
                previewImageView.isHidden = true
                previewPlaceholder.isHidden = false
            }
        case .video:
            playOverlay.isHidden = false
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

    /// Tapping the preview plays the downloaded video in an AVPlayerViewController.
    @objc private func previewTapped() {
        guard case .ready(let media) = mediaState, media.kind == .video else { return }
        let player = AVPlayer(url: media.fileURL)
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        present(playerVC, animated: true) { player.play() }
    }

    /// Requests Photos add access and saves the downloaded file, then marks the item
    /// READ in the reading list (new behavior — saving counts as consuming it).
    private func saveToPhotos() {
        guard case .ready(let media) = mediaState else { return }
        saveButton.isEnabled = false
        downloadStatus.text = "Saving to Photos…"
        downloadStatus.textColor = .secondaryLabel
        downloadStatus.isHidden = false

        Task { [weak self] in
            guard let self else { return }
            do {
                try await downloadService.saveDownloadedMediaToPhotos(media)
                // PhotoKit moved the file into the library — no temp file to clean up.
                await MainActor.run { self.unsavedPreviewFileURL = nil }
                AutoDownloadSettings.markDownloaded(articleURLString)
                markItemRead()
                await MainActor.run { self.finishSave(message: "Saved to Photos", success: true) }
            } catch {
                let message = (error as? MediaDownloadError)?.message ?? "Couldn't save the media."
                await MainActor.run { self.finishSave(message: message, success: false) }
            }
        }
    }

    @MainActor
    private func finishSave(message: String, success: Bool) {
        downloadStatus.text = message
        downloadStatus.textColor = success ? .secondaryLabel : .systemRed
        downloadStatus.isHidden = false
        if success {
            var config = saveButton.configuration
            config?.title = "Saved to Photos"
            config?.image = UIImage(systemName: "checkmark.circle.fill")
            config?.baseForegroundColor = .systemGreen
            saveButton.configuration = config
            saveButton.isEnabled = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Flash the saved checkmark, then dismiss the extension right away.
            let onDone = self.onDone
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onDone() }
        } else {
            saveButton.isEnabled = true
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

    /// Decodes a local image file downsampled (ImageIO) so a full-res photo never
    /// sits fully decoded in the memory-constrained extension.
    private func downsampledImage(from fileURL: URL, maxPixelSize: CGFloat = 1400) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

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

    /// Styles `badge` as a system-style play button: a frosted dark circle with a
    /// white play glyph (like Photos / AVKit), replacing the old YouTube-red badge.
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

    /// A static 16:9 video poster (loaded from `thumbnailURL`) with a system-style
    /// play button — shown instead of an autoplaying embed.
    private func makeVideoPoster(thumbnailURL: URL) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .black
        imageView.layer.cornerRadius = 12
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        let playBadge = UIView()
        playBadge.isUserInteractionEnabled = false
        playBadge.translatesAutoresizingMaskIntoConstraints = false
        Self.styleAsSystemPlayButton(playBadge, diameter: 60)
        container.addSubview(playBadge)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 9.0 / 16.0),
            playBadge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        Task { [weak imageView] in
            let image = await MediaPreviewFetcher.image(from: thumbnailURL, maxPixelSize: 1280)
            await MainActor.run { imageView?.image = image }
        }
        return container
    }

    // MARK: - Friend list

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        friends.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "friend", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = friends[indexPath.row].username
        config.image = UIImage(systemName: "person.crop.circle.fill")
        config.imageProperties.tintColor = GlassStyle.readingAccent
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// Tapping a friend queues the send instantly, confirms briefly, then dismisses.
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let friend = friends[indexPath.row]
        PendingFriendShareWriter.enqueue(friendUUID: friend.uuid, urlString: articleURLString)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        savedLabel.text = "Will send to \(friend.username)."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.onDone() }
    }
}
