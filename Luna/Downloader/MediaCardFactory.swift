//
//  MediaCardFactory.swift
//  Luna
//
//  Builds the Downloader's media card surfaces from a `SavedMediaItem`: the
//  looping video/audio player, the animated GIF, the full-resolution image, or
//  the not-yet-downloaded card with its in-card progress bar — plus the
//  card-sized thumbnail behind the scrub strip and the Photos-reference badge.
//
//  It exists because two decks render the same media card: the Downloader's own
//  root screen and the central Luna app's all-kinds deck, both of which must
//  show a downloaded save with the real player rather than a title and a link.
//  Compiled only into media-handling targets (Luna and LunaDownloader).
//

import AVFoundation
import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaSaves
import LunaSocialUI
import LunaStorage
import Photos
import UIKit

/// The chat hand-off for a download that found nothing to download. The page
/// is the same kind of dead end the failed-save card offers the row for, so it
/// offers the same row (`claudedocs/llm-handoff.md`).
@MainActor
enum MediaCardHandoff {

    /// Records the hand-off against the save that owns `sourceURLString` —
    /// creating one if the media was saved without a row — and opens the
    /// provider.
    static func begin(provider: LLMProvider, sourceURLString: String) {
        guard let url = URL(string: sourceURLString) else { return }
        let store = SavesStore.shared
        guard let itemID = store.item(forURLString: sourceURLString)?.id
            ?? store.addIfAbsent(urlString: sourceURLString, source: .manual)?.id
        else { return }
        let prompt = LLMHandoffPrompts.recovery(
            url: url, app: LunaApp.current,
            failure: SaveFailureReason.rescueSentence(.noMediaFound, attempted: .media))
        let target = LLMProviderPreferences.claudeTarget
        guard let link = LLMDeepLink.url(for: provider, prompt: prompt, claudeTarget: target)
        else { return }
        LLMHandoffStore.shared.begin(
            .recovery(itemID: itemID, urlString: sourceURLString),
            provider: provider, claudeTarget: target)
        LLMLauncher.shared.openLLM(
            link,
            fallback: LLMDeepLink.fallbackURL(
                for: provider, prompt: prompt, claudeTarget: target))
    }
}

enum MediaCardFactory {

    /// The card content for one saved media item. `download` is invoked by the
    /// undownloaded card's button.
    static func makeCard(
        for item: SavedMediaItem,
        scale: CGFloat,
        download: @escaping () -> Void
    ) -> CardContentViewController {
        switch item.storageState {
        case .undownloaded:
            return UndownloadedMediaCardContentViewController(item: item, download: download)
        case .localFile:
            guard let fileURL = item.fileURL else { return CardContentViewController() }
            switch item.kind {
            case .video:
                let content = VideoCardContentViewController(
                    fileURL: fileURL, speedMemoryKey: speedMemoryKey(for: item))
                loadThumbnail(for: item, scale: scale) { [weak content] image in
                    DispatchQueue.main.async { content?.setPosterImage(image) }
                }
                return content
            case .audio:
                let content = VideoCardContentViewController(
                    fileURL: fileURL, speedMemoryKey: speedMemoryKey(for: item))
                content.setPosterImage(UIImage(systemName: "waveform.circle.fill"))
                return content
            case .gif:
                return AnimatedImageCardContentViewController(fileURL: fileURL)
            default:
                return ImageCardContentViewController(loader: { completion in
                    // Full resolution (aspect-fit to the card) — decode off-main
                    // so a large photo doesn't hitch the carousel.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let raw = UIImage(contentsOfFile: fileURL.path)
                        completion(raw?.preparingForDisplay() ?? raw)
                    }
                })
            }
        case .photosReference(let identifier):
            if item.kind == .video || item.kind == .audio {
                let content = VideoCardContentViewController(
                    itemProvider: { completion in
                        loadPhotosVideoItem(identifier: identifier, completion: completion)
                    },
                    speedMemoryKey: speedMemoryKey(for: item))
                loadThumbnail(for: item, scale: scale) { [weak content] image in
                    DispatchQueue.main.async { content?.setPosterImage(image) }
                }
                return content
            }
            return ImageCardContentViewController(loader: { completion in
                loadPhotosImage(
                    identifier: identifier, targetSize: PHImageManagerMaximumSize,
                    completion: completion)
            })
        }
    }

    /// The identity a playback speed is remembered against — the media row, not
    /// the card, so the speed survives the card being unmounted two slots out
    /// and rebuilt on the way back, and is the SAME memory whichever deck (the
    /// Downloader's or the central app's) or player surface shows the item.
    static func speedMemoryKey(for item: SavedMediaItem) -> String {
        "savedMedia.\(item.id.uuidString)"
    }

    /// The badge pinned to a card's top-leading corner for media that lives in
    /// the photo library, opening the asset in Photos. Nil for everything else.
    static func photosBadge(for item: SavedMediaItem) -> UIView? {
        guard let identifier = item.photosLocalIdentifier else { return nil }
        return PhotosReferenceBadgeView { openInPhotos(localIdentifier: identifier) }
    }

    static func openInPhotos(localIdentifier: String) {
        // Photos routes assets by the UUID component of PhotoKit's durable
        // local identifier. Use its public redirect scheme and fall back to
        // opening the library if this OS cannot resolve the asset route.
        let uuid = localIdentifier.split(separator: "/", maxSplits: 1).first.map(String.init)
        var components = URLComponents()
        components.scheme = "photos-redirect"
        components.host = "asset"
        components.queryItems = uuid.map { [URLQueryItem(name: "uuid", value: $0)] }

        guard let destination = components.url else { return }
        UIApplication.shared.open(destination) { success in
            guard !success, let library = URL(string: "photos-redirect://") else { return }
            UIApplication.shared.open(library)
        }
    }

    /// A mid-size decode shared by the scrub strip and its card-sized preview
    /// (which is why thumbnails are decoded larger than the strip alone needs).
    static func loadThumbnail(
        for item: SavedMediaItem, scale: CGFloat, completion: @escaping (UIImage?) -> Void
    ) {
        if let url = item.thumbnailURL {
            DownsampledImageLoader.load(
                path: url.path,
                pointSize: CGSize(width: 300, height: 300),
                scale: scale,
                isStale: { false }
            ) { image in
                completion(image)
            }
        } else if let identifier = item.photosLocalIdentifier {
            loadPhotosImage(
                identifier: identifier,
                targetSize: CGSize(width: 600, height: 600),
                completion: completion)
        } else {
            completion(nil)
        }
    }

    static func loadPhotosImage(
        identifier: String,
        targetSize: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) {
        Task { @MainActor in
            guard await PhotoLibrarySaver().requestReadAuthorization(),
                  let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier], options: nil).firstObject
            else {
                completion(nil)
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                completion(image)
            }
        }
    }

    static func loadPhotosVideoItem(
        identifier: String,
        completion: @escaping (AVPlayerItem?) -> Void
    ) {
        Task { @MainActor in
            guard await PhotoLibrarySaver().requestReadAuthorization(),
                  let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier], options: nil).firstObject
            else {
                completion(nil)
                return
            }
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
                avAsset, _, _ in
                completion(avAsset.map { AVPlayerItem(asset: $0) })
            }
        }
    }
}

/// The verbs a media row offers, and the storage work behind two of them.
///
/// It exists for the same reason `MediaCardFactory` does: two decks show the
/// same media save — the Downloader's own root and the central app's
/// all-kinds deck — and both need the same answer to "what can you do with
/// this?" and "what goes when it goes?", one switch over `storageState`
/// rather than two.
enum MediaItemActions {

    /// What you can do with a media row depends only on where its file is: an
    /// undownloaded row can be fetched, a local one can be shared and put in
    /// Photos, one that is ALREADY in Photos can only be shared. In that order,
    /// above whatever the deck adds of its own (Archive, Delete).
    static func menuActions(
        for item: SavedMediaItem,
        download: @escaping () -> Void,
        share: @escaping () -> Void,
        saveToPhotos: @escaping () -> Void
    ) -> [UIMenuElement] {
        switch item.storageState {
        case .undownloaded:
            return [UIAction(
                title: L10n.string("Common_download"), image: UIImage(systemName: "arrow.down.circle")
            ) { _ in download() }]
        case .localFile:
            var actions: [UIMenuElement] = [UIAction(
                title: L10n.string("Common_share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in share() }]
            if item.kind?.canSaveToPhotos == true {
                actions.append(UIAction(
                    title: L10n.string("Downloader_mediaCard_menu_saveToPhotos"),
                    image: UIImage(systemName: "photo.badge.plus")
                ) { _ in saveToPhotos() })
            }
            return actions
        case .photosReference:
            return [UIAction(
                title: L10n.string("Common_share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in share() }]
        }
    }

    /// The share circle's menu for a media row, in the reader pill's ladder
    /// shape: the link verbs first, then the file itself once Luna actually
    /// holds one. The link is always `sourceURLString` — the original URL the
    /// save came from, never the resolved CDN asset — and it is shareable in
    /// every storage state, which is why an undownloaded row still gets a menu
    /// (just without its file row). Both decks that show media hang this off
    /// their trailing circle, so the options never diverge between apps.
    static func shareMenuRows(
        for item: SavedMediaItem,
        copyLink: @escaping () -> Void,
        shareLink: @escaping () -> Void,
        shareFile: @escaping () -> Void
    ) -> [ReaderShareSheet.Row] {
        var rows = linkRows(copyLink: copyLink, shareLink: shareLink)
        if case .undownloaded = item.storageState {} else {
            rows.append(.action(
                title: shareFileTitle(for: item.kind),
                systemImage: shareFileSymbol(for: item.kind),
                action: shareFile))
        }
        // A media save's id is its save row's id, so an export plugin that
        // handles `media` offers its rows here too (§9.3).
        rows += ReaderShareSheet.pluginRows(forSaveID: item.id, kind: .media)
        return rows
    }

    /// The two link rungs every save offers, whatever else it holds.
    private static func linkRows(
        copyLink: @escaping () -> Void,
        shareLink: @escaping () -> Void
    ) -> [ReaderShareSheet.Row] {
        [
            .action(title: L10n.string("Common_copyLink"), systemImage: "doc.on.doc",
                    action: copyLink),
            .action(title: L10n.string("Common_shareLink"), systemImage: "square.and.arrow.up",
                    action: shareLink),
        ]
    }

    /// A nil kind renders as an image card (`MediaCardFactory.makeCard`), so
    /// its share row says the same.
    static func shareFileTitle(for kind: MediaAsset.Kind?) -> String {
        switch kind {
        case .video: return L10n.string("Downloader_mediaCard_shareFile_videoTitle")
        case .gif: return L10n.string("Downloader_mediaCard_shareFile_gifTitle")
        case .audio: return L10n.string("Downloader_mediaCard_shareFile_audioTitle")
        case .image, nil: return L10n.string("Downloader_mediaCard_shareFile_imageTitle")
        }
    }

    private static func shareFileSymbol(for kind: MediaAsset.Kind?) -> String {
        switch kind {
        case .video: return "video"
        case .audio: return "waveform"
        case .gif, .image, nil: return "photo"
        }
    }

    /// The rows as the native menu the trailing circle presents, with the link
    /// verbs wired to the shared social sheet. `shareFile` stays injected — the
    /// export-and-present dance differs per deck (the Downloader prewarms and
    /// pauses its player; the all-kinds deck exports cold).
    static func shareMenu(
        for item: SavedMediaItem,
        presenter: UIViewController,
        sourceView: UIView?,
        shareFile: @escaping () -> Void
    ) -> UIMenu {
        ReaderShareSheet.menu(rows: shareMenuRows(
            for: item,
            copyLink: copyLinkVerb(urlString: item.sourceURLString, presenter: presenter),
            shareLink: shareLinkVerb(
                urlString: item.sourceURLString, presenter: presenter, sourceView: sourceView),
            shareFile: shareFile))
    }

    /// Copy link / Share link alone — for a save Luna knows only as a LINK: a
    /// platform item with no media row behind it. The pill still owes the user
    /// the link verbs there; it just has no file to name.
    static func linkShareMenu(
        urlString: String,
        presenter: UIViewController,
        sourceView: UIView?
    ) -> UIMenu {
        ReaderShareSheet.menu(rows: linkRows(
            copyLink: copyLinkVerb(urlString: urlString, presenter: presenter),
            shareLink: shareLinkVerb(
                urlString: urlString, presenter: presenter, sourceView: sourceView)))
    }

    private static func copyLinkVerb(
        urlString: String, presenter: UIViewController
    ) -> () -> Void {
        { [weak presenter] in
            guard let presenter else { return }
            SendToFriendSheet.copyLink(urlString: urlString, from: presenter)
        }
    }

    private static func shareLinkVerb(
        urlString: String, presenter: UIViewController, sourceView: UIView?
    ) -> () -> Void {
        { [weak presenter, weak sourceView] in
            guard let presenter else { return }
            SendToFriendSheet.shareLink(
                urlString: urlString, from: presenter, sourceView: sourceView)
        }
    }

    /// An explicit "download this exact item now" gesture — it bypasses the
    /// Wi-Fi-only setting, unlike the opportunistic resume sweep.
    static func startManualDownload(_ item: SavedMediaItem) {
        Task {
            _ = await LiveMediaDownloadManager.shared.start(
                urlString: item.sourceURLString, title: item.title, manual: true)
        }
    }

    /// Where a media row's file actually is, as one string — the change key both
    /// decks fingerprint a media card by, so a download that finishes in the
    /// background re-renders the card instead of leaving a placeholder.
    static func storageStateKey(_ item: SavedMediaItem) -> String {
        switch item.storageState {
        case .undownloaded: return "undownloaded"
        case .localFile: return "local|\(item.fileName ?? "")"
        case .photosReference(let identifier): return "photos|\(identifier)"
        }
    }

    /// Saves a defensive COPY of the row's local file to Photos (never the file
    /// itself) — moving the original would risk losing Luna's own copy if the
    /// Photos save fails or is slow.
    static func saveToPhotos(
        _ item: SavedMediaItem,
        saver: PhotoLibrarySaver,
        from presenter: UIViewController
    ) {
        Task { @MainActor in
            do {
                guard case .localFile = item.storageState,
                      let fileURL = item.fileURL, let kind = item.kind
                else { return }
                guard await saver.requestReadAuthorization() else {
                    presentAlert(
                        title: L10n.string("Downloader_mediaCard_photosAccess_title"),
                        message: L10n.string("Downloader_mediaCard_photosAccess_saveMessage"),
                        from: presenter)
                    return
                }
                let tempURL = MediaDownloadStorage.newFileURL(extension: fileURL.pathExtension)
                try FileManager.default.copyItem(at: fileURL, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await SavedMediaPhotosSync.saveAndTransition(
                    itemID: item.id, fileURL: tempURL, kind: kind, shouldMoveFile: true,
                    saver: saver, store: SavedMediaStore.shared)
                presentAlert(
                    title: L10n.string("Downloader_mediaCard_savedToPhotosAlert_title"),
                    message: L10n.string("Downloader_mediaCard_savedToPhotosAlert_message"),
                    from: presenter)
            } catch {
                presentAlert(
                    title: L10n.string("Downloader_mediaCard_saveFailedAlert_title"),
                    message: L10n.string("Downloader_mediaCard_saveFailedAlert_message"), from: presenter)
            }
        }
    }

    /// Everything that belongs to a media row besides the row itself: its Photos
    /// asset and the auto-download bookkeeping that would otherwise treat the URL
    /// as already fetched. The whole save goes when the card does.
    ///
    /// - Parameters:
    ///   - deletesSavedItem: true for a deck whose card IS the media row
    ///     (the Downloader's), false where the save entry is the card and
    ///     its own deck deletes it.
    ///   - onPhotosDeletionFailure: the Downloader tells the user its Photos
    ///     deletion needs permission; the all-kinds deck lets it pass, having
    ///     already removed the card.
    static func release(
        _ item: SavedMediaItem,
        saver: PhotoLibrarySaver,
        deletesSavedItem: Bool,
        onPhotosDeletionFailure: (@MainActor () -> Void)? = nil
    ) {
        Task { @MainActor in
            do {
                if let localIdentifier = item.photosLocalIdentifier {
                    try await SavedMediaPhotosSync.deletePhotosAssetIfPresent(
                        localIdentifier, saver: saver)
                }
                AutoDownloadSettings.unmarkDownloaded(item.sourceURLString)
                if deletesSavedItem,
                   let saved = SavesStore.shared.item(forURLString: item.sourceURLString) {
                    SavesStore.shared.delete(saved)
                }
                SavedMediaStore.shared.delete(item)
            } catch {
                onPhotosDeletionFailure?()
            }
        }
    }

    static func presentAlert(title: String, message: String, from presenter: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        presenter.present(alert, animated: true)
    }
}

// MARK: - Undownloaded card content

/// Card content for an item whose media hasn't been fetched yet. During a job it
/// becomes a real downloading card: early poster, explicit status, percentage,
/// and the same moon-horizon progress bar the Live Activity draws — all inside
/// this card. There is deliberately no app-level download bar: the download
/// belongs to one item, so its progress is drawn on that item.
///
/// The bar is a pure OBSERVER of `LiveMediaDownloadManager`'s job state. Nothing
/// here starts, holds, or stops the transfer, so paging this card off screen (or
/// backgrounding the app) tears the view down without touching the background
/// URLSession; `viewDidLoad` re-reads `currentDownloadSnapshot` so a card that
/// comes back mid-transfer picks the bar up where it is.
final class UndownloadedMediaCardContentViewController: CardContentViewController {

    private let sourceURLString: String
    private let download: () -> Void
    private let button = UIButton(configuration: .plain())
    private let poster = UIImageView()
    private let posterDim = UIView()
    private let statusLabel = UILabel()
    private let percentLabel = UILabel()
    private let progress = MoonHorizonProgressBar()
    /// The embedded bar: a glass slab inside the card's bottom edge, reading
    /// status on the leading side and percent-complete on the trailing side,
    /// with the horizon bar spanning beneath them.
    private let statusBar = UIVisualEffectView(effect: GlassStyle.barEffect())
    /// The chat hand-off, shown for the one failure a model can answer: the
    /// page held no media this app could recognise.
    private lazy var handoffRow = LLMHandoffRowView()
    private var loadedThumbnailFileName: String?

    init(item: SavedMediaItem, download: @escaping () -> Void) {
        self.sourceURLString = item.sourceURLString
        self.download = download
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        poster.contentMode = .scaleAspectFit
        poster.clipsToBounds = true
        poster.isHidden = true
        poster.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(poster)

        posterDim.backgroundColor = UIColor.black.withAlphaComponent(0.24)
        posterDim.isHidden = true
        posterDim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(posterDim)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "arrow.down.circle.dotted")
            ?? UIImage(systemName: "arrow.down.circle")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 52, weight: .regular)
        configuration.baseForegroundColor = LunaColors.secondaryText
        button.configuration = configuration
        button.accessibilityLabel = L10n.string("Downloader_mediaCard_downloadAccessibilityLabel")
        button.addAction(UIAction { [weak self] _ in self?.download() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        handoffRow.delegate = self
        handoffRow.isHidden = true
        handoffRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(handoffRow)

        statusLabel.text = L10n.string("Common_downloading")
        statusLabel.textColor = LunaColors.primaryText
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.numberOfLines = 2

        percentLabel.textColor = LunaColors.secondaryText
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        percentLabel.textAlignment = .right
        percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        progress.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [statusLabel, percentLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        let column = UIStackView(arrangedSubviews: [row, progress])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false

        statusBar.isHidden = true
        statusBar.clipsToBounds = true
        // Purely informational: the card's own tap/scrub handling must still see
        // the points the bar covers. Cancel/retry live on the card's controls.
        statusBar.isUserInteractionEnabled = false
        if #available(iOS 26.0, *) {
            statusBar.cornerConfiguration = .corners(radius: .fixed(18))
        } else {
            statusBar.layer.cornerRadius = 18
            statusBar.layer.cornerCurve = .continuous
        }
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.contentView.addSubview(column)
        view.addSubview(statusBar)

        NSLayoutConstraint.activate([
            poster.topAnchor.constraint(equalTo: view.topAnchor),
            poster.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            poster.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            posterDim.topAnchor.constraint(equalTo: view.topAnchor),
            posterDim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            posterDim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            posterDim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            handoffRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            handoffRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            handoffRow.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -16),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusBar.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            column.leadingAnchor.constraint(
                equalTo: statusBar.contentView.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(
                equalTo: statusBar.contentView.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: statusBar.contentView.topAnchor, constant: 10),
            column.bottomAnchor.constraint(
                equalTo: statusBar.contentView.bottomAnchor, constant: -10),
            progress.heightAnchor.constraint(equalToConstant: 20),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobProgressChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
        #if DEBUG
        if let stagedSnapshot {
            apply(stagedSnapshot)
            return
        }
        #endif
        apply(LiveMediaDownloadManager.shared.currentDownloadSnapshot(
            forSourceURLString: sourceURLString))
    }

    #if DEBUG
    /// Staged mode's hold on a download state (`claudedocs/staging.md`). A real
    /// transfer passes through resolving/downloading/failed in seconds, so
    /// there is no way to capture one from the outside; set this before the
    /// view loads and the card renders that state and stays on it — nothing in
    /// a staged run posts a progress notification to move it off.
    var stagedSnapshot: DownloaderJobSnapshot?
    #endif

    @objc private func handleJobProgressChanged(_ notification: Notification) {
        guard let urlString = notification.userInfo?["sourceURLString"] as? String,
              urlString == sourceURLString
        else { return }
        let snapshot = notification.userInfo?["snapshot"] as? DownloaderJobSnapshot
        DispatchQueue.main.async { [weak self] in
            self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: DownloaderJobSnapshot?) {
        guard let snapshot else {
            statusBar.isHidden = true
            posterDim.isHidden = true
            button.isHidden = false
            handoffRow.isHidden = true
            return
        }

        statusLabel.text = snapshot.message
        statusLabel.textColor = snapshot.phase == .failed
            ? .systemRed : LunaColors.primaryText
        // A percentage is only honest once bytes are actually moving; resolving
        // and waiting phases have no meaningful fraction yet.
        percentLabel.text = snapshot.phase == .downloading
            ? "\(Int((snapshot.progress * 100).rounded()))%" : nil
        progress.isHidden = snapshot.phase == .failed
        progress.setProgress(Float(snapshot.progress), animated: true)
        statusBar.isHidden = false
        button.isHidden = snapshot.phase != .failed
        // Only a no-media failure has a page a model could read. Every other
        // failure is a transfer that can simply be tried again.
        handoffRow.isHidden = !(snapshot.phase == .failed && snapshot.failureKind == .noMedia)

        guard let fileName = snapshot.thumbnailFileName,
              fileName != loadedThumbnailFileName
        else {
            posterDim.isHidden = poster.isHidden
            return
        }
        loadedThumbnailFileName = fileName
        let path = LiveMediaDownloadAssets.thumbnailURL(fileName: fileName).path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = UIImage(contentsOfFile: path)?.preparingForDisplay()
            DispatchQueue.main.async {
                guard let self, self.loadedThumbnailFileName == fileName,
                      let image else { return }
                self.poster.image = image
                self.poster.isHidden = false
                self.posterDim.isHidden = false
            }
        }
    }

    #if DEBUG
    /// The embedded bar, exposed so a test can assert it is inside this card's
    /// own view (never host chrome) and that it mirrors the job snapshot.
    var downloadBarForTesting: UIView { statusBar }
    var isDownloadBarVisibleForTesting: Bool { !statusBar.isHidden }
    var statusTextForTesting: String? { statusLabel.text }
    var percentTextForTesting: String? { percentLabel.text }
    var progressForTesting: Float { progress.progress }
    var isRetryGlyphVisibleForTesting: Bool { !button.isHidden }
    #endif
}

// MARK: - The Downloader's root deck

/// The Downloader's home screen: the shared deck host, the media kind's style,
/// and the one universal provider. Built here rather than inside
/// `KindWiring+Downloader` so the deck the tests exercise is the deck the app
/// ships — and so the app needs no deck subclass of its own at all.
enum MediaCardDeck {

    @MainActor
    static func makeRoot() -> CardCarouselHostViewController {
        let deck = CardCarouselHostViewController()
        // The same strip geometry as every other app: the viewport begins and
        // ends at the inner edges of the flanking 44pt circles, and chips
        // alpha-fade before they reach them.
        let style = CardCarouselStyle.singleKindDeck
        deck.configure(style: style) { host in
            var configuration = CardDeckConfiguration()
            // This app has no generic link card, so a platform save with
            // nothing downloaded behind it is not a slot here.
            configuration.showsSavesWithoutKindContent = false
            // The LINK is shareable in every storage state — only the file row of
            // the menu waits for a download — so the circle shows for any media
            // card and hides on the util and failed-save ones.
            configuration.shareButton = CardDeckShareButton(
                accessibilityLabel: L10n.string("Downloader_mediaCard_shareCircleAccessibilityLabel"),
                unavailability: .hides)
            return KindDeckProvider(host: host, configuration: configuration)
        }
        return deck
    }
}

// MARK: - The chat hand-off row

extension UndownloadedMediaCardContentViewController: LLMHandoffRowDelegate {

    func row(_ row: LLMHandoffRowView, didChoose provider: LLMProvider) {
        MediaCardHandoff.begin(provider: provider, sourceURLString: sourceURLString)
        row.setHint(LLMHandoffRowView.waitingHint())
    }
}
