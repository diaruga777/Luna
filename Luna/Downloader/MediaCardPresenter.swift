//
//  MediaCardPresenter.swift
//  Luna
//
//  The media kind's card behavior, defined ONCE for every app that shows a
//  Downloader save — the Downloader itself and the central Luna app. Compiled
//  into exactly those two targets (Reader and Price Tracker exclude it through
//  the synchronized group's membership exceptions, the same mechanism that keeps
//  `MediaCardFactory` out of them).
//
//  Before this existed, the Downloader's deck and the central app's all-kinds
//  deck each answered these questions separately and disagreed about: the
//  failed-download red rim (Downloader only), which store an archive wrote,
//  whether deleting an archived save released its file, the display scale, the
//  fingerprint's components, share prewarming, and the Photos reconciliation
//  pass. Every one of those was the same save behaving differently depending on
//  which icon you tapped.
//
//  The verbs themselves, and the storage work behind two of them, stay where
//  they already were: `MediaItemActions` in `MediaCardFactory.swift`. This file
//  is the presenter that hands them to a deck.
//

import AVFoundation
import AVKit
import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaReadingListUI
import LunaSocialUI
import LunaStorage
import Photos
import UIKit

@MainActor
final class MediaCardPresenter: CardKindPresenting {

    private let store = SavedMediaStore.shared
    private let photoSaver = PhotoLibrarySaver()

    /// The player behind the currently-presented fullscreen video, held weakly
    /// so it can be paused while a share sheet is up (the player VC owns it).
    private weak var activePlayer: AVPlayer?
    /// Keeps the fullscreen player's speed choices flowing back into the shared
    /// per-item memory for as long as that player exists.
    private var playerSpeedObservation: NSKeyValueObservation?

    /// One concrete export for the centered item. Photos-backed videos can be
    /// large, so superseded exports are cancelled and reclaimed immediately.
    /// This used to exist only in the Downloader; the central app re-exported
    /// from cold on every share.
    private var sharePreparationItemID: UUID?
    private var preparedShareFile: URL?
    private var sharePreparationTask: Task<URL?, Never>?
    private var sharePreparationGeneration = UUID()

    /// In-flight progress of jobs whose row is ARCHIVED, keyed by media id. An
    /// archived row has no carousel card to draw its bar in — tapping an
    /// unavailable archive cell re-downloads in place — so its tray cell carries
    /// the bar instead. Live rows need no equivalent: their own card content
    /// observes the same notification directly.
    private(set) var archiveDownloadProgress: [UUID: Double] = [:]
    private weak var progressHost: (any CardPresenterHost)?
    private var isReconcilingPhotos = false
    private var backgroundObserver: NSObjectProtocol?

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    /// The downloaded media behind a save, if Luna holds any.
    ///
    /// There is no `contentPlatform` guard: the registry has already routed this
    /// item to the media presenter, and a stand-in item for an UNBACKED media row
    /// (see `unbackedItems`) carries no platform to guard on. A URL with a media
    /// row IS media.
    private func media(for item: SavedItem) -> SavedMediaItem? {
        store.item(forURLString: item.urlString)
    }

    /// Media Luna holds that the saves list has no row for. See the protocol's
    /// `unbackedItems` for why these exist and why dropping them would delete
    /// real user downloads from the deck.
    func unbackedItems() -> [SavedItem] {
        let saves = SavesStore.shared.items()
        let backed = Set(saves.map(\.urlString))
        return store.items()
            .filter { !backed.contains($0.sourceURLString) }
            .map { media in
                // The stand-in carries the MEDIA store's id, so the slot, the
                // centering ladder and the archive tray all key off the row the
                // user actually has — exactly as the Downloader's deck always
                // did — while everything else reads a normal item.
                var item = SavedItem(urlString: media.sourceURLString, id: media.id)
                item.title = media.title
                item.dateAdded = media.dateSaved
                item.bumpDate = media.dateSaved
                item.platform = media.platform
                item.state = .ready
                return item
            }
    }

    // MARK: - Slot data

    /// The media half of a card's identity: which still it shows and where its
    /// file is. Both decks now carry both components — the central app's omitted
    /// the thumbnail, so a download that produced a poster left the card showing
    /// the old one until something else forced a rebuild.
    func fingerprint(for item: SavedItem) -> String {
        guard let media = media(for: item) else { return "" }
        return "\(media.thumbnailFileName ?? "")|\(MediaItemActions.storageStateKey(media))"
    }

    /// A platform link Luna holds no media row for has no media card to draw.
    /// The central app and Reader still show it as a link card; the Downloader,
    /// which has no link card, gives it no slot — exactly as it did when it read
    /// its own store instead of the saves list.
    func hasContent(for item: SavedItem) -> Bool {
        media(for: item) != nil
    }

    /// Archived in EITHER store means archived. The two used to be written
    /// separately — the Downloader archived the media row, the central deck
    /// archived the save row — so a save archived in one app stayed live
    /// in the other. `setArchived` now writes both; reading leniently is what
    /// reconciles the rows written before it did.
    func isArchived(_ item: SavedItem) -> Bool {
        item.isArchived || media(for: item)?.isArchived == true
    }

    var changeNotificationNames: [Notification.Name] { [.savedMediaChanged] }

    /// Darwin notifications are dropped while suspended, so also catch up on
    /// activation — which covers iPad multitasking, where the app can stay
    /// foregrounded the whole time an extension runs alongside it. The central
    /// app had no equivalent, so a download finished by an extension beside it
    /// went unnoticed there.
    var activationNotificationNames: [Notification.Name] {
        [UIApplication.didBecomeActiveNotification]
    }

    func willBeginObservingStores(host: CardPresenterHost) {
        progressHost = host
        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // AVPlayerViewController's player otherwise keeps its playback
                // session when a download completion backgrounds the app.
                // `queue: .main` is what makes the assumption hold.
                MainActor.assumeIsolated { self?.activePlayer?.pause() }
            }
        }
        // Bridges saves/deletes made by the action/share extension (a DIFFERENT
        // process, so an in-process `.savedMediaChanged` post never reaches it)
        // back to a `.savedMediaChanged` post here via a Darwin notification.
        SavedMediaStore.startObservingCrossProcessChanges()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobProgressChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
    }

    /// Expired rows go before a snapshot reads them, not after. A row that has
    /// left the archive takes its tray bar with it.
    func prepareSnapshotSideEffects() {
        store.purgeExpired()
        let archived = Set(store.items().filter(\.isArchived).map(slotID(for:)))
        archiveDownloadProgress = archiveDownloadProgress.filter { archived.contains($0.key) }
    }

    /// The id the DECK knows a media row by: its save row's when it has
    /// one, its own when it does not (see `unbackedItems`). The archive tray's
    /// cells are keyed by the slot, so its download bars must be too.
    private func slotID(for media: SavedMediaItem) -> UUID {
        SavesStore.shared.item(forURLString: media.sourceURLString)?.id ?? media.id
    }

    /// A reload that changed NOTHING is exactly when a Photos asset deleted
    /// behind Luna's back needs noticing, which is why this runs on the settle
    /// path rather than the apply path. It used to run only from the Downloader.
    func didSettleReload(host: CardPresenterHost) {
        reconcilePhotosReferencesIfAuthorized(host: host)
    }

    // MARK: - The card

    func cardContent(for item: SavedItem, host: CardPresenterHost)
        -> CardContentViewController?
    {
        guard let media = media(for: item), !media.isArchived else { return nil }
        return MediaCardFactory.makeCard(
            for: media,
            scale: host.displayScale,
            download: { MediaItemActions.startManualDownload(media) },
            rescue: MediaCardRescue.starter(forSourceURLString: media.sourceURLString))
    }

    func topLeadingAccessory(for item: SavedItem) -> UIView? {
        media(for: item).flatMap(MediaCardFactory.photosBadge(for:))
    }

    /// A media item whose DOWNLOAD failed wears the same soft red rim a failed
    /// SAVE does. The central app drew no rim at all, so the two failures looked
    /// nothing alike in the one deck that shows both.
    func edgeGlowColor(for item: SavedItem) -> UIColor? {
        guard let media = media(for: item),
              LiveMediaDownloadManager.shared.currentDownloadSnapshot(
                forSourceURLString: media.sourceURLString)?.phase == .failed
        else { return nil }
        return LunaColors.errorAccent
    }

    // MARK: - Strip and scrub preview

    /// A platform save is identified by its platform, not by its host's favicon.
    func loadSourceBadge(
        for item: SavedItem, completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        guard let platform = item.contentPlatform else {
            completion(nil)
            return
        }
        if let asset = platform.logoAssetName, let logo = UIImage(named: asset) {
            completion(.icon(logo))
            return
        }
        guard let glyph = PlatformRegistry.shared.module(for: platform)?.glyphSymbolName
        else {
            completion(nil)
            return
        }
        completion(.symbol(glyph))
    }

    func loadThumbnail(
        for item: SavedItem, host: CardPresenterHost,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let media = media(for: item) else {
            completion(nil)
            return
        }
        MediaCardFactory.loadThumbnail(
            for: media, scale: host.displayScale, completion: completion)
    }

    /// A media save's card is a picture, so its strip chip is that picture too.
    /// An unarchived save with no still yet falls back to a badge chip.
    func prefersThumbnailChip(for item: SavedItem) -> Bool {
        guard let media = media(for: item) else { return false }
        return !media.isArchived
    }

    /// Hard-clipped, and played by the scrub strip under the finger — in EVERY
    /// app. The central app used to dissolve this card's video edges over the
    /// reader's 28pt fade and preview it as a still. Its 9:16 frame is now the
    /// whole deck's frame rather than this kind's answer: video is what that
    /// shape was chosen FOR, and every other card matches it.
    ///
    /// `pagesOnInCardSwipes` stays false: a playable card's whole width is a
    /// timeline, so a horizontal drag scrubs it. That was already true of a
    /// PLAYING card everywhere (the carousel vetoes paging for playable
    /// content), but a DOWNLOADING card is not playable yet, and it paged in
    /// the central app while staying put in the Downloader.
    func cardStyle(for item: SavedItem) -> CardCarouselCardStyle {
        var style = CardCarouselCardStyle()
        style.autoplaysScrubPreview = true
        return style
    }

    /// Only media cards are expensive to build — each one is an AVPlayer, and
    /// the mini-card strip prepares its whole visible window at once.
    func allowsPreparedPreviewContent(for item: SavedItem) -> Bool {
        media(for: item) == nil
    }

    // MARK: - Verbs

    /// The Downloader's own verbs for this row — the same switch over where its
    /// file is — offered above the deck's Archive/Delete.
    func menuActions(for item: SavedItem, host: CardPresenterHost) -> [UIMenuElement] {
        guard let media = media(for: item) else { return [] }
        let anchor = host.cardView(forItemID: item.id)
        return MediaItemActions.menuActions(
            for: media,
            download: { MediaItemActions.startManualDownload(media) },
            share: { [weak self, weak host] in
                guard let self, let host else { return }
                self.share(media, from: host, sourceView: anchor)
            },
            saveToPhotos: { [weak self, weak host] in
                guard let self, let host else { return }
                MediaItemActions.saveToPhotos(
                    media, saver: self.photoSaver, from: host.presentingController)
            })
    }

    /// The ladder the deck's trailing circle hangs on this row: Copy link /
    /// Share link over the original saved URL, then the file itself once one
    /// exists. A platform save with NO media row still owes the user its link —
    /// that card IS a link and nothing else — so it gets the two link verbs
    /// alone, and only the file row ever shares a file (a video Luna holds just
    /// a thumbnail for shares its link, never the thumbnail).
    ///
    /// Two ways to be this kind's, and it takes EITHER: a recognized platform,
    /// or a media row Luna actually holds. A plain article is neither and gets
    /// nil, which is what keeps its pill hidden. The second half matters because
    /// an UNBACKED media row's stand-in carries whatever platform its media row
    /// recorded, and that is nil for a row saved before platform capture — a
    /// `contentPlatform`-only test cost those cards their entire share ladder.
    func shareMenu(for item: SavedItem, host: CardPresenterHost, sourceView: UIView)
        -> UIMenu?
    {
        guard let media = media(for: item) else {
            guard item.contentPlatform != nil else { return nil }
            return MediaItemActions.linkShareMenu(
                urlString: item.urlString, presenter: host.presentingController,
                sourceView: sourceView)
        }
        return MediaItemActions.shareMenu(
            for: media, presenter: host.presentingController, sourceView: sourceView,
            shareFile: { [weak self, weak host, weak sourceView] in
                guard let self, let host else { return }
                self.share(media, from: host, sourceView: sourceView)
            })
    }

    /// ONE archive write for this kind, covering BOTH stores the kind owns. The
    /// Downloader used to archive only its media row and the central deck only
    /// the save row, so archiving in one app left the save live (or
    /// demoted to a link card) in the other.
    /// Unarchiving also bumps the row's date, which is how the ONE ordering rule
    /// resurfaces a restored save — the same thing `markUnread` does for an
    /// article. It is the only date this kind ever writes.
    func setArchived(_ archived: Bool, for item: SavedItem) {
        if let media = media(for: item) {
            store.setArchived(archived, for: media.id)
        }
        SavesStore.shared.setArchived(archived, for: item.id)
        if !archived { SavesStore.shared.bump(item.id) }
    }

    /// The whole save goes when the card does: the downloaded file, its Photos
    /// asset, and the auto-download bookkeeping that would otherwise treat the
    /// URL as already fetched. The save row itself is the deck's to
    /// delete. This ran only from the ACTIVE deck centrally, so deleting an
    /// archived media save from the tray left every one of those behind.
    func deleteCompanionStorage(for item: SavedItem, host: CardPresenterHost?) {
        guard let media = store.item(forURLString: item.urlString) else { return }
        MediaItemActions.release(
            media, saver: photoSaver, deletesSavedItem: false,
            onPhotosDeletionFailure: { [weak host] in
                guard let host else { return }
                MediaItemActions.presentAlert(
                    title: L10n.string("Downloader_mediaCard_photosAccess_title"),
                    message: L10n.string(
                        "Downloader_mediaCard_photosAccess_deleteMessage"),
                    from: host.presentingController)
            })
    }

    // MARK: - Lifecycle

    func itemDidCenter(_ item: SavedItem, host: CardPresenterHost) {
        SavesStore.shared.markReadState(.opened, for: item.id)
        guard let media = media(for: item) else {
            discardPreparedShareFile()
            return
        }
        prewarmShareFile(for: media)
    }

    func utilCardDidCenter() {
        discardPreparedShareFile()
    }

    /// A media save rendered as a REAL card owns its own tap (play/pause, the
    /// download button), exactly as in the Downloader. The native-app → embed →
    /// in-app-browser ladder is only for the link-style card that stands in when
    /// there is nothing downloaded to show.
    @discardableResult
    func itemWasTapped(
        _ item: SavedItem, cardContent: CardContentViewController?,
        host: CardPresenterHost
    ) -> Bool {
        guard media(for: item) == nil else { return true }
        return openExternally(item, host: host)
    }

    /// The platform open ladder: the real app if it is installed, then the
    /// platform's own embed, then the in-app browser.
    @discardableResult
    func openExternally(_ item: SavedItem, host: CardPresenterHost) -> Bool {
        let presenter = host.presentingController
        guard let platform = item.contentPlatform,
              let module = PlatformRegistry.shared.module(for: platform)
        else {
            InAppBrowser.present(urlString: item.urlString, from: presenter)
            return true
        }
        if let appURL = module.appDeepLink(for: item), UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL) { success in
                if success { SavesStore.shared.markReadState(.read, for: item.id) }
            }
            return true
        }
        if let embed = module.embed(for: item) {
            presenter.present(
                PlatformEmbedViewController(embed: embed, itemID: item.id), animated: true)
            return true
        }
        InAppBrowser.present(urlString: item.urlString, from: presenter)
        return true
    }

    // MARK: - The archive tray

    /// The real media row in the tray — its thumbnail, whether the file is still
    /// there, and a tap that plays it fullscreen. The central app's tray showed
    /// a globe and a favicon fetch for these, and its tap went nowhere (it asked
    /// for a reader, and there is no reader for a video).
    func archiveTrayItem(for item: SavedItem, host: CardPresenterHost)
        -> ArchiveTrayItem?
    {
        guard let media = store.item(forURLString: item.urlString) else { return nil }
        let available: Bool
        switch media.storageState {
        case .localFile, .photosReference: available = true
        case .undownloaded: available = false
        }
        return ArchiveTrayItem(
            id: item.id, title: nil, footer: nil, showsMetadata: false,
            isAvailable: available,
            loadImage: { [weak host] completion in
                guard let host else {
                    completion(nil)
                    return
                }
                MediaCardFactory.loadThumbnail(
                    for: media, scale: host.displayScale, completion: completion)
            },
            tap: { [weak self, weak host] in
                guard let self, let host else { return }
                self.openArchivedMedia(media, host: host)
            },
            share: { [weak self, weak host] sourceView in
                guard let self, let host else { return }
                self.share(media, from: host, sourceView: sourceView)
            },
            unarchive: { [weak self] _ in self?.setArchived(false, for: item) },
            delete: { [weak self, weak host] in
                guard let self else { return }
                self.deleteCompanionStorage(for: item, host: host)
                SavesStore.shared.delete(item)
            })
    }

    // MARK: - Fullscreen playback

    private func openArchivedMedia(_ item: SavedMediaItem, host: CardPresenterHost) {
        switch item.storageState {
        case .undownloaded:
            MediaItemActions.startManualDownload(item)
        case .localFile:
            guard let url = item.fileURL else {
                MediaItemActions.startManualDownload(item)
                return
            }
            if item.kind == .video || item.kind == .audio {
                presentPlayer(
                    item: AVPlayerItem(url: url),
                    speedMemoryKey: MediaCardFactory.speedMemoryKey(for: item),
                    host: host)
            } else {
                presentArchiveImage(host: host) { completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        completion(UIImage(contentsOfFile: url.path))
                    }
                }
            }
        case .photosReference(let identifier, _, _):
            if item.kind == .video || item.kind == .audio {
                MediaCardFactory.loadPhotosVideoItem(identifier: identifier) {
                    [weak self, weak host] playerItem in
                    DispatchQueue.main.async {
                        guard let self, let host else { return }
                        guard let playerItem else {
                            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                                SavedMediaStore.shared.markArchivedPhotosAssetMissing(item.id)
                                MediaItemActions.startManualDownload(item)
                            } else {
                                MediaItemActions.presentAlert(
                                    title: L10n.string("Downloader_mediaCard_photosAccess_title"),
                                    message: L10n.string(
                                        "Downloader_mediaCard_photosAccess_playMessage"),
                                    from: host.presentingController)
                            }
                            return
                        }
                        self.presentPlayer(
                            item: playerItem,
                            speedMemoryKey: MediaCardFactory.speedMemoryKey(for: item),
                            host: host)
                    }
                }
            } else {
                presentArchiveImage(host: host) { completion in
                    MediaCardFactory.loadPhotosImage(
                        identifier: identifier, targetSize: PHImageManagerMaximumSize,
                        completion: completion)
                }
            }
        }
    }

    /// Fullscreen playback keeps the SYSTEM player and so the system's own speed
    /// menu — Luna draws no second control over it. What it does share is the
    /// memory: the row opens at the speed the card was left at, the menu offers
    /// Luna's own five speeds, and a change made here goes back to the card.
    private func presentPlayer(
        item: AVPlayerItem, speedMemoryKey: String, host: CardPresenterHost
    ) {
        let controller = AVPlayerViewController()
        let player = AVPlayer(playerItem: item)
        item.audioTimePitchAlgorithm = .spectral
        player.defaultRate = Float(PlaybackSpeedMemory.shared.speed(forKey: speedMemoryKey))
        controller.speeds = PlaybackSpeed.options.map {
            AVPlaybackSpeed(rate: Float($0), localizedName: PlaybackSpeed.label(for: $0))
        }
        controller.player = player
        activePlayer = player
        // Picking a speed in the system menu sets the player's default rate;
        // KVO can arrive off the main thread, and the memory is main-only.
        playerSpeedObservation = player.observe(\.defaultRate) { player, _ in
            let rate = Double(player.defaultRate)
            DispatchQueue.main.async {
                PlaybackSpeedMemory.shared.setSpeed(rate, forKey: speedMemoryKey)
            }
        }
        controller.modalPresentationStyle = .fullScreen
        host.presentingController.present(controller, animated: true) {
            controller.player?.play()
        }
    }

    private func presentArchiveImage(
        host: CardPresenterHost,
        loader: @escaping (@escaping (UIImage?) -> Void) -> Void
    ) {
        let controller = ArchivedImageViewController(loader: loader)
        controller.modalPresentationStyle = .fullScreen
        host.presentingController.present(controller, animated: true)
    }

    // MARK: - Sharing

    /// A single concrete file URL is the whole payload — the system derives the
    /// preview and no Luna metadata rides along. `sourceView` is nil when the
    /// caller's own anchor view is gone (the card scrolled away, a weakly-held
    /// view already deallocated); the share sheet then anchors to the deck itself.
    private func share(
        _ media: SavedMediaItem, from host: CardPresenterHost, sourceView: UIView?
    ) {
        Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            guard let fileURL = await self.prepareShareFile(for: media) else {
                MediaItemActions.presentAlert(
                    title: L10n.string("Downloader_mediaCard_shareFailedAlert_title"),
                    message: L10n.string("Downloader_mediaCard_shareFailedAlert_message"),
                    from: host.presentingController)
                return
            }
            // Don't let a playing video keep running (and talking) behind the
            // share sheet.
            self.activePlayer?.pause()
            LunaShareSheet.present(
                items: [fileURL], from: host.presentingController,
                anchor: sourceView.map(LunaShareSheetAnchor.viewBounds),
                completion: { [weak self] _, _, _, _ in
                    Task { @MainActor in self?.discardPreparedShareFile(for: media.id) }
                })
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

    // MARK: - Archive-tray download bars

    /// Keeps the archive tray's in-cell bars current. Posted on the main queue
    /// by `postDownloaderJobProgress`, so this only ever runs there. Live rows
    /// are handled by their own card, not here.
    @objc private func handleJobProgressChanged(_ notification: Notification) {
        guard let urlString = notification.userInfo?["sourceURLString"] as? String,
              let media = store.items().first(
                where: { $0.sourceURLString == urlString && $0.isArchived })
        else { return }
        let snapshot = notification.userInfo?["snapshot"] as? DownloaderJobSnapshot
        let id = slotID(for: media)
        if let snapshot, snapshot.phase != .finished, snapshot.phase != .failed {
            archiveDownloadProgress[id] = snapshot.progress
        } else {
            archiveDownloadProgress[id] = nil
        }
        progressHost?.archiveDownloadProgressDidChange()
    }

    // MARK: - Photos

    /// A Photos identifier that no longer resolves is a deletion only when Luna
    /// has full read permission. Without permission, an empty fetch is not
    /// evidence of deletion.
    private func reconcilePhotosReferencesIfAuthorized(host: CardPresenterHost) {
        let all = store.items()
        guard !isReconcilingPhotos,
              all.contains(where: { $0.photosLocalIdentifier != nil })
        else { return }
        isReconcilingPhotos = true
        Task { @MainActor [weak self, weak host] in
            guard let self else { return }
            let authorized = await self.photoSaver.requestReadAuthorization()
            defer { self.isReconcilingPhotos = false }
            guard authorized,
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            else { return }
            let missing = all.filter { item in
                guard let identifier = item.photosLocalIdentifier else { return false }
                return self.photoSaver.fetchAsset(localIdentifier: identifier) == nil
            }
            for media in missing {
                if media.isArchived {
                    self.store.markArchivedPhotosAssetMissing(media.id)
                } else {
                    MediaItemActions.release(
                        media, saver: self.photoSaver, deletesSavedItem: true,
                        onPhotosDeletionFailure: { [weak host] in
                            guard let host else { return }
                            MediaItemActions.presentAlert(
                                title: L10n.string("Downloader_mediaCard_photosAccess_title"),
                                message: L10n.string(
                                    "Downloader_mediaCard_photosAccess_deleteMessage"),
                                from: host.presentingController)
                        })
                }
            }
        }
    }
}

// MARK: - Fullscreen archived image

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
