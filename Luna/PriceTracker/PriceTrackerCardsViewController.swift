//
//  PriceTrackerCardsViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaHTMLClassification
import LunaModels
import LunaPriceUI
import LunaReadingList
import LunaStorage
import LunaURLClassification
import UIKit

/// Luna Price Tracker's root deck. It deliberately uses the same carousel,
/// miniature carousel, and mirrored arc trays as Reader and Downloader; only
/// the card's content model differs.
final class PriceTrackerCardsViewController: CardCarouselHostViewController {

    private let store = ReadingListStore.shared
    private let emptyView = CardCarouselHostViewController.makeEmptyStateView(
        symbol: "tag",
        title: L10n.string("No Tracked Products"),
        subtitle: L10n.string("Paste or share a product page to start tracking its price."))
    private let settingsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    private var items: [ReadingListItem] = []
    private var archivedItems: [ReadingListItem] = []
    private var appliedFingerprint: [String] = []
    private var hasAppliedSnapshot = false
    private var pendingCenteredID: UUID?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background
        carousel.chromeBackdrop = StarfieldView.install(behindContentsOf: view)

        var style = CardCarouselStyle()
        style.edgeGap = 10
        style.cardFit = .fill
        style.pagesOnInCardSwipes = true
        style.pageSwipeMovementMultiplier = 1.5
        style.scrubberStyle = .miniCards
        style.scrubberHorizontalInset = 56
        style.scrubberEdgeFadeWidth = 28
        style.showsCardBorder = true
        carousel.style = style
        carousel.dataSource = self
        carousel.delegate = self
        mountCarousel()

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        emptyView.isHidden = true
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureBottomButton(
            settingsButton, symbol: "gearshape", action: #selector(settingsTapped),
            accessibilityLabel: L10n.string("Settings"))
        configureBottomButton(
            shareButton, symbol: "square.and.arrow.up", action: #selector(shareCurrent),
            accessibilityLabel: L10n.string("Share Current Product"))
        mountBottomControls(leading: settingsButton, trailing: shareButton)

        mountArchiveTray(
            shifting: { [weak self] in
                guard let self else { return [] }
                return [self.carousel.view, self.emptyView]
            },
            canPull: { [weak self] in
                guard let self else { return false }
                return self.items.isEmpty || self.carousel.currentIndex == self.items.count - 1
            })
        mountLeftTray(
            shifting: { [weak self] in
                guard let self else { return [] }
                return [self.carousel.view, self.emptyView]
            },
            canPull: { [weak self] in
                guard let self else { return false }
                return self.items.isEmpty || self.carousel.currentIndex == 0
            },
            savedURL: { [weak self] url, source, sourceView in
                self?.saveLeftTrayURL(url, source: source, sourceView: sourceView)
            })

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(priceTrackerSaved(_:)),
            name: .priceTrackerSavedInteractively, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        reload()
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

    // MARK: - Store

    @objc private func priceTrackerSaved(_ notification: Notification) {
        pendingCenteredID = notification.userInfo?["itemID"] as? UUID
        reload()
    }

    @objc private func reload() {
        let trackers = store.items().filter { $0.priceTracker != nil }
        let active = trackers.filter { $0.priceTracker?.isArchived == false }
            .sorted(by: Self.newestFirst)
        let archived = trackers.filter { $0.priceTracker?.isArchived == true }
            .sorted(by: Self.newestFirst)
        let fingerprint = (active + archived).map(Self.fingerprint)
        guard !hasAppliedSnapshot || fingerprint != appliedFingerprint || pendingCenteredID != nil
        else { return }
        hasAppliedSnapshot = true
        appliedFingerprint = fingerprint

        let oldCenteredID = items.indices.contains(carousel.currentIndex)
            ? items[carousel.currentIndex].id : nil
        items = active
        archivedItems = archived
        let centeredID = pendingCenteredID ?? oldCenteredID
        pendingCenteredID = nil
        // A tracker saved since the last snapshot — here, in a sibling app, or
        // through an extension while this one was away — takes the center.
        let newSaveIndex = newSaveItemIndex(
            cardIDs: items.map(\.id), offstageIDs: Set(archivedItems.map(\.id)))
        let centeredIndex = newSaveIndex
            ?? centeredID.flatMap { id in items.firstIndex { $0.id == id } }
            ?? min(carousel.currentIndex, max(items.count - 1, 0))

        carousel.reloadData(centeringAt: centeredIndex)
        if let pendingURL = pendingLeftTraySaveURLString,
           let index = items.firstIndex(where: { $0.urlString == pendingURL }) {
            prepareLeftTraySaveDestination(carousel.cardView(at: index))
        }
        emptyView.isHidden = !items.isEmpty
        carousel.view.isHidden = items.isEmpty
        archiveTray?.setItems(makeArchiveTrayItems())
        refreshArchivePullAvailability(animated: false)
        refreshLeftPullAvailability(animated: false)
        updateShareButton()
    }

    private static func newestFirst(_ lhs: ReadingListItem, _ rhs: ReadingListItem) -> Bool {
        let left = lhs.bumpDate ?? lhs.dateAdded
        let right = rhs.bumpDate ?? rhs.dateAdded
        if left != right { return left > right }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func fingerprint(_ item: ReadingListItem) -> String {
        guard let tracker = item.priceTracker else { return item.id.uuidString }
        let stores = tracker.stores.map {
            "\($0.urlString)|\($0.lastPrice.map(String.init(describing:)) ?? "")|\($0.priceHistory.count)"
        }.joined(separator: ";")
        return [
            item.id.uuidString,
            tracker.productName,
            tracker.imageFileName ?? "",
            String(tracker.alertThresholdFraction),
            String(tracker.isArchived),
            stores,
        ].joined(separator: "|")
    }

    private func saveLeftTrayURL(
        _ urlString: String, source: CaptureSource, sourceView: UIView
    ) {
        beginLeftTraySaveTransition(for: urlString, from: sourceView)
        Task { @MainActor [weak self] in
            let result = await ReadingListIngestor.shared.handleSavePress(
                urlString: urlString, source: source)
            guard let self else { return }
            let item: ReadingListItem?
            switch result {
            case .saved(let value), .sentToEreaders(let value),
                 .sentToFriends(let value), .friendPromptRequested(let value),
                 // In-app saves pass no double-save surface, so no export is
                 // ever requested here — the item is what matters either way.
                 .exportRequested(let value, _):
                item = value
            case .ignored:
                item = self.store.item(forURLString: urlString)
            case .unsupportedKind:
                item = nil
            }
            guard let item else {
                self.cancelLeftTraySaveTransition()
                return
            }
            self.pendingCenteredID = item.id
            self.reload()
            self.view.layoutIfNeeded()
            let destinationIndex = self.items.firstIndex { $0.id == item.id }
            self.finishLeftTraySaveTransition(
                to: destinationIndex.flatMap(self.carousel.cardView(at:)))
        }
    }

    private func makeArchiveTrayItems() -> [ArchiveTrayItem] {
        archivedItems.compactMap { item in
            guard let tracker = item.priceTracker else { return nil }
            return ArchiveTrayItem(
                id: item.id,
                title: tracker.productName,
                footer: PriceFormatting.string(
                    amount: tracker.currentBestPrice, currency: tracker.displayCurrency),
                showsMetadata: true,
                isAvailable: true,
                loadImage: { [weak self] completion in
                    self?.loadProductImage(for: item, completion: completion)
                },
                tap: { [weak self] in
                    guard let self, let first = tracker.stores.first else { return }
                    InAppBrowser.present(urlString: first.urlString, from: self)
                },
                share: { [weak self] sourceView in
                    self?.share(item, sourceView: sourceView)
                },
                unarchive: { [weak self] _ in
                    self?.setArchived(false, itemID: item.id)
                },
                delete: { [weak self] in self?.store.delete(item) })
        }
    }

    private func setArchived(_ archived: Bool, itemID: UUID) {
        guard var tracker = store.item(withID: itemID)?.priceTracker else { return }
        tracker.isArchived = archived
        if !archived { pendingCenteredID = itemID }
        store.updatePriceTracker(tracker, for: itemID)
    }

    // MARK: - Sharing and images

    @objc private func shareCurrent() {
        guard items.indices.contains(carousel.currentIndex) else { return }
        share(
            items[carousel.currentIndex],
            sourceView: carousel.cardView(at: carousel.currentIndex) ?? shareButton)
    }

    private func share(_ item: ReadingListItem, sourceView: UIView) {
        guard let urlString = item.priceTracker?.stores.first?.urlString,
              let url = URL(string: urlString) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(sheet, animated: true)
    }

    private func updateShareButton() {
        shareButton.isEnabled = items.indices.contains(carousel.currentIndex)
    }

    private func loadProductImage(
        for item: ReadingListItem,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard let fileName = item.priceTracker?.imageFileName else {
            completion(PriceTrackerTagIcon.image(size: 52))
            return
        }
        let path = store.articlesDirectory.appendingPathComponent(fileName).path
        let fallback = PriceTrackerTagIcon.image(size: 52)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = UIImage(contentsOfFile: path)?.preparingForDisplay()
                ?? fallback
            completion(image)
        }
    }
}

// The launch splash crossfades from this deck's real resting card geometry.
extension PriceTrackerCardsViewController: AppLaunchTransitionTarget {
    func appLaunchTargetFrame(in window: UIWindow) -> CGRect? {
        view.layoutIfNeeded()
        guard let frame = carousel.restingCenteredCardFrame(in: view) else { return nil }
        return view.convert(frame, to: window)
    }
}

// MARK: - Carousel data source

extension PriceTrackerCardsViewController: CardCarouselDataSource {
    func numberOfCards(in carousel: CardCarouselViewController) -> Int {
        items.count
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        contentControllerForCardAt index: Int
    ) -> CardContentViewController {
        guard items.indices.contains(index) else { return CardContentViewController() }
        return PriceTrackerCardContentViewController(itemID: items[index].id)
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
        guard items.indices.contains(index) else { completion(nil); return }
        loadProductImage(for: items[index], completion: completion)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        titleForCardAt index: Int
    ) -> String? {
        items.indices.contains(index) ? items[index].priceTracker?.productName : nil
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadSourceBadgeForCardAt index: Int,
        completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(.symbol("tag.fill"))
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        prefersThumbnailChipForCardAt index: Int
    ) -> Bool {
        true
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        loadMiniCarouselAccessoryForCardAt index: Int,
        completion: @escaping (UIImage?) -> Void
    ) {
        completion(PriceTrackerTagIcon.image(size: 22))
    }
}

// MARK: - Carousel delegate

extension PriceTrackerCardsViewController: CardCarouselDelegate {
    func carousel(
        _ carousel: CardCarouselViewController,
        navigationTargetDidChangeTo index: Int
    ) {
        if index != 0 { leftTray?.setPullAvailable(false, animated: true) }
        updateArchivePullAvailability(
            forTargetIndex: index, cardCount: items.count, animated: true)
    }

    func carousel(_ carousel: CardCarouselViewController, didCenterCardAt index: Int) {
        refreshLeftPullAvailability(animated: true)
        refreshArchivePullAvailability(animated: true)
        updateShareButton()
        guard items.indices.contains(index), var tracker = items[index].priceTracker,
              tracker.hasUnviewedAlert else { return }
        tracker.markAlertViewed()
        store.updatePriceTracker(tracker, for: items[index].id)
    }

    func carousel(
        _ carousel: CardCarouselViewController,
        menuForCardAt index: Int
    ) -> UIMenu? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        return UIMenu(children: [
            UIAction(
                title: L10n.string("Share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in
                guard let self else { return }
                self.share(item, sourceView: carousel.cardView(at: index) ?? self.view)
            },
            UIAction(
                title: L10n.string("Archive"), image: UIImage(systemName: "archivebox")
            ) { [weak self] _ in
                self?.setArchived(true, itemID: item.id)
            },
            UIAction(
                title: L10n.string("Delete"), image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.store.delete(item) },
        ])
    }
}

/// One product card: image/title, graph with the threshold editor, then its
/// seller list and add button. It owns no archive timer or completion policy.
private final class PriceTrackerCardContentViewController: CardContentViewController {

    private let itemID: UUID
    private let store = ReadingListStore.shared
    private let priceFetcher: PriceFetching

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let thumbnailView = UIImageView()
    private let titleLabel = UILabel()
    private let graphView = PriceGraphView()
    private let storesStack = UIStackView()
    private let addButton = UIButton(type: .system)

    private var tracker: PriceTracker? {
        store.item(withID: itemID)?.priceTracker
    }

    init(itemID: UUID, priceFetcher: PriceFetching = PriceFetcher()) {
        self.itemID = itemID
        self.priceFetcher = priceFetcher
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.secondaryBackground

        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        configureHeader()
        configureGraph()
        configureStores()

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -22),
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -36),
        ])
        reloadContent()
    }

    private func configureHeader() {
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 12
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.backgroundColor = LunaColors.tertiaryFill
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 64),
            thumbnailView.heightAnchor.constraint(equalToConstant: 64),
        ])

        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = LunaColors.primaryText
        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail

        let header = UIStackView(arrangedSubviews: [thumbnailView, titleLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        contentStack.addArrangedSubview(header)
    }

    private func configureGraph() {
        let label = UILabel()
        label.text = L10n.string("Price History")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = LunaColors.secondaryText
        contentStack.addArrangedSubview(label)

        graphView.translatesAutoresizingMaskIntoConstraints = false
        graphView.heightAnchor.constraint(equalToConstant: 246).isActive = true
        graphView.onThresholdCommitted = { [weak self] price in
            guard let self, var tracker = self.tracker else { return }
            tracker.setAlertThresholdPrice(price)
            self.store.updatePriceTracker(tracker, for: self.itemID)
        }
        scrollView.panGestureRecognizer.require(
            toFail: graphView.thresholdDragGestureRecognizer)
        contentStack.addArrangedSubview(graphView)
    }

    private func configureStores() {
        let heading = UILabel()
        heading.text = L10n.string("Tracked Sites")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = LunaColors.secondaryText

        var addConfiguration = UIButton.Configuration.plain()
        addConfiguration.image = UIImage(systemName: "plus")
        addConfiguration.baseForegroundColor = LunaSurfacePalette.baseColor(for: .priceTracker)
        addConfiguration.contentInsets = .zero
        addButton.configuration = addConfiguration
        addButton.accessibilityLabel = L10n.string("Add tracked site")
        addButton.addTarget(self, action: #selector(addSellerTapped), for: .touchUpInside)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 38),
            addButton.heightAnchor.constraint(equalToConstant: 38),
        ])

        let headingRow = UIStackView(arrangedSubviews: [heading, UIView(), addButton])
        headingRow.axis = .horizontal
        headingRow.alignment = .center
        contentStack.addArrangedSubview(headingRow)

        storesStack.axis = .vertical
        storesStack.spacing = 8
        contentStack.addArrangedSubview(storesStack)
    }

    private func reloadContent() {
        guard let tracker else { return }
        titleLabel.text = tracker.productName
        loadThumbnail(tracker)
        graphView.setData(
            PriceHistory.series(for: tracker),
            currency: tracker.displayCurrency,
            thresholdPrice: tracker.alertThresholdPrice,
            baselinePrice: tracker.initialPrice,
            allowsThresholdEditing: true)
        rebuildStoreRows(tracker)
    }

    private func loadThumbnail(_ tracker: PriceTracker) {
        guard let fileName = tracker.imageFileName else {
            thumbnailView.image = PriceTrackerTagIcon.image(size: 52)
            thumbnailView.contentMode = .center
            return
        }
        let path = store.articlesDirectory.appendingPathComponent(fileName).path
        let fallback = PriceTrackerTagIcon.image(size: 52)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = UIImage(contentsOfFile: path)?.preparingForDisplay()
            DispatchQueue.main.async {
                self?.thumbnailView.contentMode = loaded == nil ? .center : .scaleAspectFill
                self?.thumbnailView.image = loaded ?? fallback
            }
        }
    }

    private func rebuildStoreRows(_ tracker: PriceTracker) {
        storesStack.arrangedSubviews.forEach {
            storesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for storeListing in tracker.stores {
            storesStack.addArrangedSubview(makeStoreRow(storeListing, canRemove: tracker.stores.count > 1))
        }
    }

    private func makeStoreRow(_ listing: PriceTrackerStore, canRemove: Bool) -> UIView {
        let open = UIButton(type: .system)
        var configuration = UIButton.Configuration.gray()
        configuration.title = listing.url?.host?.replacingOccurrences(of: "www.", with: "")
            ?? listing.urlString
        configuration.subtitle = listing.lastPrice.map {
            PriceFormatting.string(amount: $0, currency: listing.currency)
        } ?? L10n.string("Price unavailable")
        configuration.titleAlignment = .leading
        configuration.image = UIImage(systemName: "safari")
        configuration.imagePadding = 8
        configuration.baseForegroundColor = LunaColors.primaryText
        open.configuration = configuration
        open.contentHorizontalAlignment = .leading
        open.accessibilityHint = L10n.string("Opens this tracked site")
        open.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            InAppBrowser.present(urlString: listing.urlString, from: self)
        }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [open])
        row.axis = .horizontal
        row.spacing = 4
        if canRemove {
            let remove = UIButton(type: .system)
            var removeConfiguration = UIButton.Configuration.plain()
            removeConfiguration.image = UIImage(systemName: "minus.circle")
            removeConfiguration.baseForegroundColor = LunaColors.secondaryText
            remove.configuration = removeConfiguration
            remove.accessibilityLabel = L10n.string("Remove \(configuration.title ?? "site")")
            remove.addAction(UIAction { [weak self] _ in
                guard let self, var tracker = self.tracker,
                      tracker.removeStore(urlString: listing.urlString) else { return }
                self.store.updatePriceTracker(tracker, for: self.itemID)
                self.reloadContent()
            }, for: .touchUpInside)
            remove.widthAnchor.constraint(equalToConstant: 36).isActive = true
            row.addArrangedSubview(remove)
        }
        return row
    }

    @objc private func addSellerTapped() {
        guard let tracker else { return }
        let initialURL = ProductSearchURL.googleShoppingURL(forProductName: tracker.productName)
            ?? URL(string: "https://www.google.com")
        guard let initialURL else { return }
        let product = ProductInfo(
            name: tracker.productName,
            priceAmount: tracker.initialPrice,
            priceCurrency: tracker.initialCurrency,
            imageURL: nil,
            brand: tracker.brand,
            productID: tracker.productID)
        let sourcePoint = addButton.convert(
            CGPoint(x: addButton.bounds.midX, y: addButton.bounds.midY), to: nil)
        let overlay = ProductSearchOverlayViewController(
            initialURL: initialURL,
            trackedProduct: product,
            eclipseSourcePointInWindow: sourcePoint,
            eclipseSceneFrameInWindow: view.convert(view.bounds, to: nil))
        overlay.delegate = self
        present(overlay, animated: true)
    }
}

extension PriceTrackerCardContentViewController: ProductSearchOverlayDelegate {
    func productSearchOverlay(
        _ overlay: ProductSearchOverlayViewController,
        didConfirmPage urlString: String,
        html: String,
        completion: @escaping (ProductSearchAddOutcome) -> Void
    ) {
        guard let tracker else { return completion(.noPrice) }
        guard !tracker.hasStore(urlString: urlString) else { return completion(.duplicate) }
        Task { [weak self] in
            guard let self else { return }
            let price = await priceFetcher.fetchPrice(
                forURLString: urlString,
                prefetchedHTML: html.isEmpty ? nil : html)
            await MainActor.run {
                guard var current = self.tracker else { return completion(.noPrice) }
                guard !current.hasStore(urlString: urlString) else {
                    return completion(.duplicate)
                }
                guard let price else { return completion(.noPrice) }
                current.upsertStore(PriceTrackerStore(
                    urlString: urlString,
                    lastPrice: price.amount,
                    currency: price.currency,
                    lastRefreshed: Date()))
                self.store.updatePriceTracker(current, for: self.itemID)
                self.reloadContent()
                completion(.added)
            }
        }
    }
}

/// The tag silhouette from the Price Tracker app icon, intentionally without
/// the magnifying glass. It is rendered in the app's fixed green identity color.
private enum PriceTrackerTagIcon {
    static func image(size: CGFloat) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { context in
            let scale = size / 100
            context.cgContext.scaleBy(x: scale, y: scale)
            let tag = UIBezierPath()
            tag.move(to: CGPoint(x: 30, y: 7))
            tag.addCurve(
                to: CGPoint(x: 53, y: 5),
                controlPoint1: CGPoint(x: 37, y: 5),
                controlPoint2: CGPoint(x: 46, y: 5))
            tag.addCurve(
                to: CGPoint(x: 63, y: 10),
                controlPoint1: CGPoint(x: 57, y: 5),
                controlPoint2: CGPoint(x: 60, y: 7))
            tag.addLine(to: CGPoint(x: 94, y: 43))
            tag.addCurve(
                to: CGPoint(x: 94, y: 58),
                controlPoint1: CGPoint(x: 99, y: 48),
                controlPoint2: CGPoint(x: 99, y: 54))
            tag.addLine(to: CGPoint(x: 59, y: 94))
            tag.addCurve(
                to: CGPoint(x: 44, y: 95),
                controlPoint1: CGPoint(x: 54, y: 99),
                controlPoint2: CGPoint(x: 49, y: 99))
            tag.addLine(to: CGPoint(x: 7, y: 61))
            tag.addCurve(
                to: CGPoint(x: 5, y: 49),
                controlPoint1: CGPoint(x: 3, y: 57),
                controlPoint2: CGPoint(x: 3, y: 53))
            tag.addLine(to: CGPoint(x: 9, y: 20))
            tag.addCurve(
                to: CGPoint(x: 30, y: 7),
                controlPoint1: CGPoint(x: 10, y: 12),
                controlPoint2: CGPoint(x: 18, y: 7))
            tag.close()
            tag.append(UIBezierPath(ovalIn: CGRect(x: 18, y: 18, width: 13, height: 13)))
            tag.usesEvenOddFillRule = true
            LunaSurfacePalette.baseColor(for: .priceTracker).setFill()
            tag.fill()
        }
    }
}
