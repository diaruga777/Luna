//
//  PhotoSearchGridViewController.swift
//  clipper
//

import Photos
import UIKit

/// The main Photo Search screen: a search field over a chronological photo grid.
/// Typing filters the grid live (per keystroke, debounced); a blank query shows
/// photos newest-first. Tapping the toolbar button opens the model/index screen.
@MainActor
final class PhotoSearchGridViewController: UIViewController {

    private let context: PhotoSearchContext
    private let imageManager = PHCachingImageManager()

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let searchBar = UISearchBar()
    private let emptyStateLabel = UILabel()

    /// All image assets keyed by local identifier, for thumbnail rendering.
    private var assetsByID: [String: PHAsset] = [:]
    private var engine: CLIPEmbeddingEngine?

    private var searchTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    /// Square thumbnail pixel size (one grid cell, at screen scale). Slightly
    /// oversampled so the downscaled result stays crisp. A single consistent size
    /// lets PHCachingImageManager serve cache hits on reorder/scroll.
    private let thumbnailSize: CGSize = {
        let side = ceil(UIScreen.main.bounds.width / 3 * UIScreen.main.scale * 1.25)
        return CGSize(width: side, height: side)
    }()

    /// Shared options for both prefetch caching and per-cell requests so they hit
    /// the same cache. `.opportunistic` paints a quick low-res thumbnail and then
    /// upgrades to a sharp full-resolution one (so images don't stay blurry);
    /// `.exact` sizing keeps them crisp at the cell's resolution.
    private let imageOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return options
    }()

    /// Opens the model/index setup screen.
    var onOpenSetup: (() -> Void)?

    /// Opens the Applets list.
    var onOpenApplets: (() -> Void)?

    init(context: PhotoSearchContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Photos"
        view.backgroundColor = .systemBackground
        engine = context.makeEngine()

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "slider.horizontal.3"),
            style: .plain,
            target: self,
            action: #selector(openSetup)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "wand.and.stars"),
            style: .plain,
            target: self,
            action: #selector(openApplets)
        )

        configureSearch()
        configureCollectionView()
        configureEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAssetsAndIndex()
    }

    // MARK: - Setup

    private func configureSearch() {
        // An always-visible search bar pinned below the nav bar; `textDidChange`
        // fires on every keystroke so the grid filters live as you type.
        searchBar.delegate = self
        searchBar.placeholder = "Search your photos"
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.searchBarStyle = .minimal
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0 / 3.0),
                    heightDimension: .fractionalHeight(1.0)
                )
            )
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .fractionalWidth(1.0 / 3.0)
                ),
                subitems: [item]
            )
            return NSCollectionLayoutSection(group: group)
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(PhotoGridCell.self, forCellWithReuseIdentifier: PhotoGridCell.reuseID)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, identifier in
            let dequeued = collectionView.dequeueReusableCell(
                withReuseIdentifier: PhotoGridCell.reuseID, for: indexPath
            )
            guard let cell = dequeued as? PhotoGridCell, let self else { return dequeued }
            if let asset = self.assetsByID[identifier] {
                cell.configure(asset: asset, imageManager: self.imageManager, targetSize: self.thumbnailSize, options: self.imageOptions)
            }
            return cell
        }
    }

    /// Resolves the assets for a set of result identifiers (for prefetch caching).
    private func assets(for identifiers: [String]) -> [PHAsset] {
        identifiers.compactMap { assetsByID[$0] }
    }

    private func configureEmptyState() {
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.font = .preferredFont(forTextStyle: .body)
        emptyStateLabel.text = "No indexed photos yet.\nTap the slider button to choose a model and index your library."
        emptyStateLabel.isHidden = true
        view.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Data

    private func reloadAssetsAndIndex() {
        reloadTask?.cancel()
        reloadTask = Task {
            let hasIndex = await context.loadIndexIntoService()
            if Task.isCancelled { return }
            // Runs on the main actor (UIViewController is @MainActor): assigning
            // engine/assetsByID here is race-free with the data source reads.
            engine = context.makeEngine()
            buildAssetMap()
            emptyStateLabel.isHidden = hasIndex
            // Re-issue the *current* query rather than applying a blank result,
            // so a refresh can't clobber an in-progress search.
            runSearch(query: searchBar.text ?? "")
        }
    }

    private func buildAssetMap() {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var map: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = asset
        }
        assetsByID = map
    }

    private func applyResults(_ identifiers: [String]) {
        let renderable = identifiers.filter { assetsByID[$0] != nil }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(renderable, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)

        // Prewarm thumbnails for the first screenful so results paint instantly,
        // and reset caching to the new result set.
        imageManager.stopCachingImagesForAllAssets()
        let prewarm = assets(for: Array(renderable.prefix(30)))
        imageManager.startCachingImages(for: prewarm, targetSize: thumbnailSize, contentMode: .aspectFill, options: imageOptions)
    }

    // MARK: - Search

    private func runSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = self.engine

        searchTask = Task {
            // Short debounce so a burst of keystrokes coalesces, but results still
            // feel instant. Cached query embeddings make repeats effectively free.
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }

            var embedding: [Float]?
            if !trimmed.isEmpty, let engine {
                do {
                    embedding = try await engine.textEmbedding(for: trimmed)
                } catch {
                    // Fall back to OCR-only ranking, but don't hide the failure.
                    context.logger.error("Text embedding failed for query '\(trimmed)': \(error)")
                }
            }
            if Task.isCancelled { return }

            let results = await context.searchService.search(query: trimmed, queryEmbedding: embedding)
            if Task.isCancelled { return }
            applyResults(results)
        }
    }

    @objc private func openSetup() {
        onOpenSetup?()
    }

    @objc private func openApplets() {
        onOpenApplets?()
    }
}

// MARK: - Search updating

extension PhotoSearchGridViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        runSearch(query: searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - Collection delegate (prefetch caching)

extension PhotoSearchGridViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard
            let identifier = dataSource.itemIdentifier(for: indexPath),
            let asset = assetsByID[identifier]
        else {
            return
        }
        presentPreview(for: asset)
    }

    private func presentPreview(for asset: PHAsset) {
        let preview = PhotoPreviewViewController(asset: asset, imageManager: imageManager)
        navigationController?.pushViewController(preview, animated: true)
    }
}

// MARK: - Prefetching (warm thumbnails ahead of display)

extension PhotoSearchGridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { assetsByID[$0] }
        imageManager.startCachingImages(for: assets, targetSize: thumbnailSize, contentMode: .aspectFill, options: imageOptions)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { assetsByID[$0] }
        imageManager.stopCachingImages(for: assets, targetSize: thumbnailSize, contentMode: .aspectFill, options: imageOptions)
    }
}
