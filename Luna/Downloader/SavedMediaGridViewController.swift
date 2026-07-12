//
//  SavedMediaGridViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaMediaDownload
import LunaReadingList
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
        reload()
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
            Task { await ReadingListIngestor.shared.handleSavePress(urlString: normalized.absoluteString) }
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

    private func deleteSavedItem(for item: SavedMediaItem) {
        AutoDownloadSettings.unmarkDownloaded(item.sourceURLString)
        if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
            ReadingListStore.shared.delete(saved)
        }
        store.delete(item)
    }

    private func startDownload(_ item: SavedMediaItem) {
        Task {
            _ = await LiveMediaDownloadManager.shared.start(
                urlString: item.sourceURLString, title: item.title)
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
    private var photoRequestID: PHImageRequestID = PHInvalidImageRequestID
    private var representedItemID: UUID?

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
        contentView.addSubview(imageView)
        contentView.addSubview(scrimView)
        contentView.addSubview(glyphView)
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
        imageView.image = nil
        imageView.preferredSymbolConfiguration = nil
        glyphView.isHidden = true
        scrimView.isHidden = true
    }

    func configure(_ item: SavedMediaItem?) {
        guard let item else { return }
        representedItemID = item.id
        contentView.backgroundColor = .secondarySystemBackground

        if case .undownloaded = item.storageState {
            imageView.image = UIImage(systemName: "arrow.down.circle.dotted")
                ?? UIImage(systemName: "arrow.down.circle")
            imageView.tintColor = .secondaryLabel
            imageView.contentMode = .center
            imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: 34, weight: .regular)
            glyphView.isHidden = true
            scrimView.isHidden = true
            return
        }

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
