//
//  SavedMediaCardsViewController.swift
//  Luna
//
//  The Downloader's root screen: a carousel of vertical cards (one saved item
//  per card) over the shared store, replacing the previous Photos-style grid +
//  pushed viewer. The generic carousel machinery (cards, scrub strip, eclipse
//  paging, playback/mute/scrub gestures) lives in LunaDesignSystem/CardCarousel;
//  this controller adapts SavedMediaItems into card content and keeps the grid's
//  store plumbing: cross-process change observation, expiry purge, Photos
//  reconciliation, and context-menu actions. Download progress is never floating
//  chrome: it is drawn inside the card (or archive-tray cell) of the item that is
//  actually downloading, while the transfer itself lives in
//  `LiveMediaDownloadManager`'s background URLSession and so survives paging
//  away, this screen disappearing, and the app being backgrounded.
//

import AVFoundation
import AVKit
import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaReadingList
import LunaReadingListUI
import LunaSocialUI
import LunaStorage
import LunaURLClassification
import Photos
import UIKit

enum SavedMediaCardOrdering {
    static func newestFirst(_ items: [SavedMediaItem]) -> [SavedMediaItem] {
        items.sorted { $0.dateSaved > $1.dateSaved }
    }
}

final class SavedMediaCardsViewController: CardCarouselHostViewController {

    private let store = SavedMediaStore.shared
    private let photoSaver = PhotoLibrarySaver()
    /// The player behind the currently-presented full-screen video, held weakly
    /// so we can pause it while a share sheet is up (the player VC owns it).
    private weak var activePlayer: AVPlayer?
    private var items: [SavedMediaItem] = []
    private var archivedItems: [SavedMediaItem] = []
    /// Saves whose ingestion FAILED. They carry no kind (the classifier never
    /// got one), so the surface gate keeps them and every app shows them — this
    /// app included: a Downloader link that broke belongs on the Downloader's
    /// screen, not silently in the shared store. They sit after the media cards
    /// as error cards, and vanish from here the moment a rescue gives them a
    /// kind (media resolves into `items`; anything else surfaces in its own app).
    private var failedSaves: [ReadingListItem] = []
    /// What `deckPreparedSnapshot` computed, waiting for the host to say the
    /// reload is going ahead.
    private var preparedItems: [SavedMediaItem] = []
    private var preparedArchivedItems: [SavedMediaItem] = []
    private var preparedFailedSaves: [ReadingListItem] = []
    /// In-flight progress of jobs whose row is ARCHIVED, keyed by item id. An
    /// archived row has no carousel card to draw its bar in — tapping an
    /// unavailable archive cell re-downloads in place — so its tray cell carries
    /// the bar instead. Live rows need no equivalent map: their own card content
    /// controller observes the same notification directly.
    private var archiveDownloadProgress: [UUID: Double] = [:]
    private var isReconcilingPhotos = false
    /// One concrete export for the centered item. Photos-backed videos can be
    /// large, so superseded exports are cancelled and reclaimed immediately.
    private var sharePreparationItemID: UUID?
    private var preparedShareFile: URL?
    private var sharePreparationTask: Task<URL?, Never>?
    private var sharePreparationGeneration = UUID()

    override var deckProvider: CardDeckProviding? { self }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        // Handed to the carousel as chrome, so it fades away with the scrub
        // strip and side cards when a reader takes over the screen.
        carousel.chromeBackdrop = StarfieldView.install(behindContentsOf: view)

        var style = CardCarouselStyle()
        style.pageSwipeMovementMultiplier = 1.5
        style.autoplaysScrubPreviewContent = true
        // Keep the strip inside the inner edges of the 44pt footer buttons.
        // A bounded strip needs no blur veil (which reads as a dark band on
        // black backgrounds).
        style.scrubberHorizontalInset = 64
        style.scrubberEdgeFadeWidth = 0
        style.showsCardBorder = true
        style.showsPlaybackScrubProgress = true
        carousel.style = style
        mountDeck()
    }

    /// The tray's own in-cell bars, refreshed alongside its rows.
    override func deckDidApplyReload() {
        archiveTray?.setDownloadProgress(archiveDownloadProgress)
    }

    // MARK: - Slots

    private func mediaItem(forSlot slot: Int) -> SavedMediaItem? {
        items.indices.contains(slot) ? items[slot] : nil
    }

    /// Failed-save cards occupy the slots after the media ones.
    private func failedSave(forSlot slot: Int) -> ReadingListItem? {
        let index = slot - items.count
        return failedSaves.indices.contains(index) ? failedSaves[index] : nil
    }

    var screenScale: CGFloat { view.window?.screen.scale ?? UIScreen.main.scale }

    // MARK: - Store

    /// Keeps the archive tray's in-cell bars current. Posted on the main queue by
    /// `postDownloaderJobProgress`, so this only ever runs there. Live (unarchived)
    /// rows are handled by their own card, not here.
    @objc private func handleJobProgressChanged(_ notification: Notification) {
        guard let urlString = notification.userInfo?["sourceURLString"] as? String,
              let id = archivedItems.first(where: { $0.sourceURLString == urlString })?.id
        else { return }
        let snapshot = notification.userInfo?["snapshot"] as? DownloaderJobSnapshot
        if let snapshot, snapshot.phase != .finished, snapshot.phase != .failed {
            archiveDownloadProgress[id] = snapshot.progress
        } else {
            archiveDownloadProgress[id] = nil
        }
        archiveTray?.setDownloadProgress(archiveDownloadProgress)
    }

    // MARK: - Opening an archived row

    private func openArchivedMedia(_ item: SavedMediaItem) {
        switch item.storageState {
        case .undownloaded:
            MediaItemActions.startManualDownload(item)
        case .localFile:
            guard let url = item.fileURL else {
                MediaItemActions.startManualDownload(item)
                return
            }
            if item.kind == .video || item.kind == .audio {
                presentPlayer(item: AVPlayerItem(url: url))
            } else {
                presentArchiveImage { completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        completion(UIImage(contentsOfFile: url.path))
                    }
                }
            }
        case .photosReference(let identifier, _, _):
            if item.kind == .video || item.kind == .audio {
                MediaCardFactory.loadPhotosVideoItem(identifier: identifier) { [weak self] playerItem in
                    DispatchQueue.main.async {
                        guard let playerItem else {
                            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                                self?.store.markArchivedPhotosAssetMissing(item.id)
                                MediaItemActions.startManualDownload(item)
                            } else {
                                self?.presentAlert(
                                    title: L10n.string("Photos Access Needed"),
                                    message: L10n.string("Allow Photos access to play this archived item."))
                            }
                            return
                        }
                        self?.presentPlayer(item: playerItem)
                    }
                }
            } else {
                presentArchiveImage { completion in
                    MediaCardFactory.loadPhotosImage(
                        identifier: identifier, targetSize: PHImageManagerMaximumSize,
                        completion: completion)
                }
            }
        }
    }

    private func presentPlayer(item: AVPlayerItem) {
        let controller = AVPlayerViewController()
        let player = AVPlayer(playerItem: item)
        controller.player = player
        activePlayer = player
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true) { controller.player?.play() }
    }

    private func presentArchiveImage(loader: @escaping (@escaping (UIImage?) -> Void) -> Void) {
        let controller = ArchivedImageViewController(loader: loader)
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    private func markOpened(_ item: SavedMediaItem) {
        if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
            ReadingListStore.shared.markReadState(.opened, for: saved.id)
        }
    }

    // MARK: - Sharing the file

    private func share(_ item: SavedMediaItem, sourceIndex: Int) {
        share(item, sourceView: carousel.cardView(at: sourceIndex) ?? trailingBottomButton)
    }

    private func share(_ item: SavedMediaItem, sourceView: UIView) {
        Task { @MainActor [weak self] in
            guard let self,
                  let fileURL = await self.prepareShareFile(for: item)
            else {
                self?.presentAlert(
                    title: L10n.string("Share Failed"), message: L10n.string("Couldn't prepare this media for sharing."))
                return
            }

            // A single concrete file URL is the entire payload. This lets the
            // system derive the movie preview and exposes normal file receivers
            // without attaching Luna metadata, text, or the source URL.
            let activity = UIActivityViewController(
                activityItems: [fileURL], applicationActivities: nil)
            activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
                Task { @MainActor in self?.discardPreparedShareFile(for: item.id) }
            }
            activity.popoverPresentationController?.sourceView = sourceView
            activity.popoverPresentationController?.sourceRect = sourceView.bounds
            // Don't let a playing video keep running (and talking) behind the
            // share sheet.
            self.activePlayer?.pause()
            self.present(activity, animated: true)
        }
    }

    private func prewarmShareFile(for item: SavedMediaItem) {
        if sharePreparationItemID != item.id { discardPreparedShareFile() }
        guard case .photosReference = item.storageState else { return }
        Task { @MainActor [weak self] in
            _ = await self?.prepareShareFile(for: item)
        }
    }

    private func prepareShareFile(for item: SavedMediaItem) async -> URL? {
        if sharePreparationItemID == item.id,
           let existing = preparedShareFile,
           FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        if sharePreparationItemID == item.id, let existingTask = sharePreparationTask {
            return await existingTask.value
        }

        discardPreparedShareFile()
        let generation = UUID()
        sharePreparationGeneration = generation
        sharePreparationItemID = item.id
        let task = Task<URL?, Never>.detached(priority: .userInitiated) {
            let fileURL = await MediaAutoDownloader.exportFile(from: item)?.fileURL
            if Task.isCancelled, let fileURL {
                MediaDownloadStorage.discardIntentExport(at: fileURL)
                return nil
            }
            return fileURL
        }
        sharePreparationTask = task
        let fileURL = await task.value
        guard sharePreparationGeneration == generation else {
            if let fileURL { MediaDownloadStorage.discardIntentExport(at: fileURL) }
            return nil
        }
        sharePreparationTask = nil
        preparedShareFile = fileURL
        return fileURL
    }

    private func discardPreparedShareFile(for itemID: UUID? = nil) {
        if let itemID, sharePreparationItemID != itemID { return }
        sharePreparationGeneration = UUID()
        sharePreparationTask?.cancel()
        sharePreparationTask = nil
        if let preparedShareFile {
            MediaDownloadStorage.discardIntentExport(at: preparedShareFile)
        }
        preparedShareFile = nil
        sharePreparationItemID = nil
    }

    // MARK: - Deleting

    private func presentAlert(title: String, message: String) {
        MediaItemActions.presentAlert(title: title, message: message, from: self)
    }

    private func deleteSavedItem(for item: SavedMediaItem) {
        MediaItemActions.release(
            item, saver: photoSaver, deletesReadingListItem: true,
            onPhotosDeletionFailure: { [weak self] in
                self?.presentAlert(
                    title: L10n.string("Photos Access Needed"),
                    message: L10n.string("Allow Photos access in Settings to delete this media from Photos."))
            })
    }

    /// A Photos identifier that no longer resolves is a deletion only when Luna
    /// has full read permission. Without permission, an empty fetch is not
    /// evidence of deletion.
    private func reconcilePhotosReferencesIfAuthorized() {
        guard !isReconcilingPhotos,
              (items + archivedItems).contains(where: { $0.photosLocalIdentifier != nil })
        else { return }
        isReconcilingPhotos = true
        Task { @MainActor in
            let authorized = await photoSaver.requestReadAuthorization()
            defer { isReconcilingPhotos = false }
            guard authorized,
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            else { return }
            let missing = (items + archivedItems).filter { item in
                guard let identifier = item.photosLocalIdentifier else { return false }
                return photoSaver.fetchAsset(localIdentifier: identifier) == nil
            }
            for item in missing {
                if item.isArchived {
                    store.markArchivedPhotosAssetMissing(item.id)
                } else {
                    deleteSavedItem(for: item)
                }
            }
        }
    }
}

// MARK: - The media kind

extension SavedMediaCardsViewController: CardDeckProviding {

    var deckChangeNotificationNames: [Notification.Name] { [.savedMediaChanged] }

    /// Darwin notifications are dropped while suspended, so also catch up on
    /// activation — which covers iPad multitasking, where the app can stay
    /// foregrounded the whole time an extension runs alongside it.
    var deckActivationNotificationNames: [Notification.Name] {
        [UIApplication.didBecomeActiveNotification]
    }

    func deckWillBeginObservingStores() {
        // Bridges saves/deletes made by the action/share extension (a DIFFERENT
        // process, so an in-process `.savedMediaChanged` post never reaches it)
        // back to a `.savedMediaChanged` post here via a Darwin notification.
        SavedMediaStore.startObservingCrossProcessChanges()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobProgressChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
    }

    func deckPreparedSnapshot() -> CardDeckSnapshot {
        store.purgeExpired()
        let allItems = store.items()
        preparedItems = SavedMediaCardOrdering.newestFirst(allItems.filter { !$0.isArchived })
        preparedArchivedItems = allItems.filter(\.isArchived).sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
        preparedFailedSaves = ReadingListStore.shared.items()
            .filter { ReadingListSectioning.isFailedSave($0) && !$0.isArchived }
            .sorted { ($0.bumpDate ?? $0.dateAdded) > ($1.bumpDate ?? $1.dateAdded) }
        // A media row is keyed by the MEDIA store's id, which the reading-list
        // item a save produced does not share — so the source URL travels with it
        // and the host can still center a just-saved link (see
        // `CardDeckSlot.urlString`).
        let mediaSlots = preparedItems.map { item in
            CardDeckSlot(
                id: item.id, urlString: item.sourceURLString,
                fingerprint: "active|\(item.id)|\(item.thumbnailFileName ?? "")"
                    + "|\(MediaItemActions.storageStateKey(item))")
        }
        let failedSlots = preparedFailedSaves.map { item in
            CardDeckSlot(
                id: item.id, urlString: item.urlString,
                fingerprint: "failed|\(item.id)|\(URLRescueCoordinator.shared.isRescuing(item.id))")
        }
        return CardDeckSnapshot(
            slots: mediaSlots + failedSlots,
            offstageIDs: Set(preparedArchivedItems.map(\.id)),
            offstageFingerprint: preparedArchivedItems.map { item in
                "archive|\(item.id)|\(item.thumbnailFileName ?? "")"
                    + "|\(MediaItemActions.storageStateKey(item))"
            })
    }

    func deckCommitPreparedSnapshot() {
        items = preparedItems
        archivedItems = preparedArchivedItems
        failedSaves = preparedFailedSaves
        // A row that left the archive (unarchived, or completed into a live card)
        // takes its tray bar with it.
        let archivedIDs = Set(archivedItems.map(\.id))
        archiveDownloadProgress = archiveDownloadProgress.filter { archivedIDs.contains($0.key) }
    }

    /// A reload that changed nothing is exactly when a Photos asset deleted
    /// behind Luna's back needs noticing, so this runs on that path too.
    func deckDidSettleReload() {
        reconcilePhotosReferencesIfAuthorized()
    }

    func deckContentController(forSlot slot: Int) -> CardContentViewController {
        if let failed = failedSave(forSlot: slot) {
            return FailedSaveCardFactory.makeCard(
                for: failed, host: self, onChanged: { [weak self] in self?.reload() })
        }
        guard let item = mediaItem(forSlot: slot) else { return CardContentViewController() }
        return MediaCardFactory.makeCard(
            for: item, scale: screenScale,
            download: { MediaItemActions.startManualDownload(item) },
            rescue: MediaCardRescue.starter(forSourceURLString: item.sourceURLString))
    }

    func deckLoadThumbnail(forSlot slot: Int, completion: @escaping (UIImage?) -> Void) {
        if failedSave(forSlot: slot) != nil {
            completion(UIImage(systemName: "exclamationmark.triangle"))
            return
        }
        guard let item = mediaItem(forSlot: slot) else {
            completion(nil)
            return
        }
        MediaCardFactory.loadThumbnail(for: item, scale: screenScale, completion: completion)
    }

    /// Media cards title themselves; only a failed save needs the deck to say
    /// what it is.
    func deckTitle(forSlot slot: Int) -> String? {
        failedSave(forSlot: slot).map(FailedSaveCardFactory.displayTitle(for:))
    }

    /// Two kinds of broken wear the red rim: a failed SAVE, and a media item
    /// whose DOWNLOAD failed. The second was missing, so the two failures looked
    /// nothing alike despite sitting in the same deck.
    func deckEdgeGlowColor(forSlot slot: Int) -> UIColor? {
        if failedSave(forSlot: slot) != nil { return LunaColors.errorAccent }
        guard let item = mediaItem(forSlot: slot),
              LiveMediaDownloadManager.shared.currentDownloadSnapshot(
                forSourceURLString: item.sourceURLString)?.phase == .failed
        else { return nil }
        return LunaColors.errorAccent
    }

    func deckTopLeadingAccessory(forSlot slot: Int) -> UIView? {
        mediaItem(forSlot: slot).flatMap(MediaCardFactory.photosBadge(for:))
    }

    func deckSlotDidCenter(_ slot: Int) {
        guard let item = mediaItem(forSlot: slot) else {
            discardPreparedShareFile()
            return
        }
        markOpened(item)
        prewarmShareFile(for: item)
    }

    func deckUtilCardDidCenter() {
        discardPreparedShareFile()
    }

    func deckMenu(forSlot slot: Int) -> UIMenu? {
        if let failed = failedSave(forSlot: slot) {
            return FailedSaveCardFactory.makeMenu(
                shareLink: { [weak self] in
                    guard let self else { return }
                    SendToFriendSheet.shareLink(
                        urlString: failed.urlString, from: self, sourceView: self.view)
                },
                delete: UIAction(
                    title: L10n.string("Delete"), image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    ReadingListStore.shared.delete(failed)
                    self?.reload()
                })
        }
        guard let item = mediaItem(forSlot: slot) else { return nil }
        let carouselIndex = carouselIndex(forSlot: slot)
        var actions = MediaItemActions.menuActions(
            for: item,
            download: { MediaItemActions.startManualDownload(item) },
            share: { [weak self] in self?.share(item, sourceIndex: carouselIndex) },
            saveToPhotos: { [weak self] in
                guard let self else { return }
                MediaItemActions.saveToPhotos(item, saver: self.photoSaver, from: self)
            })
        actions.append(WeeklyPromotionMenu.action(
            kind: .media, urlString: item.sourceURLString, title: item.title,
            presenter: self))
        actions.append(UIAction(
            title: L10n.string("Archive"), image: UIImage(systemName: "archivebox")
        ) { [weak self] _ in self?.store.setArchived(true, for: item.id) })
        actions.append(UIAction(
            title: L10n.string("Delete"), image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in self?.deleteSavedItem(for: item) })
        return UIMenu(children: actions)
    }

    func deckArchiveTrayItems() -> [ArchiveTrayItem] {
        archivedItems.map { item in
            let available: Bool
            switch item.storageState {
            case .localFile, .photosReference: available = true
            case .undownloaded: available = false
            }
            return ArchiveTrayItem(
                id: item.id, title: nil, footer: nil, showsMetadata: false,
                isAvailable: available,
                loadImage: { [weak self] completion in
                    guard let self else {
                        completion(nil)
                        return
                    }
                    MediaCardFactory.loadThumbnail(
                        for: item, scale: self.screenScale, completion: completion)
                },
                tap: { [weak self] in self?.openArchivedMedia(item) },
                share: { [weak self] sourceView in
                    self?.share(item, sourceView: sourceView)
                },
                unarchive: { [weak self] _ in
                    self?.store.setArchived(false, for: item.id)
                },
                delete: { [weak self] in self?.deleteSavedItem(for: item) })
        }
    }

    var deckShareButton: CardDeckShareButton? {
        CardDeckShareButton(
            accessibilityLabel: L10n.string("Share Current Media"),
            unavailability: .hides)
    }

    /// There is nothing to hand the system until the file is actually here.
    func deckCanShare(slot: Int?) -> Bool {
        guard let slot, let item = mediaItem(forSlot: slot) else { return false }
        switch item.storageState {
        case .localFile, .photosReference: return true
        case .undownloaded: return false
        }
    }

    func deckShare(slot: Int, sourceView: UIView) {
        guard let item = mediaItem(forSlot: slot) else { return }
        share(item, sourceView: sourceView)
    }
}

private final class ArchivedImageViewController: UIViewController {
    private let loader: (@escaping (UIImage?) -> Void) -> Void

    init(loader: @escaping (@escaping (UIImage?) -> Void) -> Void) {
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        let close = UIButton(type: .close)
        close.tintColor = .white
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
        ])
        loader { image in DispatchQueue.main.async { imageView.image = image } }
    }

    @objc private func closeTapped() { dismiss(animated: true) }
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
    private let rescue: (() -> Void)?
    private let button = UIButton(configuration: .plain())
    private let rescueButton = UIButton(configuration: .plain())
    private let poster = UIImageView()
    private let posterDim = UIView()
    private let statusLabel = UILabel()
    private let percentLabel = UILabel()
    private let progress = MoonHorizonProgressBar()
    /// The embedded bar: a glass slab inside the card's bottom edge, reading
    /// status on the leading side and percent-complete on the trailing side,
    /// with the horizon bar spanning beneath them.
    private let statusBar = UIVisualEffectView(effect: GlassStyle.barEffect())
    private var loadedThumbnailFileName: String?

    init(item: SavedMediaItem, download: @escaping () -> Void, rescue: (() -> Void)? = nil) {
        self.sourceURLString = item.sourceURLString
        self.download = download
        self.rescue = rescue
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
        button.accessibilityLabel = L10n.string("Download media")
        button.addAction(UIAction { [weak self] _ in self?.download() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        // "Retry with AI ✦" — shown only on a no-media failure when a model is
        // available. Styled by the one shared definition
        // (`GlassStyle.retryWithAIConfiguration`) so this card's offer is visibly
        // the SAME offer as the failed-save card's, which it wasn't when it read
        // "Try Apple Intelligence" over a `wand.and.stars`.
        rescueButton.configuration = GlassStyle.retryWithAIConfiguration(compact: true)
        rescueButton.isHidden = true
        rescueButton.addAction(UIAction { [weak self] _ in
            self?.rescueButton.isHidden = true
            self?.statusLabel.text = L10n.string("Trying harder with Apple Intelligence…")
            self?.rescue?()
        }, for: .touchUpInside)
        rescueButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rescueButton)

        statusLabel.text = L10n.string("Downloading")
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
            rescueButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            rescueButton.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -16),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobProgressChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
        apply(LiveMediaDownloadManager.shared.currentDownloadSnapshot(
            forSourceURLString: sourceURLString))
    }

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
            rescueButton.isHidden = true
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
        // Offer the AI rescue only on a genuine no-media failure, when installed.
        rescueButton.isHidden = !(snapshot.phase == .failed
            && snapshot.failureKind == .noMedia && rescue != nil)

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
