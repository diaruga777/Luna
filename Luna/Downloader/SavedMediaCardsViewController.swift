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
//  reconciliation, context-menu actions, and the download-progress footer.
//

import AVFoundation
import AVKit
import LunaDesignSystem
import LunaMediaDownload
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import LunaURLClassification
import Photos
import UIKit

final class SavedMediaCardsViewController: CardCarouselHostViewController {

    private enum PasteboardCardState {
        case placeholder(changeCount: Int)
        case invalid(changeCount: Int, showsSettingsGuidance: Bool)
        case downloading(
            changeCount: Int, url: URL, title: String, progress: Double)
        case ready(
            changeCount: Int, url: URL, title: String,
            media: DownloadedMedia, expiresAt: Date)

        var changeCount: Int {
            switch self {
            case .placeholder(let count), .invalid(let count, _),
                 .downloading(let count, _, _, _), .ready(let count, _, _, _, _):
                return count
            }
        }

        var fingerprint: String {
            switch self {
            case .placeholder(let count): return "placeholder|\(count)"
            case .invalid(let count, let guidance): return "invalid|\(count)|\(guidance)"
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
    private let downloadFooter = DownloaderProgressFooterView()
    private let emptyView = CardCarouselHostViewController.makeEmptyStateView(
        symbol: "photo.on.rectangle.angled", title: "No Saved Media",
        subtitle: "Saved Downloader links appear here after Luna downloads the media.")
    private let settingsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private var items: [SavedMediaItem] = []
    private var archivedItems: [SavedMediaItem] = []
    private var isReconcilingPhotos = false
    private var pasteboardState: PasteboardCardState?
    private var renderedPasteboardState: PasteboardCardState?
    private var consumedPasteboardChangeCount: Int?
    private var pendingPasteboardDownloadURLString: String?
    private var pasteboardDownloadTask: Task<Void, Never>?
    private var pasteboardExpiryWorkItem: DispatchWorkItem?
    private var isCommittingPasteboardMedia = false
    /// Concrete exports keyed by item so the share sheet never receives a lazy
    /// provider and the current Photos-backed card can be warmed before a tap.
    private var preparedShareFiles: [UUID: URL] = [:]
    private var sharePreparationTasks: [UUID: Task<URL?, Never>] = [:]
    /// Fingerprint of the last-applied item list, so store notifications that
    /// changed nothing visible (frequent on foreground/activation catch-ups)
    /// don't tear down and rebuild live card content mid-playback.
    private var appliedFingerprint: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        var style = CardCarouselStyle()
        style.pageSwipeMovementMultiplier = 1.5
        style.autoplaysScrubPreviewContent = true
        // Keep the strip inside the inner edges of the 44pt footer buttons.
        // A bounded strip needs no blur veil (which reads as a dark band on
        // black backgrounds).
        style.scrubberHorizontalInset = 64
        style.scrubberEdgeFadeWidth = 0
        style.showsCardBorder = true
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
        mountDownloadFooter()
        mountArchiveTray(
            shifting: { [weak self] in
                guard let self else { return [] }
                return [self.carousel.view, self.emptyView]
            },
            canPull: { [weak self] in
                guard let self else { return false }
                let count = self.items.count + self.cardOffset
                return count == 0 || self.carousel.currentIndex == count - 1
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

    /// Floats the download-progress footer above the scrub strip, mirroring the
    /// Live Activity / action-extension download UI. It reveals itself only
    /// while a Downloader-owned job is running.
    private func mountDownloadFooter() {
        view.addSubview(downloadFooter)
        NSLayoutConstraint.activate([
            downloadFooter.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: 16),
            downloadFooter.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -16),
            downloadFooter.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -92),
        ])
    }

    // MARK: - Store

    @objc private func applicationForegrounded() {
        store.purgeExpired()
        expireTemporaryPasteboardMediaIfNeeded()
        reload()
        refreshPasteboardURL()
    }

    @objc private func reload() {
        store.purgeExpired()
        let allItems = store.items()
        var updated = allItems.filter { !$0.isArchived }
        if isCommittingPasteboardMedia,
           case .ready(_, let url, _, _, _) = renderedPasteboardState {
            updated.removeAll { $0.sourceURLString == url.absoluteString }
        }
        let updatedArchive = allItems.filter(\.isArchived).sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
        var fingerprint = updated.map { item in
            "active|\(item.id)|\(item.thumbnailFileName ?? "")|\(storageStateKey(item))"
        }
        fingerprint.append(contentsOf: updatedArchive.map { item in
            "archive|\(item.id)|\(item.thumbnailFileName ?? "")|\(storageStateKey(item))"
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
        emptyView.isHidden = !items.isEmpty || renderedPasteboardState != nil
        carousel.view.isHidden = items.isEmpty && renderedPasteboardState == nil
        archiveTray?.setItems(makeArchiveTrayItems())
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
                unarchive: { [weak self] in self?.store.setArchived(false, for: item.id) })
        }
    }

    private func openArchivedMedia(_ item: SavedMediaItem) {
        switch item.storageState {
        case .undownloaded:
            startDownload(item)
        case .localFile:
            guard let url = item.fileURL else { startDownload(item); return }
            if item.kind == .video {
                presentPlayer(item: AVPlayerItem(url: url))
            } else {
                presentArchiveImage { completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        completion(UIImage(contentsOfFile: url.path))
                    }
                }
            }
        case .photosReference(let identifier, _, _):
            if item.kind == .video {
                Self.loadPhotosVideoItem(identifier: identifier) { [weak self] playerItem in
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
                    Self.loadPhotosImage(
                        identifier: identifier, targetSize: PHImageManagerMaximumSize,
                        completion: completion)
                }
            }
        }
    }

    private func presentPlayer(item: AVPlayerItem) {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(playerItem: item)
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

    private func readPasteboardPlaceholder() {
        guard case .placeholder(let expectedChangeCount) = renderedPasteboardState else { return }
        let result = PasteboardReadTiming.readGeneralPasteboard()
        guard result.changeCount == expectedChangeCount,
              UIPasteboard.general.changeCount == expectedChangeCount,
              let value = result.value,
              let url = URLUnwrapper.ingestURL(from: value, allowBareHost: true),
              MediaDownloadablePlatform.supports(url.absoluteString),
              store.matchingItem(forURLString: url.absoluteString) == nil
        else {
            pasteboardState = .invalid(
                changeCount: expectedChangeCount,
                showsSettingsGuidance: result.likelyPresentedPermissionPrompt)
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
                    self.pasteboardState = .invalid(
                        changeCount: expectedChangeCount,
                        showsSettingsGuidance: result.likelyPresentedPermissionPrompt)
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
            if await self.photoSaver.requestReadAuthorization() {
                do {
                    let identifier = try await self.photoSaver.save(
                        fileURL: media.fileURL, kind: media.kind, shouldMoveFile: false)
                    _ = try self.store.transitionToPhotosReference(
                        saved.id, localIdentifier: identifier, kind: media.kind)
                } catch {
                    photosFailure = true
                }
            } else {
                photosFailure = true
            }
            AutoDownloadSettings.markDownloaded(url.absoluteString)
            _ = await ReadingListIngestor.shared.handleSavePress(
                urlString: url.absoluteString, source: .paste)

            await MainActor.run {
                self.isCommittingPasteboardMedia = false
                self.pendingPasteboardDownloadURLString = url.absoluteString
                self.consumedPasteboardChangeCount = changeCount
                self.clearPasteboardCard(removingTemporaryFile: true)
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
            if let card = self.carousel.cardView(at: sourceIndex) {
                activity.popoverPresentationController?.sourceView = card
                activity.popoverPresentationController?.sourceRect = card.bounds
            }
            self.present(activity, animated: true)
        }
    }

    private func prewarmShareFile(for item: SavedMediaItem) {
        guard case .photosReference = item.storageState else { return }
        Task { @MainActor [weak self] in
            _ = await self?.prepareShareFile(for: item)
        }
    }

    private func prepareShareFile(for item: SavedMediaItem) async -> URL? {
        if let existing = preparedShareFiles[item.id],
           FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        if let existingTask = sharePreparationTasks[item.id] {
            return await existingTask.value
        }

        let task = Task {
            await MediaAutoDownloader.exportFile(from: item)?.fileURL
        }
        sharePreparationTasks[item.id] = task
        let fileURL = await task.value
        sharePreparationTasks[item.id] = nil
        if let fileURL {
            preparedShareFiles[item.id] = fileURL
        }
        return fileURL
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
        items.count + cardOffset
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        if let state = renderedPasteboardState, index == 0 {
            switch state {
            case .placeholder:
                return PasteboardPlaceholderCardContentViewController(
                    title: "Paste Link", detail: "Swipe here to preview the pasted URL.")
            case .invalid(_, let guidance):
                return InvalidPasteCardContentViewController(showsSettingsGuidance: guidance)
            case .downloading(_, let url, let title, let progress):
                return PasteboardMediaDownloadCardContentViewController(
                    url: url, title: title, progress: progress)
            case .ready(_, _, _, let media, _):
                return TemporaryPasteboardMediaCardContentViewController(
                    media: media,
                    onFirstPlay: { [weak self] in self?.commitTemporaryPasteboardMedia() })
            }
        }
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else {
            return CardContentViewController()
        }
        let item = items[mediaIndex]
        switch item.storageState {
        case .undownloaded:
            return UndownloadedMediaCardContentViewController(item: item) { [weak self] in
                self?.startDownload(item)
            }
        case .localFile:
            guard let fileURL = item.fileURL else { return CardContentViewController() }
            switch item.kind {
            case .video:
                let content = VideoCardContentViewController(fileURL: fileURL)
                loadThumbnail(for: item) { [weak content] image in
                    DispatchQueue.main.async { content?.setPosterImage(image) }
                }
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
        case .photosReference(let identifier, _, _):
            if item.kind == .video {
                let content = VideoCardContentViewController(itemProvider: { completion in
                    Self.loadPhotosVideoItem(identifier: identifier, completion: completion)
                })
                loadThumbnail(for: item) { [weak content] image in
                    DispatchQueue.main.async { content?.setPosterImage(image) }
                }
                return content
            }
            return ImageCardContentViewController(loader: { completion in
                Self.loadPhotosImage(identifier: identifier, targetSize: PHImageManagerMaximumSize, completion: completion)
            })
        }
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
                Self.loadTemporaryThumbnail(for: media, completion: completion)
            }
            return
        }
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else {
            completion(nil)
            return
        }
        loadThumbnail(for: items[mediaIndex], completion: completion)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView? {
        guard let mediaIndex = mediaIndex(forCarouselIndex: index),
              let identifier = items[mediaIndex].photosLocalIdentifier
        else { return nil }
        return PhotosReferenceBadgeView { [weak self] in
            self?.openInPhotos(localIdentifier: identifier)
        }
    }

    private func openInPhotos(localIdentifier: String) {
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

    /// A mid-size decode shared by the scrub strip and its drag-preview overlay
    /// (which is card-sized, so thumbnails are decoded larger than the strip
    /// alone would need).
    private func loadThumbnail(for item: SavedMediaItem, completion: @escaping (UIImage?) -> Void) {
        if let url = item.thumbnailURL {
            DownsampledImageLoader.load(
                path: url.path,
                pointSize: CGSize(width: 300, height: 300),
                scale: view.window?.screen.scale ?? UIScreen.main.scale,
                isStale: { false }
            ) { image in
                completion(image)
            }
        } else if let identifier = item.photosLocalIdentifier {
            Self.loadPhotosImage(
                identifier: identifier,
                targetSize: CGSize(width: 600, height: 600),
                completion: completion)
        } else {
            completion(nil)
        }
    }

    private static func loadTemporaryThumbnail(
        for media: DownloadedMedia, completion: @escaping (UIImage?) -> Void
    ) {
        if media.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.fileURL))
            generator.appliesPreferredTrackTransform = true
            generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
                completion(image.map(UIImage.init))
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                completion(UIImage(contentsOfFile: media.fileURL.path))
            }
        }
    }

    private static func loadPhotosImage(
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

    private static func loadPhotosVideoItem(
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

// MARK: - Carousel delegate

extension SavedMediaCardsViewController: CardCarouselDelegate {

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        updateShareButton()
        if let state = renderedPasteboardState, index == 0 {
            if case .placeholder = state, !items.isEmpty {
                readPasteboardPlaceholder()
            }
            return
        }
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else { return }
        let item = items[mediaIndex]
        markOpened(item)
        prewarmShareFile(for: item)
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        guard let state = renderedPasteboardState, index == 0 else { return }
        switch state {
        case .placeholder:
            readPasteboardPlaceholder()
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
        contextMenuForCardAt index: Int
    ) -> UIContextMenuConfiguration? {
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else { return nil }
        let item = items[mediaIndex]
        return UIContextMenuConfiguration(actionProvider: { _ in
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
                actions.append(UIAction(
                    title: "Save to Photos", image: UIImage(systemName: "photo.badge.plus")
                ) { [weak self] _ in self?.saveToPhotos(item) })
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
        })
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

/// Card content for an item whose media hasn't been fetched yet: a large
/// download button, replaced by a progress ring while the Downloader-owned job
/// runs. Progress arrives via `.downloaderJobProgressChanged`, observed here
/// directly (the notification carries the source URL, and this controller knows
/// its own), so the host doesn't route per-card updates.
private final class UndownloadedMediaCardContentViewController: CardContentViewController {

    private let sourceURLString: String
    private let download: () -> Void
    private let button = UIButton(configuration: .plain())
    private let progressRing = CircularDownloadProgressView()

    init(item: SavedMediaItem, download: @escaping () -> Void) {
        self.sourceURLString = item.sourceURLString
        self.download = download
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

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

        progressRing.isHidden = true
        progressRing.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressRing)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            progressRing.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressRing.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            progressRing.widthAnchor.constraint(equalToConstant: 44),
            progressRing.heightAnchor.constraint(equalToConstant: 44),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobProgressChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
        updateProgress(LiveMediaDownloadManager.shared.currentDownloadProgress(
            forSourceURLString: sourceURLString))
    }

    @objc private func handleJobProgressChanged(_ notification: Notification) {
        guard let urlString = notification.userInfo?["sourceURLString"] as? String,
              urlString == sourceURLString
        else { return }
        let progress = notification.userInfo?["progress"] as? Double
        DispatchQueue.main.async { [weak self] in
            self?.updateProgress(progress)
        }
    }

    private func updateProgress(_ progress: Double?) {
        if let progress {
            progressRing.progress = progress
            progressRing.isHidden = false
            button.isHidden = true
        } else {
            progressRing.isHidden = true
            button.isHidden = false
        }
    }
}

/// A ring that fills clockwise from 0 to `progress` (0...1). Track + progress
/// arc as two `CAShapeLayer`s so updates are a cheap `strokeEnd` animation.
private final class CircularDownloadProgressView: UIView {
    var progress: Double = 0 {
        didSet {
            let clamped = min(1, max(0, progress))
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = progressLayer.presentation()?.strokeEnd ?? oldValue
            animation.toValue = clamped
            animation.duration = 0.2
            progressLayer.strokeEnd = clamped
            progressLayer.add(animation, forKey: "strokeEnd")
        }
    }

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = LunaColors.secondaryText.withAlphaComponent(0.35).cgColor
        trackLayer.lineWidth = 3
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.strokeColor = LunaColors.primaryText.cgColor
        progressLayer.lineWidth = 3
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        layer.addSublayer(trackLayer)
        layer.addSublayer(progressLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = min(bounds.width, bounds.height) / 2 - 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath(
            arcCenter: center, radius: radius,
            startAngle: -.pi / 2, endAngle: .pi * 1.5,
            clockwise: true)
        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
    }
}
