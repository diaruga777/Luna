//
//  SavedMediaGridViewController.swift
//  Luna
//

import AVKit
import LunaDesignSystem
import LunaMediaDownload
import LunaReadingList
import LunaSocialUI
import LunaStorage
import LunaTransitions
import LunaURLClassification
import UIKit

final class SavedMediaGridViewController: UICollectionViewController {
    private enum Section { case main }

    private let header = NavHeaderBar()
    private let store = SavedMediaStore.shared
    private let photoSaver = PhotoLibrarySaver()
    private var items: [SavedMediaItem] = []
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .savedMediaChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationForegrounded),
            name: UIApplication.willEnterForegroundNotification,
            object: nil)
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

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(3, min(6, Int(width / 118)))
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .fractionalWidth(1)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .fractionalWidth(1 / CGFloat(columns))),
                subitem: item,
                count: columns)
            return NSCollectionLayoutSection(group: group)
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
        items = store.items()
        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(items.map(\.id), toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        collectionView.backgroundView = items.isEmpty ? EmptyMediaView() : nil
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
        let item = items[indexPath.item]
        let viewer = SavedMediaViewerViewController(items: items, initialIndex: indexPath.item)
        navigationController?.pushViewController(viewer, animated: true)
        if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
            ReadingListStore.shared.markReadState(.opened, for: saved.id)
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPath.item < items.count else { return nil }
        let item = items[indexPath.item]
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.share(item, sourceIndexPath: indexPath)
                },
                UIAction(title: "Save to Photos", image: UIImage(systemName: "photo.badge.plus")) { [weak self] _ in
                    self?.saveToPhotos(item)
                },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.deleteSavedItem(for: item)
                },
            ])
        })
    }

    private func share(_ item: SavedMediaItem, sourceIndexPath: IndexPath) {
        let activity = UIActivityViewController(activityItems: [item.fileURL], applicationActivities: nil)
        if let cell = collectionView.cellForItem(at: sourceIndexPath) {
            activity.popoverPresentationController?.sourceView = cell
            activity.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(activity, animated: true)
    }

    private func saveToPhotos(_ item: SavedMediaItem) {
        Task { @MainActor in
            do {
                guard await photoSaver.requestAddAuthorization() else {
                    presentAlert(
                        title: "Photos Access Needed",
                        message: "Allow photo library access in Settings to save media.")
                    return
                }
                let tempURL = MediaDownloadStorage.newFileURL(extension: item.fileURL.pathExtension)
                try FileManager.default.copyItem(at: item.fileURL, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await photoSaver.save(fileURL: tempURL, kind: item.kind)
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
        if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
            ReadingListStore.shared.delete(saved)
        } else {
            store.delete(item)
        }
    }
}

private final class SavedMediaCell: UICollectionViewCell {
    static let reuseID = "SavedMediaCell"
    private let imageView = UIImageView()
    private let glyphView = UIImageView(image: UIImage(systemName: "play.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.tintColor = .white
        glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        contentView.addSubview(glyphView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            glyphView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            glyphView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        glyphView.isHidden = true
    }

    func configure(_ item: SavedMediaItem?) {
        guard let item else { return }
        if let url = item.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
            imageView.image = image
            imageView.contentMode = .scaleAspectFill
            imageView.tintColor = nil
        } else {
            imageView.image = UIImage(systemName: item.kind == .video ? "video.fill" : "photo")
            imageView.tintColor = .tertiaryLabel
            imageView.contentMode = .center
        }
        glyphView.isHidden = item.kind == .image
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

private final class SavedMediaViewerViewController: UIViewController, UIScrollViewDelegate {
    private let items: [SavedMediaItem]
    private var index: Int
    private var playerController: AVPlayerViewController?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(items: [SavedMediaItem], initialIndex: Int) {
        self.items = items
        self.index = initialIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationController?.setNavigationBarHidden(false, animated: true)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .trash,
            target: self,
            action: #selector(deleteCurrent))
        configureSwipeGestures()
        showCurrent()
    }

    private func configureSwipeGestures() {
        let left = UISwipeGestureRecognizer(target: self, action: #selector(nextItem))
        left.direction = .left
        let right = UISwipeGestureRecognizer(target: self, action: #selector(previousItem))
        right.direction = .right
        view.addGestureRecognizer(left)
        view.addGestureRecognizer(right)
    }

    private func showCurrent() {
        guard items.indices.contains(index) else {
            navigationController?.popViewController(animated: true)
            return
        }
        let item = items[index]
        title = item.title ?? item.sourceURLString
        children.forEach { child in
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        scrollView.removeFromSuperview()
        playerController?.player?.pause()
        playerController = nil

        switch item.kind {
        case .video:
            let player = AVPlayer(url: item.fileURL)
            let controller = AVPlayerViewController()
            controller.player = player
            controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addChild(controller)
            view.addSubview(controller.view)
            controller.didMove(toParent: self)
            playerController = controller
            player.play()
        case .image, .gif:
            scrollView.frame = view.bounds
            scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 4
            scrollView.zoomScale = 1
            scrollView.delegate = self
            imageView.image = UIImage(contentsOfFile: item.fileURL.path)
            imageView.contentMode = .scaleAspectFit
            imageView.frame = scrollView.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scrollView.addSubview(imageView)
            view.addSubview(scrollView)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func nextItem() {
        guard index + 1 < items.count else { return }
        index += 1
        showCurrent()
    }

    @objc private func previousItem() {
        guard index > 0 else { return }
        index -= 1
        showCurrent()
    }

    @objc private func deleteCurrent() {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if let saved = ReadingListStore.shared.item(forURLString: item.sourceURLString) {
            ReadingListStore.shared.delete(saved)
        } else {
            SavedMediaStore.shared.delete(item)
        }
        navigationController?.popViewController(animated: true)
    }
}
