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
import LunaDesignSystem
import LunaMediaDownload
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import LunaURLClassification
import Photos
import UIKit

final class SavedMediaCardsViewController: UIViewController {

    private let store = SavedMediaStore.shared
    private let photoSaver = PhotoLibrarySaver()
    private let downloadFooter = DownloaderProgressFooterView()
    private let carousel = CardCarouselViewController()
    private let emptyView = EmptyMediaView()
    private let settingsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private var items: [SavedMediaItem] = []
    private var isReconcilingPhotos = false
    private var pasteboardURL: URL?
    private var renderedPasteboardURL: URL?
    private var consumedPasteboardChangeCount: Int?
    private var pendingPasteboardDownloadURLString: String?
    /// Fingerprint of the last-applied item list, so store notifications that
    /// changed nothing visible (frequent on foreground/activation catch-ups)
    /// don't tear down and rebuild live card content mid-playback.
    private var appliedFingerprint: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        var style = CardCarouselStyle()
        style.pageSwipeMovementMultiplier = 1.5
        style.autoplaysScrubPreviewContent = true
        style.scrubberHorizontalInset = 0
        style.scrubberEdgeFadeWidth = 72
        style.showsCardBorder = true
        carousel.style = style
        carousel.dataSource = self
        carousel.delegate = self
        addChild(carousel)
        view.addSubview(carousel.view)
        carousel.view.translatesAutoresizingMaskIntoConstraints = false
        carousel.didMove(toParent: self)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        NSLayoutConstraint.activate([
            carousel.view.topAnchor.constraint(equalTo: view.topAnchor),
            carousel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            carousel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            carousel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        mountBottomControls()
        mountDownloadFooter()

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
        applyCarouselTopInset()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyCarouselTopInset()
    }

    private func applyCarouselTopInset() {
        carousel.setTopInset(view.safeAreaInsets.top + 4)
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
        view.addSubview(settingsButton)
        view.addSubview(shareButton)
        NSLayoutConstraint.activate([
            settingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            settingsButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            settingsButton.widthAnchor.constraint(equalToConstant: 44),
            settingsButton.heightAnchor.constraint(equalToConstant: 44),
            shareButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            shareButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -26),
            shareButton.widthAnchor.constraint(equalToConstant: 44),
            shareButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureBottomButton(
        _ button: UIButton, symbol: String, action: Selector, accessibilityLabel: String
    ) {
        button.configuration = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 10)
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
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
        reload()
        refreshPasteboardURL()
    }

    @objc private func reload() {
        store.purgeExpired()
        let updated = store.items()
        var fingerprint = updated.map { item in
            "\(item.id)|\(item.thumbnailFileName ?? "")|\(storageStateKey(item))"
        }
        fingerprint.insert("paste|\(pasteboardURL?.absoluteString ?? "")", at: 0)
        defer { reconcilePhotosReferencesIfAuthorized() }
        guard fingerprint != appliedFingerprint else { return }
        appliedFingerprint = fingerprint

        let oldItemIndex = carousel.currentIndex - cardOffset
        let centeredID = items.indices.contains(oldItemIndex) ? items[oldItemIndex].id : nil
        items = updated
        renderedPasteboardURL = pasteboardURL
        let pendingIndex = pendingPasteboardDownloadURLString.flatMap { pending in
            items.firstIndex { $0.sourceURLString == pending }
        }
        let centeredIndex = centeredID.flatMap { id in
            items.firstIndex { $0.id == id }.map { $0 + cardOffset }
        } ?? pendingIndex.map { $0 + cardOffset }
            ?? (items.isEmpty ? 0 : cardOffset)
        if pendingIndex != nil { pendingPasteboardDownloadURLString = nil }
        carousel.reloadData(centeringAt: centeredIndex)
        emptyView.isHidden = !items.isEmpty || renderedPasteboardURL != nil
        carousel.view.isHidden = items.isEmpty && renderedPasteboardURL == nil
        updateShareButton()
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

    private var cardOffset: Int { renderedPasteboardURL == nil ? 0 : 1 }

    private func mediaIndex(forCarouselIndex index: Int) -> Int? {
        let mediaIndex = index - cardOffset
        return items.indices.contains(mediaIndex) ? mediaIndex : nil
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

    @objc private func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func shareCurrentTapped() {
        guard let current = currentMediaItem() else { return }
        share(current.item, sourceIndex: current.carouselIndex)
    }

    @objc private func refreshPasteboardURL() {
        let pasteboard = UIPasteboard.general
        if consumedPasteboardChangeCount == pasteboard.changeCount {
            guard pasteboardURL != nil else { return }
            pasteboardURL = nil
            reload()
            return
        }
        let changeCount = pasteboard.changeCount
        // Ask UIKit for the structured URL value in one operation rather than
        // reading loosely typed pasteboard contents and reparsing them.
        pasteboard.detectValues(for: [\.probableWebURL]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, UIPasteboard.general.changeCount == changeCount else { return }
                let value = try? result.get().probableWebURL
                let candidate = value.flatMap {
                    URLUnwrapper.ingestURL(from: $0, allowBareHost: true)
                }.flatMap { url -> URL? in
                    guard MediaDownloadablePlatform.supports(url.absoluteString),
                          self.store.matchingItem(forURLString: url.absoluteString) == nil
                    else { return nil }
                    return url
                }
                guard candidate != self.pasteboardURL else {
                    self.reload()
                    return
                }
                self.pasteboardURL = candidate
                self.reload()
            }
        }
    }

    private func downloadPasteboardURL() {
        guard let url = renderedPasteboardURL ?? pasteboardURL else { return }
        consumedPasteboardChangeCount = UIPasteboard.general.changeCount
        pasteboardURL = nil
        pendingPasteboardDownloadURLString = url.absoluteString
        Task {
            _ = await DownloaderIntentPhotoPermission.requestIfNeeded()
            _ = await LiveMediaDownloadManager.shared.start(
                urlString: url.absoluteString,
                ownership: .downloader,
                manual: true)
            _ = await ReadingListIngestor.shared.handleSavePress(
                urlString: url.absoluteString, source: .paste)
        }
    }

    // MARK: - Item actions (context menu)

    private func share(_ item: SavedMediaItem, sourceIndex: Int) {
        guard let backing = providerBacking(for: item),
              let provider = MediaItemProviderFactory.makeProvider(for: backing)
        else { return }
        let activity = UIActivityViewController(activityItems: [provider], applicationActivities: nil)
        if let card = carousel.cardView(at: sourceIndex) {
            activity.popoverPresentationController?.sourceView = card
            activity.popoverPresentationController?.sourceRect = card.bounds
        }
        present(activity, animated: true)
    }

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
                let localIdentifier = try await photoSaver.save(fileURL: tempURL, kind: kind)
                _ = try store.transitionToPhotosReference(
                    item.id, localIdentifier: localIdentifier, kind: kind)
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
                if let localIdentifier = item.photosLocalIdentifier {
                    try await self?.photoSaver.deleteAsset(localIdentifier: localIdentifier)
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

    private func providerBacking(for item: SavedMediaItem) -> MediaItemProviderBacking? {
        switch item.storageState {
        case .undownloaded:
            return nil
        case .localFile:
            return item.fileURL.map(MediaItemProviderBacking.localFile)
        case .photosReference(let identifier, _, _):
            guard let kind = item.kind else { return nil }
            return .photo(localIdentifier: identifier, kind: kind)
        }
    }

    /// A Photos identifier that no longer resolves is a deletion only when Luna
    /// has full read permission. Without permission, an empty fetch is not
    /// evidence of deletion.
    private func reconcilePhotosReferencesIfAuthorized() {
        guard !isReconcilingPhotos,
              items.contains(where: { $0.photosLocalIdentifier != nil })
        else { return }
        isReconcilingPhotos = true
        Task { @MainActor in
            let authorized = await photoSaver.requestReadAuthorization()
            defer { isReconcilingPhotos = false }
            guard authorized,
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            else { return }
            let missing = items.filter { item in
                guard let identifier = item.photosLocalIdentifier else { return false }
                return photoSaver.fetchAsset(localIdentifier: identifier) == nil
            }
            for item in missing {
                deleteSavedItem(for: item)
            }
        }
    }
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
        if let url = renderedPasteboardURL, index == 0 {
            return PasteboardMediaCardContentViewController(url: url) { [weak self] in
                self?.downloadPasteboardURL()
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
        if renderedPasteboardURL != nil, index == 0 {
            completion(UIImage(systemName: "doc.on.clipboard"))
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
              items[mediaIndex].photosLocalIdentifier != nil
        else { return nil }
        return PhotosReferenceBadgeView()
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
        guard let mediaIndex = mediaIndex(forCarouselIndex: index) else { return }
        markOpened(items[mediaIndex])
    }

    func carousel(_ carousel: CardCarouselViewController, didTapCenteredCardAt index: Int) {
        guard renderedPasteboardURL != nil, index == 0 else { return }
        downloadPasteboardURL()
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
                title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in self?.deleteSavedItem(for: item) })
            return UIMenu(children: actions)
        })
    }
}

// MARK: - Pasteboard card

/// A transient leading card for a supported media URL detected on the
/// pasteboard. Nothing is persisted or downloaded until the user taps it.
private final class PasteboardMediaCardContentViewController: CardContentViewController {
    private let url: URL
    private let download: () -> Void
    private let downloadButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let progress = MoonHorizonProgressBar()
    private var hasStarted = false

    init(url: URL, download: @escaping () -> Void) {
        self.url = url
        self.download = download
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "doc.on.clipboard"))
        icon.tintColor = GlassStyle.readingAccent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42, weight: .medium)

        let title = UILabel()
        title.text = "Download Pasted Link"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = .label
        title.textAlignment = .center

        let urlLabel = UILabel()
        urlLabel.text = url.absoluteString
        urlLabel.font = .preferredFont(forTextStyle: .subheadline)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 4
        urlLabel.lineBreakMode = .byTruncatingMiddle

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Download"
        configuration.image = UIImage(systemName: "arrow.down.circle")
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = GlassStyle.readingAccent
        downloadButton.configuration = configuration
        downloadButton.accessibilityHint = url.absoluteString
        downloadButton.addAction(UIAction { [weak self] _ in
            self?.beginDownload()
        }, for: .touchUpInside)

        statusLabel.text = "Starting download…"
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.isHidden = true

        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            icon, title, urlLabel, downloadButton, statusLabel, progress,
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobProgressChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
        if let current = LiveMediaDownloadManager.shared.currentDownloadProgress(
            forSourceURLString: url.absoluteString) {
            showProgress(current)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func beginDownload() {
        guard !hasStarted else { return }
        hasStarted = true
        showProgress(0)
        download()
    }

    @objc private func handleJobProgressChanged(_ notification: Notification) {
        guard let source = notification.userInfo?["sourceURLString"] as? String,
              source == url.absoluteString
        else { return }
        if let snapshot = notification.userInfo?["snapshot"] as? DownloaderJobSnapshot {
            statusLabel.text = snapshot.message
        }
        showProgress(notification.userInfo?["progress"] as? Double ?? 0)
    }

    private func showProgress(_ value: Double) {
        downloadButton.isHidden = true
        statusLabel.isHidden = false
        progress.isHidden = false
        progress.setProgress(Float(value), animated: true)
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
        configuration.baseForegroundColor = .secondaryLabel
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
        trackLayer.strokeColor = UIColor.secondaryLabel.withAlphaComponent(0.35).cgColor
        trackLayer.lineWidth = 3
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.strokeColor = UIColor.label.cgColor
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

// MARK: - Empty state

private final class EmptyMediaView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let image = UIImageView(image: UIImage(systemName: "photo.on.rectangle.angled"))
        image.tintColor = .tertiaryLabel
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let title = UILabel()
        title.text = "No Saved Media"
        title.font = .preferredFont(forTextStyle: .title3)
        title.textColor = .label
        let subtitle = UILabel()
        subtitle.text = "Saved Downloader links appear here after Luna downloads the media."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [image, title, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
