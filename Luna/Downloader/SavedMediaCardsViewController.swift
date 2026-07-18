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
import LunaSocialUI
import LunaStorage
import LunaURLClassification
import Photos
import UIKit

final class SavedMediaCardsViewController: UIViewController {

    private let header = NavHeaderBar()
    private let store = SavedMediaStore.shared
    private let photoSaver = PhotoLibrarySaver()
    private let downloadFooter = DownloaderProgressFooterView()
    private let carousel = CardCarouselViewController()
    private let emptyView = EmptyMediaView()
    private var items: [SavedMediaItem] = []
    private var isReconcilingPhotos = false
    /// Fingerprint of the last-applied item list, so store notifications that
    /// changed nothing visible (frequent on foreground/activation catch-ups)
    /// don't tear down and rebuild live card content mid-playback.
    private var appliedFingerprint: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        var style = CardCarouselStyle()
        style.pageSwipeMovementMultiplier = 1.5
        carousel.style = style
        carousel.dataSource = self
        carousel.delegate = self
        addChild(carousel)
        view.addSubview(carousel.view)
        carousel.view.translatesAutoresizingMaskIntoConstraints = false
        carousel.didMove(toParent: self)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)

        let headerBottom = header.mount(in: self)
        setHeaderControls()

        NSLayoutConstraint.activate([
            carousel.view.topAnchor.constraint(equalTo: headerBottom),
            carousel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            carousel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            carousel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyView.topAnchor.constraint(equalTo: headerBottom),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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
            self, selector: #selector(reload), name: UIApplication.didBecomeActiveNotification,
            object: nil)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        header.setManagedHeight(topSafeAreaInset: view.safeAreaInsets.top)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        header.setManagedHeight(topSafeAreaInset: view.safeAreaInsets.top)
    }

    private func setHeaderControls() {
        header.setLeadingControls([
            NavHeaderBar.imageButton(
                systemName: "gearshape",
                target: self,
                action: #selector(settingsTapped),
                accessibilityLabel: "Settings"),
            NavHeaderBar.imageButton(
                systemName: "person.2",
                target: self,
                action: #selector(friendsTapped),
                accessibilityLabel: "Friends"),
        ])
        header.setTrailingControls([
            NavHeaderBar.imageButton(
                systemName: "plus",
                target: self,
                action: #selector(addTapped),
                accessibilityLabel: "Add"),
        ])
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
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Store

    @objc private func applicationForegrounded() {
        store.purgeExpired()
        reload()
    }

    @objc private func reload() {
        store.purgeExpired()
        let updated = store.items()
        let fingerprint = updated.map { item in
            "\(item.id)|\(item.thumbnailFileName ?? "")|\(storageStateKey(item))"
        }
        defer { reconcilePhotosReferencesIfAuthorized() }
        guard fingerprint != appliedFingerprint else { return }
        appliedFingerprint = fingerprint

        let centeredID = items.indices.contains(carousel.currentIndex)
            ? items[carousel.currentIndex].id : nil
        items = updated
        let centeredIndex = centeredID.flatMap { id in items.firstIndex { $0.id == id } }
        carousel.reloadData(centeringAt: centeredIndex)
        emptyView.isHidden = !items.isEmpty
        carousel.view.isHidden = items.isEmpty
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

    // MARK: - Header actions

    @objc private func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    @objc private func friendsTapped() {
        navigationController?.pushViewController(FriendsViewController(), animated: true)
    }

    @objc private func addTapped() {
        let alert = UIAlertController(title: "Save Media", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://..."
            field.keyboardType = .URL
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            guard let entered = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let normalized = URLUnwrapper.ingestURL(from: entered, allowBareHost: true)
            else { return }
            Task {
                let urlString = normalized.absoluteString
                _ = await ReadingListIngestor.shared.handleSavePress(urlString: urlString)
                guard MediaDownloadablePlatform.supports(urlString) else { return }
                // A duplicate reading-list save still needs to resume an
                // undownloaded/interrupted Downloader media row.
                _ = await DownloaderIntentPhotoPermission.requestIfNeeded()
                _ = await LiveMediaDownloadManager.shared.start(
                    urlString: urlString, ownership: .downloader)
            }
        })
        present(alert, animated: true)
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
        items.count
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        guard items.indices.contains(index) else { return CardContentViewController() }
        let item = items[index]
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
        loadThumbnailForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard items.indices.contains(index) else {
            completion(nil)
            return
        }
        loadThumbnail(for: items[index], completion: completion)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        topLeadingAccessoryForCardAt index: Int
    ) -> UIView? {
        guard items.indices.contains(index),
              items[index].photosLocalIdentifier != nil
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
        guard items.indices.contains(index) else { return }
        markOpened(items[index])
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contextMenuForCardAt index: Int
    ) -> UIContextMenuConfiguration? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
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
