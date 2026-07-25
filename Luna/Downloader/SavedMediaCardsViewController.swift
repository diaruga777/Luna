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

    private enum PasteboardCardState {
        case placeholder(changeCount: Int)
        case invalid(changeCount: Int)
        case downloading(
            changeCount: Int, url: URL, title: String, progress: Double)
        case ready(
            changeCount: Int, url: URL, title: String,
            media: DownloadedMedia, expiresAt: Date)

        var changeCount: Int {
            switch self {
            case .placeholder(let count), .invalid(let count),
                 .downloading(let count, _, _, _), .ready(let count, _, _, _, _):
                return count
            }
        }

        var fingerprint: String {
            switch self {
            case .placeholder(let count): return "placeholder|\(count)"
            case .invalid(let count): return "invalid|\(count)"
            case .downloading(let count, let url, _, _):
                return "downloading|\(count)|\(url.absoluteString)"
            case .ready(let count, let url, _, let media, _):
                return "ready|\(count)|\(url.absoluteString)|\(media.fileURL.path)"
            }
        }

        var temporaryMedia: DownloadedMedia? {
            guard case .ready(_, _, _, let media, _) = self else { return nil }
            return media
        }
    }

    private let store = SavedMediaStore.shared
    private let photoSaver = PhotoLibrarySaver()
    private let emptyView = CardCarouselHostViewController.makeEmptyStateView(
        symbol: "photo.on.rectangle.angled", title: "No Saved Media",
        subtitle: "Saved Downloader links appear here after Luna downloads the media.")
    private let settingsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    /// The player behind the currently-presented full-screen video, held weakly
    /// so we can pause it while a share sheet is up (the player VC owns it).
    private weak var activePlayer: AVPlayer?
    private var items: [SavedMediaItem] = []
    private var archivedItems: [SavedMediaItem] = []
    /// In-flight progress of jobs whose row is ARCHIVED, keyed by item id. An
    /// archived row has no carousel card to draw its bar in — tapping an
    /// unavailable archive cell re-downloads in place — so its tray cell carries
    /// the bar instead. Live rows need no equivalent map: their own card content
    /// controller observes the same notification directly.
    private var archiveDownloadProgress: [UUID: Double] = [:]
    /// Saves whose ingestion FAILED. They carry no kind (the classifier never
    /// got one), so the surface gate keeps them and every app shows them — this
    /// app included: a Downloader link that broke belongs on the Downloader's
    /// screen, not silently in the shared store. They sit after the media cards
    /// as error cards, and vanish from here the moment a rescue gives them a
    /// kind (media resolves into `items`; anything else surfaces in its own app).
    private var failedSaves: [ReadingListItem] = []
    private var isReconcilingPhotos = false
    private var pasteboardState: PasteboardCardState?
    private var renderedPasteboardState: PasteboardCardState?
    private var consumedPasteboardChangeCount: Int?
    private var pendingPasteboardDownloadURLString: String?
    private var pasteboardDownloadTask: Task<Void, Never>?
    private var pasteboardExpiryWorkItem: DispatchWorkItem?
    private var isCommittingPasteboardMedia = false
    /// One concrete export for the centered item. Photos-backed videos can be
    /// large, so superseded exports are cancelled and reclaimed immediately.
    private var sharePreparationItemID: UUID?
    private var preparedShareFile: URL?
    private var sharePreparationTask: Task<URL?, Never>?
    private var sharePreparationGeneration = UUID()
    /// Fingerprint of the last-applied item list, so store notifications that
    /// changed nothing visible (frequent on foreground/activation catch-ups)
    /// don't tear down and rebuild live card content mid-playback.
    private var appliedFingerprint: [String] = []

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
        carousel.dataSource = self
        carousel.delegate = self
        mountCarousel()

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        mountBottomControls()
        mountArchiveTray(
            shifting: { [weak self] in
                guard let self else { return [] }
                return [self.carousel.view, self.emptyView]
            },
            canPull: { [weak self] in
                guard let self else { return false }
                let count = self.items.count + self.cardOffset
                return count == 0 || self.carousel.currentIndex == count - 1
            },
            openStateChanged: { [weak self] open in
                self?.carousel.setMuteButtonOccluded(open)
            })

        // Bridges saves/deletes made by the action/share extension (a DIFFERENT
        // process, so the in-process .savedMediaChanged post below never reaches
        // it) back to a .savedMediaChanged post here via a Darwin notification.
        SavedMediaStore.startObservingCrossProcessChanges()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .savedMediaChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationForegrounded),
            name: UIApplication.willEnterForegroundNotification,
            object: nil)
        // Darwin notifications are dropped while suspended, so also catch up on
        // activation (covers iPad multitasking, where the app can stay
        // foregrounded the whole time an extension runs alongside it).
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationForegrounded), name: UIApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPasteboardURL),
            name: UIPasteboard.changedNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobProgressChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
        reload()
        refreshPasteboardURL()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        applyCarouselTopInset(4)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyCarouselTopInset(4)
    }

    /// Matches Reader's outer chrome: the scrubber runs edge-to-edge beneath
    /// two persistent Liquid Glass circles.
    private func mountBottomControls() {
        configureBottomButton(
            settingsButton, symbol: "gearshape", action: #selector(settingsTapped),
            accessibilityLabel: "Settings")
        configureBottomButton(
            shareButton, symbol: "square.and.arrow.up", action: #selector(shareCurrentTapped),
            accessibilityLabel: "Share Current Media")
        mountBottomControls(leading: settingsButton, trailing: shareButton)
    }

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

    @objc private func applicationForegrounded() {
        store.purgeExpired()
        expireTemporaryPasteboardMediaIfNeeded()
        reload()
        refreshPasteboardURL()
    }

    @objc private func reload() {
        store.purgeExpired()
        let allItems = store.items()
        var updated = SavedMediaCardOrdering.newestFirst(
            allItems.filter { !$0.isArchived })
        if isCommittingPasteboardMedia,
           case .ready(_, let url, _, _, _) = renderedPasteboardState {
            updated.removeAll { $0.sourceURLString == url.absoluteString }
        }
        let updatedArchive = allItems.filter(\.isArchived).sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
        let updatedFailed = ReadingListStore.shared.items()
            .filter { ReadingListSectioning.isFailedSave($0) && !$0.isArchived }
            .sorted { ($0.bumpDate ?? $0.dateAdded) > ($1.bumpDate ?? $1.dateAdded) }
        var fingerprint = updated.map { item in
            "active|\(item.id)|\(item.thumbnailFileName ?? "")|\(storageStateKey(item))"
        }
        fingerprint.append(contentsOf: updatedArchive.map { item in
            "archive|\(item.id)|\(item.thumbnailFileName ?? "")|\(storageStateKey(item))"
        })
        fingerprint.append(contentsOf: updatedFailed.map { item in
            "failed|\(item.id)|\(URLRescueCoordinator.shared.isRescuing(item.id))"
        })
        fingerprint.insert("paste|\(pasteboardState?.fingerprint ?? "")", at: 0)
        defer { reconcilePhotosReferencesIfAuthorized() }
        guard fingerprint != appliedFingerprint else { return }
        appliedFingerprint = fingerprint

        let wasPasteboardCentered = renderedPasteboardState != nil && carousel.currentIndex == 0
        let oldItemIndex = carousel.currentIndex - cardOffset
        let centeredID = items.indices.contains(oldItemIndex) ? items[oldItemIndex].id : nil
        items = updated
        archivedItems = updatedArchive
        failedSaves = updatedFailed
        // A row that left the archive (unarchived, or completed into a live card)
        // takes its tray bar with it.
        let archivedIDs = Set(archivedItems.map(\.id))
        archiveDownloadProgress = archiveDownloadProgress.filter { archivedIDs.contains($0.key) }
        renderedPasteboardState = pasteboardState
        let pendingIndex = pendingPasteboardDownloadURLString.flatMap { pending in
            items.firstIndex { $0.sourceURLString == pending }
        }
        let centeredIndex = wasPasteboardCentered && renderedPasteboardState != nil ? 0 : centeredID.flatMap { id in
            items.firstIndex { $0.id == id }.map { $0 + cardOffset }
        } ?? pendingIndex.map { $0 + cardOffset }
            ?? (items.isEmpty ? 0 : cardOffset)
        if pendingIndex != nil { pendingPasteboardDownloadURLString = nil }
        carousel.reloadData(centeringAt: centeredIndex)
        let hasAnyCard = !items.isEmpty || !failedSaves.isEmpty
        emptyView.isHidden = hasAnyCard || renderedPasteboardState != nil
        carousel.view.isHidden = !hasAnyCard && renderedPasteboardState == nil
        archiveTray?.setItems(makeArchiveTrayItems())
        archiveTray?.setDownloadProgress(archiveDownloadProgress)
        refreshArchivePullAvailability(animated: false)
        updateShareButton()
    }

    private func makeArchiveTrayItems() -> [ArchiveTrayItem] {
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
                    self?.loadThumbnail(for: item, completion: completion)
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

    private func openArchivedMedia(_ item: SavedMediaItem) {
        switch item.storageState {
        case .undownloaded:
            startDownload(item)
        case .localFile:
            guard let url = item.fileURL else { startDownload(item); return }
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
                                self?.startDownload(item)
                            } else {
                                self?.presentAlert(
                                    title: "Photos Access Needed",
                                    message: "Allow Photos access to play this archived item.")
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

    private func storageStateKey(_ item: SavedMediaItem) -> String {
        switch item.storageState {
        case .undownloaded: return "undownloaded"
        case .localFile: return "local|\(item.fileName ?? "")"
        case .photosReference(let identifier, _, _): return "photos|\(identifier)"
        }
    }

    private func markOpened(_ item: SavedMediaItem) {
        if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
            ReadingListStore.shared.markReadState(.opened, for: saved.id)
        }
    }

    override var hasLeadingPasteboardCard: Bool { renderedPasteboardState != nil }

    private func mediaIndex(forCarouselIndex index: Int) -> Int? {
        itemIndex(forCarouselIndex: index, itemCount: items.count)
    }

    /// Failed-save cards occupy the slots after the media cards, so one shared
    /// offset keeps both index maps honest.
    private func failedIndex(forCarouselIndex index: Int) -> Int? {
        let failedIndex = index - cardOffset - items.count
        return (0..<failedSaves.count).contains(failedIndex) ? failedIndex : nil
    }

    private func failedSave(atCarouselIndex index: Int) -> ReadingListItem? {
        failedIndex(forCarouselIndex: index).map { failedSaves[$0] }
    }

    private func currentMediaItem() -> (item: SavedMediaItem, carouselIndex: Int)? {
        let index = carousel.currentIndex
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else { return nil }
        return (items[mediaIndex], index)
    }

    private func updateShareButton() {
        guard let current = currentMediaItem() else {
            shareButton.isHidden = true
            return
        }
        switch current.item.storageState {
        case .localFile, .photosReference:
            shareButton.isHidden = false
        case .undownloaded:
            shareButton.isHidden = true
        }
    }

    // MARK: - Outer controls + pasteboard

    @objc private func shareCurrentTapped() {
        guard let current = currentMediaItem() else { return }
        share(current.item, sourceIndex: current.carouselIndex)
    }

    @objc private func refreshPasteboardURL() {
        let pasteboard = UIPasteboard.general
        if consumedPasteboardChangeCount == pasteboard.changeCount {
            clearPasteboardCard(removingTemporaryFile: true)
            return
        }
        guard pasteboardState?.changeCount != pasteboard.changeCount else { return }
        pasteboardDownloadTask?.cancel()
        clearPasteboardCard(removingTemporaryFile: true)
        let changeCount = pasteboard.changeCount
        // Privacy-preserving pre-validation only. The URL value is not read
        // until the user reaches this synthetic leading card.
        pasteboard.detectPatterns(for: [\.probableWebURL]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, UIPasteboard.general.changeCount == changeCount else { return }
                let hasLink = (try? result.get())?.contains(\.probableWebURL) == true
                self.pasteboardState = hasLink ? .placeholder(changeCount: changeCount) : nil
                self.reload()
            }
        }
    }

    /// The value the card's `UIPasteControl` handed over — an implicitly
    /// authorized read, so nothing here touches `UIPasteboard` for content.
    private func handlePastedValue(_ value: String) {
        guard case .placeholder(let expectedChangeCount) = renderedPasteboardState else { return }
        guard UIPasteboard.general.changeCount == expectedChangeCount,
              let url = URLUnwrapper.ingestURL(from: value, allowBareHost: true),
              MediaDownloadablePlatform.supports(url.absoluteString),
              store.matchingItem(forURLString: url.absoluteString) == nil
        else {
            pasteboardState = .invalid(changeCount: expectedChangeCount)
            reload()
            return
        }

        let title = PlatformRecognizer.recognize(url.absoluteString)?.platform.displayName
            ?? url.host ?? "Pasted Media"
        pasteboardState = .downloading(
            changeCount: expectedChangeCount, url: url, title: title, progress: 0)
        reload()
        pasteboardDownloadTask?.cancel()
        pasteboardDownloadTask = Task { [weak self] in
            do {
                let media = try await MediaDownloadService().downloadFirstMediaToFile(
                    from: url,
                    onProgress: { progress in
                        DispatchQueue.main.async { [weak self] in
                            guard let self,
                                  case .downloading(let count, let currentURL, let currentTitle, _) = self.pasteboardState,
                                  count == expectedChangeCount, currentURL == url
                            else { return }
                            self.pasteboardState = .downloading(
                                changeCount: count, url: currentURL,
                                title: currentTitle, progress: progress)
                            (self.carousel.contentController(at: 0)
                                as? PasteboardMediaDownloadCardContentViewController)?
                                .setProgress(progress)
                        }
                    })
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: media.fileURL)
                    return
                }
                await MainActor.run {
                    guard let self,
                          case .downloading(let count, let currentURL, let currentTitle, _) = self.pasteboardState,
                          count == expectedChangeCount, currentURL == url,
                          UIPasteboard.general.changeCount == expectedChangeCount
                    else {
                        try? FileManager.default.removeItem(at: media.fileURL)
                        return
                    }
                    let expiry = Date().addingTimeInterval(PasteboardTemporaryMediaPolicy.lifetime)
                    self.pasteboardState = .ready(
                        changeCount: count, url: currentURL, title: currentTitle,
                        media: media, expiresAt: expiry)
                    self.reload()
                    self.schedulePasteboardExpiry(at: expiry)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.pasteboardState?.changeCount == expectedChangeCount
                    else { return }
                    self.pasteboardState = .invalid(changeCount: expectedChangeCount)
                    self.reload()
                }
            }
        }
    }

    private func commitTemporaryPasteboardMedia() {
        guard !isCommittingPasteboardMedia,
              case .ready(let changeCount, let url, let title, let media, _) = renderedPasteboardState
        else { return }
        isCommittingPasteboardMedia = true
        Task { [weak self] in
            guard let self else { return }
            let persistentCopy = MediaDownloadStorage.newFileURL(
                extension: media.fileURL.pathExtension)
            do {
                try FileManager.default.copyItem(at: media.fileURL, to: persistentCopy)
            } catch {
                await MainActor.run {
                    self.isCommittingPasteboardMedia = false
                    self.presentAlert(title: "Save Failed", message: "Couldn't keep the pasted media.")
                }
                return
            }

            let saved: SavedMediaItem
            do {
                saved = try self.store.addDownloadedFile(
                    persistentCopy, kind: media.kind,
                    sourceURLString: url.absoluteString, title: title)
            } catch {
                try? FileManager.default.removeItem(at: persistentCopy)
                await MainActor.run {
                    self.isCommittingPasteboardMedia = false
                    self.presentAlert(title: "Save Failed", message: "Couldn't keep the pasted media.")
                }
                return
            }

            var photosFailure = false
            if media.kind.canSaveToPhotos,
               await self.photoSaver.requestReadAuthorization() {
                do {
                    let identifier = try await self.photoSaver.save(
                        fileURL: media.fileURL, kind: media.kind, shouldMoveFile: false)
                    _ = try self.store.transitionToPhotosReference(
                        saved.id, localIdentifier: identifier, kind: media.kind)
                } catch {
                    photosFailure = true
                }
            } else if media.kind.canSaveToPhotos {
                photosFailure = true
            }
            AutoDownloadSettings.markDownloaded(url.absoluteString)
            _ = await ReadingListIngestor.shared.handleSavePress(
                urlString: url.absoluteString, source: .paste)

            await MainActor.run {
                self.isCommittingPasteboardMedia = false
                self.pendingPasteboardDownloadURLString = url.absoluteString
                self.consumedPasteboardChangeCount = changeCount
                let pasteboardChanged = UIPasteboard.general.changeCount != changeCount
                if PasteboardCommitPolicy.shouldClearCommittedCard(
                    committedChangeCount: changeCount,
                    currentPasteboardChangeCount: UIPasteboard.general.changeCount,
                    representedChangeCount: self.pasteboardState?.changeCount
                ) {
                    self.clearPasteboardCard(removingTemporaryFile: true)
                } else {
                    // A newer paste arrived while Photos/storage work was in
                    // flight. Keep its synthetic card and only fold the saved
                    // media row into the current carousel snapshot.
                    self.reload()
                }
                if pasteboardChanged { self.refreshPasteboardURL() }
                if photosFailure {
                    self.presentAlert(
                        title: "Photos Access Needed",
                        message: "The media was saved in Luna. Allow photo library access in Settings to also save it to Photos.")
                }
            }
        }
    }

    private func clearPasteboardCard(removingTemporaryFile: Bool) {
        pasteboardExpiryWorkItem?.cancel()
        pasteboardExpiryWorkItem = nil
        if removingTemporaryFile {
            let urls = [pasteboardState?.temporaryMedia?.fileURL,
                        renderedPasteboardState?.temporaryMedia?.fileURL]
            for url in Set(urls.compactMap { $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        pasteboardState = nil
        reload()
    }

    private func schedulePasteboardExpiry(at date: Date) {
        pasteboardExpiryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.expireTemporaryPasteboardMediaIfNeeded()
        }
        pasteboardExpiryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, date.timeIntervalSinceNow), execute: work)
    }

    private func expireTemporaryPasteboardMediaIfNeeded(now: Date = Date()) {
        guard case .ready(let count, _, _, _, let expiry) = pasteboardState,
              PasteboardTemporaryMediaPolicy.isExpired(expiresAt: expiry, now: now)
        else { return }
        consumedPasteboardChangeCount = count
        clearPasteboardCard(removingTemporaryFile: true)
    }

    // MARK: - Item actions (context menu)

    private func share(_ item: SavedMediaItem, sourceIndex: Int) {
        let sourceView = carousel.cardView(at: sourceIndex) ?? shareButton
        share(item, sourceView: sourceView)
    }

    private func share(_ item: SavedMediaItem, sourceView: UIView) {
        Task { @MainActor [weak self] in
            guard let self,
                  let fileURL = await self.prepareShareFile(for: item)
            else {
                self?.presentAlert(
                    title: "Share Failed", message: "Couldn't prepare this media for sharing.")
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

    /// Saves a defensive COPY of the item's local file to Photos (never the file
    /// itself) — moving the original would risk losing the carousel's own copy
    /// if the Photos save fails or is slow.
    private func saveToPhotos(_ item: SavedMediaItem) {
        Task { @MainActor in
            do {
                guard case .localFile = item.storageState,
                      let fileURL = item.fileURL,
                      let kind = item.kind
                else { return }
                guard await photoSaver.requestReadAuthorization() else {
                    presentAlert(
                        title: "Photos Access Needed",
                        message: "Allow photo library access in Settings to save media.")
                    return
                }
                let tempURL = MediaDownloadStorage.newFileURL(extension: fileURL.pathExtension)
                try FileManager.default.copyItem(at: fileURL, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await SavedMediaPhotosSync.saveAndTransition(
                    itemID: item.id, fileURL: tempURL, kind: kind, shouldMoveFile: true,
                    saver: photoSaver, store: store)
                presentAlert(title: "Saved to Photos", message: "The media was added to your photo library.")
            } catch {
                presentAlert(title: "Save Failed", message: "Couldn't save this media to Photos.")
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func deleteSavedItem(for item: SavedMediaItem) {
        Task { @MainActor [weak self] in
            do {
                if let localIdentifier = item.photosLocalIdentifier, let self {
                    try await SavedMediaPhotosSync.deletePhotosAssetIfPresent(
                        localIdentifier, saver: self.photoSaver)
                }
                guard let self else { return }
                AutoDownloadSettings.unmarkDownloaded(item.sourceURLString)
                if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
                    ReadingListStore.shared.delete(saved)
                }
                self.store.delete(item)
            } catch {
                self?.presentAlert(
                    title: "Photos Access Needed",
                    message: "Allow Photos access in Settings to delete this media from Photos.")
            }
        }
    }

    private func startDownload(_ item: SavedMediaItem) {
        Task {
            // An explicit "download this exact item now" gesture — bypasses the
            // Wi-Fi-only setting (unlike the opportunistic resume sweep).
            _ = await LiveMediaDownloadManager.shared.start(
                urlString: item.sourceURLString, title: item.title, manual: true)
        }
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

// MARK: - Carousel data source

extension SavedMediaCardsViewController: CardCarouselDataSource {

    func numberOfCards(in carousel: CardCarouselViewController) -> Int {
        items.count + failedSaves.count + cardOffset
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        if let state = renderedPasteboardState, index == 0 {
            switch state {
            case .placeholder:
                return PasteboardPlaceholderCardContentViewController(
                    title: "Paste Link",
                    detail: "Paste the copied link to preview it here.",
                    onPaste: { [weak self] value in self?.handlePastedValue(value) })
            case .invalid:
                return InvalidPasteCardContentViewController()
            case .downloading(_, let url, let title, let progress):
                return PasteboardMediaDownloadCardContentViewController(
                    url: url, title: title, progress: progress)
            case .ready(_, _, _, let media, _):
                return TemporaryPasteboardMediaCardContentViewController(
                    media: media,
                    onFirstPlay: { [weak self] in self?.commitTemporaryPasteboardMedia() })
            }
        }
        if let failed = failedSave(atCarouselIndex: index) {
            return FailedSaveCardFactory.makeCard(
                for: failed, host: self, onChanged: { [weak self] in self?.reload() })
        }
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else {
            return CardContentViewController()
        }
        let item = items[mediaIndex]
        return MediaCardFactory.makeCard(
            for: item, scale: screenScale,
            download: { [weak self] in self?.startDownload(item) },
            rescue: MediaCardRescue.starter(forSourceURLString: item.sourceURLString))
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        previewContentControllerForCardAt index: Int
    ) -> CardContentViewController? {
        self.carousel(carousel, contentControllerForCardAt: index)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        if let state = renderedPasteboardState, index == 0 {
            switch state {
            case .placeholder, .downloading:
                completion(UIImage(systemName: "doc.on.clipboard"))
            case .invalid:
                completion(UIImage(systemName: "exclamationmark.circle"))
            case .ready(_, _, _, let media, _):
                MediaCardFactory.loadTemporaryThumbnail(for: media, completion: completion)
            }
            return
        }
        if failedSave(atCarouselIndex: index) != nil {
            completion(UIImage(systemName: "exclamationmark.triangle"))
            return
        }
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else {
            completion(nil)
            return
        }
        loadThumbnail(for: items[mediaIndex], completion: completion)
    }

    /// A failed save's card carries a soft red rim — the only card chrome that
    /// says "this one is broken" without a badge or a banner.
    func carousel(
        _ carousel: CardCarouselViewController, edgeGlowColorForCardAt index: Int
    ) -> UIColor? {
        failedSave(atCarouselIndex: index) != nil ? LunaColors.errorAccent : nil
    }

    func carousel(
        _ carousel: CardCarouselViewController, titleForCardAt index: Int
    ) -> String? {
        failedSave(atCarouselIndex: index).map { FailedSaveCardFactory.makeModel(for: $0).title }
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView? {
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else { return nil }
        return MediaCardFactory.photosBadge(for: items[mediaIndex])
    }

    private func loadThumbnail(for item: SavedMediaItem, completion: @escaping (UIImage?) -> Void) {
        MediaCardFactory.loadThumbnail(for: item, scale: screenScale, completion: completion)
    }

    var screenScale: CGFloat { view.window?.screen.scale ?? UIScreen.main.scale }
}

// MARK: - Carousel delegate

extension SavedMediaCardsViewController: CardCarouselDelegate {

    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int
    ) {
        updateArchivePullAvailability(
            forTargetIndex: index,
            cardCount: items.count + failedSaves.count + cardOffset,
            animated: true)
    }

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        refreshArchivePullAvailability(animated: true)
        updateShareButton()
        if renderedPasteboardState != nil, index == 0 {
            // Nothing reads the pasteboard on arrival — the card's paste control
            // is the only way in, and its tap IS the authorization.
            discardPreparedShareFile()
            return
        }
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else {
            discardPreparedShareFile()
            return
        }
        let item = items[mediaIndex]
        markOpened(item)
        prewarmShareFile(for: item)
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        guard let state = renderedPasteboardState, index == 0 else { return }
        switch state {
        case .placeholder:
            break // The card's paste control owns this interaction.
        case .ready(_, _, _, let media, _):
            // Still images are non-playable, so their card tap arrives here.
            // Video/GIF taps go through `setPlaying(true)` on the temporary
            // content controller and commit from there.
            if media.kind == .image { commitTemporaryPasteboardMedia() }
        case .invalid, .downloading:
            break
        }
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        menuForCardAt index: Int
    ) -> UIMenu? {
        // A failed save has nothing to download, nothing to put in Photos, and
        // no reason to be archived — sharing the link and deleting it are the
        // only honest verbs.
        if let failed = failedSave(atCarouselIndex: index) {
            return UIMenu(children: [
                UIAction(title: "Share Link…", image: UIImage(systemName: "square.and.arrow.up")) {
                    [weak self] _ in
                    guard let self else { return }
                    SendToFriendSheet.shareLink(
                        urlString: failed.urlString, from: self, sourceView: self.view)
                },
                UIAction(
                    title: "Delete", image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    ReadingListStore.shared.delete(failed)
                    self?.reload()
                },
            ])
        }
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else { return nil }
        let item = items[mediaIndex]
        var actions: [UIMenuElement] = []
        switch item.storageState {
        case .undownloaded:
            actions.append(UIAction(
                title: "Download", image: UIImage(systemName: "arrow.down.circle")
            ) { [weak self] _ in self?.startDownload(item) })
        case .localFile:
            actions.append(UIAction(
                title: "Share", image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.share(item, sourceIndex: index) })
            if item.kind?.canSaveToPhotos == true {
                actions.append(UIAction(
                    title: "Save to Photos", image: UIImage(systemName: "photo.badge.plus")
                ) { [weak self] _ in self?.saveToPhotos(item) })
            }
        case .photosReference:
            actions.append(UIAction(
                title: "Share", image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.share(item, sourceIndex: index) })
        }
        actions.append(UIAction(
            title: "Archive", image: UIImage(systemName: "archivebox")
        ) { [weak self] _ in self?.store.setArchived(true, for: item.id) })
        actions.append(UIAction(
            title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
        ) { [weak self] _ in self?.deleteSavedItem(for: item) })
        return UIMenu(children: actions)
    }
}

// MARK: - Pasteboard card

/// The user-triggered paste read succeeded and its media is being staged in a
/// one-hour temporary file. The paste icon remains in the scrubber until this
/// progress card is replaced by the real, paused media card.
private final class PasteboardMediaDownloadCardContentViewController: CardContentViewController {
    private let url: URL
    private let titleText: String
    private let initialProgress: Double
    private let statusLabel = UILabel()
    private let progress = MoonHorizonProgressBar()

    init(url: URL, title: String, progress: Double) {
        self.url = url
        self.titleText = title
        self.initialProgress = progress
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        let icon = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
        icon.tintColor = GlassStyle.readingAccent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42, weight: .medium)

        let title = UILabel()
        title.text = titleText
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = LunaColors.primaryText
        title.textAlignment = .center

        let urlLabel = UILabel()
        urlLabel.text = url.absoluteString
        urlLabel.font = .preferredFont(forTextStyle: .subheadline)
        urlLabel.textColor = LunaColors.secondaryText
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 4
        urlLabel.lineBreakMode = .byTruncatingMiddle

        statusLabel.text = "Downloading temporary preview…"
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = LunaColors.secondaryText
        statusLabel.textAlignment = .center
        progress.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            icon, title, urlLabel, statusLabel, progress,
        ])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 20),
        ])
        setProgress(initialProgress)
    }

    func setProgress(_ value: Double) {
        guard isViewLoaded else { return }
        progress.setProgress(Float(value), animated: true)
    }
}

/// A fully downloaded but unsaved pasteboard card. It deliberately suppresses
/// the carousel's normal center-autoplay. The first explicit play tap commits
/// the file to Luna and Photos; still images commit through the host's normal
/// non-playable card-tap callback.
final class TemporaryPasteboardMediaCardContentViewController: CardContentViewController {
    private let content: CardContentViewController
    private let onFirstPlay: () -> Void
    private var didRequestCommit = false

    init(media: DownloadedMedia, onFirstPlay: @escaping () -> Void) {
        switch media.kind {
        case .video:
            self.content = VideoCardContentViewController(fileURL: media.fileURL)
        case .audio:
            let content = VideoCardContentViewController(fileURL: media.fileURL)
            content.setPosterImage(UIImage(systemName: "waveform.circle.fill"))
            self.content = content
        case .gif:
            self.content = AnimatedImageCardContentViewController(fileURL: media.fileURL)
        case .image:
            self.content = ImageCardContentViewController(loader: { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    let raw = UIImage(contentsOfFile: media.fileURL.path)
                    completion(raw?.preparingForDisplay() ?? raw)
                }
            })
        }
        self.onFirstPlay = onFirstPlay
        super.init()
        content.audioAvailabilityChanged = { [weak self] in
            self?.audioAvailabilityChanged?()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override var isPlayable: Bool { content.isPlayable }
    override var supportsAudio: Bool { content.supportsAudio }
    override var isPlaying: Bool { content.isPlaying }
    override var playbackFraction: Double { content.playbackFraction }
    override var showsPlaybackScrubProgress: Bool { content.showsPlaybackScrubProgress }

    override func setPlaying(_ playing: Bool) {
        if playing, !didRequestCommit {
            didRequestCommit = true
            onFirstPlay()
        }
        content.setPlaying(playing)
    }

    override func seek(toFraction fraction: Double) {
        content.seek(toFraction: fraction)
    }

    override func setMuted(_ muted: Bool) {
        content.setMuted(muted)
    }

    override func allowsCardTap(at point: CGPoint) -> Bool {
        content.allowsCardTap(at: point)
    }

    override func cardDidBecomeCentered() {
        // Unlike durable media cards, a temporary paste always starts paused.
        content.setPlaying(false)
    }

    override func cardDidLeaveCenter() {
        content.cardDidLeaveCenter()
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
        button.accessibilityLabel = "Download media"
        button.addAction(UIAction { [weak self] _ in self?.download() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        // "Try Apple Intelligence" — shown only on a no-media failure when a model
        // is available. Runs a one-shot URL rescue with the media hint.
        var rescueConfig = UIButton.Configuration.tinted()
        rescueConfig.image = UIImage(systemName: "wand.and.stars")
        rescueConfig.title = "Try Apple Intelligence"
        rescueConfig.imagePadding = 6
        rescueConfig.cornerStyle = .capsule
        rescueButton.configuration = rescueConfig
        rescueButton.isHidden = true
        rescueButton.addAction(UIAction { [weak self] _ in
            self?.rescueButton.isHidden = true
            self?.statusLabel.text = "Asking Apple Intelligence…"
            self?.rescue?()
        }, for: .touchUpInside)
        rescueButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rescueButton)

        statusLabel.text = "Downloading"
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
