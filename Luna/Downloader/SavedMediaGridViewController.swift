//
//  SavedMediaGridViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaMediaDownload
import LunaReadingList
import LunaReadingListUI
import LunaSocialUI
import LunaStorage
import LunaTransitions
import LunaURLClassification
import Photos
import UIKit

final class SavedMediaGridViewController: UICollectionViewController {
    private enum Section { case main }

    private let header = NavHeaderBar()
    private let store = SavedMediaStore.shared
    private let photoSaver = PhotoLibrarySaver()
    private let downloadFooter = DownloaderProgressFooterView()
    private var items: [SavedMediaItem] = []
    private var isReconcilingPhotos = false
    private lazy var dataSource = makeDataSource()

    init() {
        super.init(collectionViewLayout: Self.makeLayout())
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collectionView.backgroundColor = .systemBackground
        collectionView.register(SavedMediaCell.self, forCellWithReuseIdentifier: SavedMediaCell.reuseID)
        collectionView.dataSource = dataSource
        header.mount(in: self)
        setHeaderControls()
        mountDownloadFooter()
        // Bridges saves/deletes made by the action/share extension (a DIFFERENT process,
        // so the in-process .savedMediaChanged post below never reaches it) back to a
        // .savedMediaChanged post here via a Darwin notification. Idempotent.
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
        // activation (covers iPad multitasking, where the app can stay foregrounded the
        // whole time an extension runs alongside it, and plain didBecomeActive returns).
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleJobProgressChanged(_:)),
            name: .downloaderJobProgressChanged, object: nil)
        reload()
    }

    /// Live per-item download progress: updates just the affected visible
    /// cell's ring in place, no full grid reload (so the fill animates
    /// smoothly). A cell not currently visible picks up the right state next
    /// time it's configured (`SavedMediaCell.configure` does the same
    /// synchronous lookup).
    @objc private func handleJobProgressChanged(_ notification: Notification) {
        guard let urlString = notification.userInfo?["sourceURLString"] as? String else { return }
        let progress = notification.userInfo?["progress"] as? Double
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for case let cell as SavedMediaCell in self.collectionView.visibleCells
            where cell.representsSourceURLString(urlString) {
                cell.updateProgress(progress)
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        updateInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateInsets()
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        header.updateScrolledAppearance(
            contentOffsetY: scrollView.contentOffset.y,
            adjustedTopInset: scrollView.adjustedContentInset.top)
    }

    /// Column count + exactly-square item width for a Photos-style grid at a given
    /// container width: hairline `gap` between cells, no outer insets. Pulled out as
    /// pure math (no UIKit types) so it's covered by a plain unit test — see
    /// `SavedMediaGridLayoutTests`. 3 columns on an iPhone-portrait-width layout,
    /// scaling up for wider layouts (landscape, iPad) — no upper cap, matching Photos.
    static func columnLayout(width: CGFloat, gap: CGFloat = 1) -> (columns: Int, itemWidth: CGFloat) {
        let columns = max(3, Int(width / 130))
        let itemWidth = ((width - gap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        return (columns, itemWidth)
    }

    /// Photos-style grid: edge-to-edge, hairline (1pt) gaps between cells, no outer
    /// section insets. Squareness is computed explicitly (not left to fractional
    /// dimensions resolving against the group) so cells stay exactly square at any
    /// column count / gap combination.
    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let gap: CGFloat = 1
            let (columns, itemWidth) = columnLayout(width: width, gap: gap)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                    heightDimension: .absolute(itemWidth)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(itemWidth)),
                subitem: item,
                count: columns)
            group.interItemSpacing = .fixed(gap)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .zero
            section.interGroupSpacing = gap
            return section
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, UUID> {
        UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: SavedMediaCell.reuseID, for: indexPath) as? SavedMediaCell
                ?? SavedMediaCell()
            let item = self?.items.first { $0.id == id }
            cell.configure(item)
            return cell
        }
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

    private func updateInsets() {
        header.setManagedHeight(topSafeAreaInset: view.safeAreaInsets.top)
        collectionView.contentInset.top = NavHeaderBar.barHeight
        collectionView.verticalScrollIndicatorInsets.top = NavHeaderBar.barHeight
    }

    /// Floats the download-progress footer above the grid, bottom-anchored to the
    /// safe area — mirrors the Live Activity / action-extension download UI so a
    /// Downloader-owned job started from anywhere (grid tap, add-by-URL, share
    /// extension) reads the same in-app. Purely informational; the grid stays
    /// fully scrollable/tappable underneath it.
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

    @objc private func applicationForegrounded() {
        store.purgeExpired()
        reload()
    }

    @objc private func reload() {
        store.purgeExpired()
        let previousIDs = Set(items.map(\.id))
        items = store.items()
        let ids = items.map(\.id)
        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(ids, toSection: .main)
        // An id that persisted across this reload is still the same collection-view
        // item identity, so appendItems alone wouldn't refresh its cell — but its
        // thumbnail may have only just been written to disk. Explicitly reconfigure
        // those so the new thumbnail actually shows up.
        let persisting = ids.filter { previousIDs.contains($0) }
        if !persisting.isEmpty {
            snapshot.reconfigureItems(persisting)
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        collectionView.backgroundView = items.isEmpty ? EmptyMediaView() : nil
        reconcilePhotosReferencesIfAuthorized()
    }

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
        DotMatrixModal.present(alert, from: self)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < items.count else { return }
        if case .undownloaded = items[indexPath.item].storageState {
            startDownload(items[indexPath.item])
            return
        }
        // The viewer marks the initially-shown item (and every item paged to
        // afterwards) as opened itself — see SavedMediaViewerViewController.markOpened.
        let viewer = SavedMediaViewerViewController(items: items, initialIndex: indexPath.item, grid: self)
        navigationController?.pushViewController(viewer, animated: true)
    }

    /// Resolves the grid cell currently displaying `id`, scrolling it into view first
    /// if it's off-screen — used as the zoom transition's `sourceViewProvider` so the
    /// dismiss-from-viewer animation always zooms back into the right cell, even if the
    /// user paged to a different item while the viewer was open.
    func gridCellView(for id: UUID) -> UIView? {
        guard let indexPath = dataSource.indexPath(for: id) else { return nil }
        if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        return collectionView.cellForItem(at: indexPath)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPath.item < items.count else { return nil }
        let item = items[indexPath.item]
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
                ) { [weak self] _ in self?.share(item, sourceIndexPath: indexPath) })
                actions.append(UIAction(
                    title: "Save to Photos", image: UIImage(systemName: "photo.badge.plus")
                ) { [weak self] _ in self?.saveToPhotos(item) })
            case .photosReference:
                actions.append(UIAction(
                    title: "Share", image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in self?.share(item, sourceIndexPath: indexPath) })
            }
            actions.append(UIAction(
                title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in self?.deleteSavedItem(for: item) })
            return UIMenu(children: actions)
        })
    }

    private func share(_ item: SavedMediaItem, sourceIndexPath: IndexPath) {
        guard let backing = providerBacking(for: item),
              let provider = MediaItemProviderFactory.makeProvider(for: backing)
        else { return }
        let activity = UIActivityViewController(activityItems: [provider], applicationActivities: nil)
        if let cell = collectionView.cellForItem(at: sourceIndexPath) {
            activity.popoverPresentationController?.sourceView = cell
            activity.popoverPresentationController?.sourceRect = cell.bounds
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
        DotMatrixModal.present(alert, from: self)
    }

    func deleteSavedItem(for item: SavedMediaItem, onFailure: (() -> Void)? = nil) {
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
                if let onFailure {
                    onFailure()
                } else {
                    self?.presentAlert(
                        title: "Photos Access Needed",
                        message: "Allow Photos access in Settings to delete this media from Photos.")
                }
            }
        }
    }

    private func startDownload(_ item: SavedMediaItem) {
        Task {
            // Tap-to-download and the long-press "Download" action are both
            // explicit "download this exact item now" gestures, so both bypass
            // the Wi-Fi-only setting (unlike the opportunistic resume sweep).
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

    /// A Photos identifier that no longer resolves is a deletion only when Luna has
    /// read permission. Without permission, an empty fetch is not evidence of deletion.
    private func reconcilePhotosReferencesIfAuthorized() {
        guard !isReconcilingPhotos,
              items.contains(where: { $0.photosLocalIdentifier != nil })
        else { return }
        isReconcilingPhotos = true
        Task { @MainActor in
            let authorized = await photoSaver.requestReadAuthorization()
            defer { isReconcilingPhotos = false }
            guard authorized else { return }
            var snapshot = dataSource.snapshot()
            let photoIDs = items.compactMap { item in
                item.photosLocalIdentifier == nil ? nil : item.id
            }
            if !photoIDs.isEmpty {
                snapshot.reconfigureItems(photoIDs)
                await dataSource.apply(snapshot, animatingDifferences: false)
            }
            // Limited access can hide a still-existing asset, so absence is proof
            // of deletion only with full read/write authorization.
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                return
            }
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

private final class SavedMediaCell: UICollectionViewCell {
    static let reuseID = "SavedMediaCell"
    private let imageView = UIImageView()
    // Photos-style bottom-edge scrim so the play glyph (and, if ever added, a
    // duration label) reads over bright thumbnails.
    private let scrimLayer = CAGradientLayer()
    private let scrimView = UIView()
    private let glyphView = UIImageView(image: UIImage(systemName: "play.fill"))
    private let photosBadgeView = PhotosReferenceBadgeView()
    private let progressRing = CircularProgressView()
    private var photoRequestID: PHImageRequestID = PHInvalidImageRequestID
    private var representedItemID: UUID?
    private var representedSourceURLString: String?
    private var isShowingUndownloadedState = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        scrimView.isUserInteractionEnabled = false
        scrimLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.55).cgColor]
        scrimLayer.locations = [0, 1]
        scrimView.layer.addSublayer(scrimLayer)
        scrimView.translatesAutoresizingMaskIntoConstraints = false

        glyphView.tintColor = .white
        glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        photosBadgeView.translatesAutoresizingMaskIntoConstraints = false
        progressRing.isHidden = true
        progressRing.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        contentView.addSubview(scrimView)
        contentView.addSubview(glyphView)
        contentView.addSubview(photosBadgeView)
        contentView.addSubview(progressRing)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrimView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrimView.heightAnchor.constraint(equalToConstant: 32),
            glyphView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            glyphView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            photosBadgeView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            photosBadgeView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            photosBadgeView.widthAnchor.constraint(equalToConstant: 24),
            photosBadgeView.heightAnchor.constraint(equalToConstant: 24),
            progressRing.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            progressRing.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            progressRing.widthAnchor.constraint(equalToConstant: 36),
            progressRing.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrimLayer.frame = scrimView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if photoRequestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(photoRequestID)
        }
        photoRequestID = PHInvalidImageRequestID
        representedItemID = nil
        representedSourceURLString = nil
        isShowingUndownloadedState = false
        imageView.image = nil
        imageView.preferredSymbolConfiguration = nil
        glyphView.isHidden = true
        scrimView.isHidden = true
        photosBadgeView.isHidden = true
        progressRing.isHidden = true
    }

    /// Whether this cell is currently displaying `urlString`'s undownloaded/
    /// downloading state — used by the grid to route a live progress
    /// notification to the right visible cell.
    func representsSourceURLString(_ urlString: String) -> Bool {
        isShowingUndownloadedState && representedSourceURLString == urlString
    }

    /// Live update from `.downloaderJobProgressChanged`, called only on a cell
    /// that `representsSourceURLString` confirmed is showing this URL's
    /// undownloaded state — a stale notification arriving after the item
    /// completed (and the cell was reconfigured to a thumbnail by the normal
    /// `.savedMediaChanged` reload) is a no-op.
    func updateProgress(_ progress: Double?) {
        guard isShowingUndownloadedState else { return }
        if let progress {
            progressRing.progress = progress
            progressRing.isHidden = false
            imageView.image = nil
        } else {
            progressRing.isHidden = true
            imageView.image = UIImage(systemName: "arrow.down.circle.dotted")
                ?? UIImage(systemName: "arrow.down.circle")
        }
    }

    func configure(_ item: SavedMediaItem?) {
        guard let item else { return }
        representedItemID = item.id
        representedSourceURLString = item.sourceURLString
        contentView.backgroundColor = .secondarySystemBackground
        photosBadgeView.isHidden = item.photosLocalIdentifier == nil

        if case .undownloaded = item.storageState {
            isShowingUndownloadedState = true
            imageView.tintColor = .secondaryLabel
            imageView.contentMode = .center
            imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: 34, weight: .regular)
            glyphView.isHidden = true
            scrimView.isHidden = true
            let progress = LiveMediaDownloadManager.shared.currentDownloadProgress(
                forSourceURLString: item.sourceURLString)
            updateProgress(progress)
            return
        }
        isShowingUndownloadedState = false
        progressRing.isHidden = true

        if let identifier = item.photosLocalIdentifier,
           let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil).firstObject {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            photoRequestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 600, height: 600),
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, _ in
                guard let self, self.representedItemID == item.id, let image else { return }
                self.imageView.image = image
                self.imageView.contentMode = .scaleAspectFill
                self.imageView.tintColor = nil
            }
        } else if let url = item.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
            imageView.image = image
            imageView.contentMode = .scaleAspectFill
            imageView.tintColor = nil
        } else {
            imageView.image = UIImage(systemName: item.kind == .video ? "video.fill" : "photo")
            imageView.tintColor = .tertiaryLabel
            imageView.contentMode = .center
        }
        // SavedMediaItem carries no duration today, so we show the play glyph
        // (as before) plus the scrim behind it — no duration text plumbing added.
        let isPlayable = item.kind == .video || item.kind == .gif
        glyphView.isHidden = !isPlayable
        scrimView.isHidden = !isPlayable
    }
}

/// A ring that fills clockwise from 0 to `progress` (0...1), for the grid's
/// "downloading" cell state. Track + progress arc as two `CAShapeLayer`s so
/// updates are a cheap `strokeEnd` animation rather than a redraw.
private final class CircularProgressView: UIView {
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
        trackLayer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        trackLayer.lineWidth = 3
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.strokeColor = UIColor.white.cgColor
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
