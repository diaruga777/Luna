//
//  PriceTrackerCardsViewController.swift
//  Luna
//

import LunaDesignSystem
import LunaHTMLClassification
import LunaModels
import LunaPriceUI
import LunaReadingList
import LunaSocial
import LunaStorage
import LunaURLClassification
import UIKit

/// Luna Price Tracker's root deck: the shared `CardCarouselHostViewController`
/// with product cards in it. Only the kind is different, so only the kind is
/// here — the deck's ordering and filtering, its cards, its menu, its archive
/// tray rows, and its share verb.
final class PriceTrackerCardsViewController: CardCarouselHostViewController {

    private let store = ReadingListStore.shared

    private var items: [ReadingListItem] = []
    private var archivedItems: [ReadingListItem] = []
    /// What `deckPreparedSnapshot` computed, waiting for the host to say the
    /// reload is going ahead.
    private var preparedItems: [ReadingListItem] = []
    private var preparedArchivedItems: [ReadingListItem] = []

    override var deckProvider: CardDeckProviding? { self }

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
        mountDeck()
    }

    // MARK: - Store

    @objc private func priceTrackerSaved(_ notification: Notification) {
        if let id = notification.userInfo?["itemID"] as? UUID {
            requestCentering(onSlotID: id)
        }
        reload()
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
            // "none" is a real state: a tracker with no alert threshold at all.
            tracker.alertThresholdFraction.map(String.init) ?? "none",
            String(tracker.isArchived),
            stores,
        ].joined(separator: "|")
    }

    private func setArchived(_ archived: Bool, itemID: UUID) {
        guard var tracker = store.item(withID: itemID)?.priceTracker else { return }
        tracker.isArchived = archived
        if !archived { requestCentering(onSlotID: itemID) }
        store.updatePriceTracker(tracker, for: itemID)
    }

    // MARK: - Sharing

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
}

// MARK: - The product kind

extension PriceTrackerCardsViewController: CardDeckProviding {

    func deckWillBeginObservingStores() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(priceTrackerSaved(_:)),
            name: .priceTrackerSavedInteractively, object: nil)
    }

    func deckPreparedSnapshot() -> CardDeckSnapshot {
        let trackers = store.items().filter { $0.priceTracker != nil }
        preparedItems = trackers.filter { $0.priceTracker?.isArchived == false }
            .sorted(by: Self.newestFirst)
        preparedArchivedItems = trackers.filter { $0.priceTracker?.isArchived == true }
            .sorted(by: Self.newestFirst)
        return CardDeckSnapshot(
            slots: preparedItems.map {
                CardDeckSlot(
                    id: $0.id, urlString: $0.urlString, fingerprint: Self.fingerprint($0))
            },
            offstageIDs: Set(preparedArchivedItems.map(\.id)),
            offstageFingerprint: preparedArchivedItems.map(Self.fingerprint))
    }

    func deckCommitPreparedSnapshot() {
        items = preparedItems
        archivedItems = preparedArchivedItems
    }

    func deckContentController(forSlot slot: Int) -> CardContentViewController {
        PriceTrackerCardContentViewController(itemID: items[slot].id)
    }

    func deckLoadThumbnail(forSlot slot: Int, completion: @escaping (UIImage?) -> Void) {
        PriceTrackerProductImage.load(
            imageFileName: items[slot].priceTracker?.imageFileName
        ) { completion($0 ?? PriceTrackerProductImage.fallback) }
    }

    func deckTitle(forSlot slot: Int) -> String? {
        items[slot].priceTracker?.productName
    }

    func deckLoadSourceBadge(
        forSlot slot: Int, completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(.symbol("tag.fill"))
    }

    func deckPrefersThumbnailChip(forSlot slot: Int) -> Bool { true }

    func deckLoadMiniCarouselAccessory(
        forSlot slot: Int, completion: @escaping (UIImage?) -> Void
    ) {
        completion(PriceTrackerTagIcon.image(size: 22))
    }

    /// Arriving at an alerting tracker is how its alert is acknowledged, so it
    /// stops floating above the other cards' ordering.
    func deckSlotDidCenter(_ slot: Int) {
        guard var tracker = items[slot].priceTracker, tracker.hasUnviewedAlert else { return }
        tracker.markAlertViewed()
        store.updatePriceTracker(tracker, for: items[slot].id)
    }

    func deckMenu(forSlot slot: Int) -> UIMenu? {
        let item = items[slot]
        let weekly = WeeklyPromotionMenu.action(for: item, presenter: self)
        return UIMenu(children: [
            UIAction(
                title: L10n.string("Share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in
                guard let self else { return }
                self.share(
                    item,
                    sourceView: self.carousel.cardView(
                        at: self.carouselIndex(forSlot: slot)) ?? self.view)
            },
        ] + [weekly].compactMap { $0 } + [
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

    func deckArchiveTrayItems() -> [ArchiveTrayItem] {
        archivedItems.compactMap { item in
            guard let tracker = item.priceTracker else { return nil }
            return ArchiveTrayItem(
                id: item.id,
                title: tracker.productName,
                footer: PriceFormatting.string(
                    amount: tracker.currentBestPrice, currency: tracker.displayCurrency),
                showsMetadata: true,
                isAvailable: true,
                loadImage: { completion in
                    PriceTrackerProductImage.load(
                        imageFileName: tracker.imageFileName
                    ) { completion($0 ?? PriceTrackerProductImage.fallback) }
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

    /// The pill greys out on the util card rather than vanishing: it is a fixture
    /// of this deck's chrome, and a gap beside the scrub strip reads as a fault.
    var deckShareButton: CardDeckShareButton? {
        CardDeckShareButton(
            accessibilityLabel: L10n.string("Share Current Product"),
            unavailability: .disables)
    }

    func deckShare(slot: Int, sourceView: UIView) {
        share(items[slot], sourceView: sourceView)
    }
}

/// One product image loader, for the deck's chip and archive artwork and for the
/// card's own header — the same file, the same tag-glyph fallback, one place.
/// The completion runs on the calling queue when the answer is immediate (there
/// is no picture) and on a background queue when a file had to be decoded.
enum PriceTrackerProductImage {
    /// The tag glyph that stands in for a product with no picture of its own.
    static var fallback: UIImage { PriceTrackerTagIcon.image(size: 52) }

    static func load(imageFileName: String?, completion: @escaping (UIImage?) -> Void) {
        guard let imageFileName else {
            completion(nil)
            return
        }
        let path = ReadingListStore.shared.articlesDirectory
            .appendingPathComponent(imageFileName).path
        DispatchQueue.global(qos: .userInitiated).async {
            completion(UIImage(contentsOfFile: path)?.preparingForDisplay())
        }
    }
}

/// One product card: image/title, graph with the threshold editor (or, for a
/// tracker with no alert yet, the graph's "Set price alert" pill), then its
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
        // Keeps the shared notification-permission latch honest — it decides whether
        // the NEXT tracked product starts with an alert threshold at all.
        NotificationManager.refreshAuthorizationRequestedStateInBackground()

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
        thumbnailView.accessibilityIdentifier = UtilCardSaveTransitionAnchor.thumbnail
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

        titleLabel.accessibilityIdentifier = UtilCardSaveTransitionAnchor.title
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
<<<<<<< HEAD
            // Setting the line is the request for a price-drop alert, and the only
            // moment this app has anything to notify about — launch doesn't ask (see
            // `AppDelegate`). No-op after the first commit answers the prompt.
            NotificationManager.requestAuthorization()
=======
            // The opt-in moment: an alert the user just set is the first thing this
            // app has to notify them about. Idempotent (see NotificationManager).
            NotificationManager.requestAuthorization()
        }
        // A tracker saved before the user was ever asked about notifications has no
        // threshold and so no line to drag: the graph offers "Set price alert"
        // instead, and this is where that default alert — and the permission prompt
        // that makes it deliverable — comes from.
        graphView.onThresholdRequested = { [weak self] in
            guard let self, var tracker = self.tracker else { return }
            tracker.setAlertThresholdFraction(PriceTracker.defaultAlertThresholdFraction)
            self.store.updatePriceTracker(tracker, for: self.itemID)
            NotificationManager.requestAuthorization()
            self.reloadContent()
>>>>>>> worktree-agent-a1a881b4510b4bace
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

    /// The deck's chips and this header draw the same picture, so they load it
    /// the same way. The card is the one that also has to say HOW: a real
    /// photograph fills its frame, the tag glyph is centred in it.
    private func loadThumbnail(_ tracker: PriceTracker) {
        PriceTrackerProductImage.load(imageFileName: tracker.imageFileName) { [weak self] loaded in
            let apply = {
                self?.thumbnailView.contentMode = loaded == nil ? .center : .scaleAspectFill
                self?.thumbnailView.image = loaded ?? PriceTrackerProductImage.fallback
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
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
