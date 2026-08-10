//
//  ProductDetailViewController.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaHTMLClassification
import LunaModels
import LunaSocial
import LunaStorage
import LunaURLClassification
import UIKit

/// A price resolved by the URL-rescue engine (`claudedocs/url-rescue.md`), and
/// the seam the main app installs it through.
///
/// It is a free-standing enum rather than a static on a screen because BOTH
/// product surfaces are that screen now, and the app's `KindWiring` should not
/// have to know which class happens to host the add-seller flow this week.
public enum ProductPriceRescue {

    public struct ResolvedPrice {
        public let amount: Decimal
        public let currency: String
        public init(amount: Decimal, currency: String) {
            self.amount = amount
            self.currency = currency
        }
    }

    /// The main app's "Ask Apple Intelligence to find the price" behavior for a
    /// no-price page, installed once at launch (nil in extensions → the offer is
    /// not made and behavior is unchanged).
    public static var resolver: ((String) async -> ResolvedPrice?)?
}

/// **The** product surface: the product, its price history, its alert, and the
/// sellers being watched — one screen, used by every app and every surface that
/// shows a tracked product.
///
/// It exists because there were two of these and they disagreed about
/// everything. The in-deck card scrolled a column of a `title3` product title, a
/// 246pt graph and grey seller buttons captioned with a Safari compass; the
/// share/action extension's editor showed the same tracker as a grouped
/// `UITableView` of hostnames with a 130pt alert pill bolted to the bottom. A
/// seller row was a different height, a different label and a different tap
/// target depending on which one you were looking at, and a fix to either was a
/// fix to one.
///
/// So the hosts keep only what is genuinely theirs — the card frame on one side,
/// the header bar and the extension's exit button on the other — and everything
/// between the two is this:
///
/// ```
/// ┌──────────────────────────────────────────┐
/// │ [img]  Panasonic shaver      $116.33     │  header: the short name, the
/// │        Panasonic spare blade men's…      │  full title small underneath,
/// │                                          │  and what it costs today
/// │ Sellers                              +   │
/// │ ╭────────────────────────────────────╮   │  a scroll viewport measured in
/// │ │ 🅰 Amazon Australia       $116.33   │   │  whole rows plus a peek, so the
/// │ │ 🅹 JB Hi-Fi              $119.00   │   │  list looks scrollable when it
/// │ ╰┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈╯   │  is
/// │ ╭────────────────────────────────────╮   │
/// │ │  price history + the alert line    │   │  graph: a share of the height,
/// │ ╰────────────────────────────────────╯   │  never a fixed 246pt
/// │ ╭────────────────────────────────────╮   │
/// │ │ 🔔 Alert at  $104.70  ──o────────  │   │  one 46pt row, both states
/// │ ╰────────────────────────────────────╯   │
/// └──────────────────────────────────────────┘
/// ```
///
/// The bands are laid out against the container's own height rather than in a
/// scroll view: on a card there is nowhere to scroll TO, and a seller list that
/// scrolls inside a column that also scrolls is a gesture argument. Only the
/// seller list scrolls, which is the only band whose length the product decides.
public final class ProductDetailViewController: UIViewController {

    private let itemID: UUID
    private let store = ReadingListStore.shared
    private let priceFetcher: PriceFetching
    /// Non-nil only in an extension. The add button hands the item back to the
    /// containing app instead of trying to keep a web session alive in an appex.
    private let openContainingAppForAddSeller: ((UUID) -> Void)?
    /// A just-merged seller URL to flash, or nil.
    private let highlightedURLString: String?

    private let thumbnailView = UIImageView()
    private let headlineLabel = UILabel()
    private let detailLabel = UILabel()
    private let priceLabel = UILabel()
    private let changeLabel = UILabel()
    private let graphView = PriceGraphView()
    private let alertRow = AlertThresholdRow()
    private let sellersHeadingLabel = UILabel()
    private let addSellerButton = UIButton(type: .system)
    private let sellersScrollView = UIScrollView()
    private let sellersStack = UIStackView()
    private let bandStack = UIStackView()
    /// The graph's ceiling — lowered while the tracker has no history to draw.
    private var graphCeiling: NSLayoutConstraint?
    /// The seller list's bottom fade: the standing cue that there are more
    /// retailers below. A scroll indicator only says so while a finger is down,
    /// and the row the viewport cuts can land anywhere, including flush.
    private let sellersFade = CAGradientLayer()
    private var pendingDeepLinkedSellerSearch = false

    private var tracker: PriceTracker? { store.item(withID: itemID)?.priceTracker }

    /// Identifiers the card-save transition anchors on. Set by the card host;
    /// the extension leaves them nil (nothing there is transitioning from a
    /// util-card save).
    public var thumbnailTransitionIdentifier: String? {
        didSet { thumbnailView.accessibilityIdentifier = thumbnailTransitionIdentifier }
    }

    public var titleTransitionIdentifier: String? {
        didSet { headlineLabel.accessibilityIdentifier = titleTransitionIdentifier }
    }

    public init(
        itemID: UUID,
        priceFetcher: PriceFetching = PriceFetcher(),
        highlightedURLString: String? = nil,
        openContainingAppForAddSeller: ((UUID) -> Void)? = nil
    ) {
        self.itemID = itemID
        self.priceFetcher = priceFetcher
        self.highlightedURLString = highlightedURLString
        self.openContainingAppForAddSeller = openContainingAppForAddSeller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    /// The graph's share of the surface. A fraction rather than a constant
    /// because the two hosts are different sizes — a 9:16 card and a full share
    /// sheet — and the chart was tuned for neither: 246pt of a card is a third
    /// of it, and 168pt of a share sheet is a strip.
    static let graphHeightFraction: CGFloat = 0.30
    static let graphMinimumHeight: CGFloat = 132
    static let graphMaximumHeight: CGFloat = 260
    /// …and its ceiling before there is anything to plot. A brand-new tracker
    /// has one price and no history, and a 260pt box saying "No price history
    /// yet" is the largest thing on a screen with the least in it.
    static let emptyGraphMaximumHeight: CGFloat = 168

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        sellersFade.colors = [
            UIColor.white.cgColor, UIColor.white.cgColor,
            UIColor.white.withAlphaComponent(0.05).cgColor,
        ]
        sellersFade.startPoint = CGPoint(x: 0.5, y: 0)
        sellersFade.endPoint = CGPoint(x: 0.5, y: 1)

        bandStack.axis = .vertical
        bandStack.spacing = 12
        bandStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bandStack)

        bandStack.addArrangedSubview(makeHeader())
        bandStack.addArrangedSubview(makeSellersHeading())
        bandStack.addArrangedSubview(makeSellersViewport())
        bandStack.addArrangedSubview(makeGraphBand())
        bandStack.addArrangedSubview(alertRow)

        configureAlertRow()
        installGraphHeightRatio()

        NSLayoutConstraint.activate([
            bandStack.topAnchor.constraint(equalTo: view.topAnchor),
            bandStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bandStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bandStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Keeps the shared notification-permission latch honest — it decides
        // whether the NEXT tracked product starts with an alert threshold at all.
        NotificationManager.refreshAuthorizationRequestedStateInBackground()
        // A save-time seller fan-out lands its retailers one at a time, from a
        // background task, straight into the store — so this has to hear about a
        // change it did not make.
        NotificationCenter.default.addObserver(
            self, selector: #selector(readingListChanged), name: .readingListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(addSellerDeepLinkReceived(_:)),
            name: .priceTrackerAddSellerRequested, object: nil)
        if PriceTrackerAddSellerRoute.consume(ifMatching: itemID) {
            pendingDeepLinkedSellerSearch = true
        }
        reload()
    }

    private func makeHeader() -> UIView {
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 11
        thumbnailView.layer.cornerCurve = .continuous
        thumbnailView.backgroundColor = LunaColors.tertiaryFill
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        headlineLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        headlineLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.textColor = LunaColors.primaryText
        headlineLabel.numberOfLines = 1
        headlineLabel.lineBreakMode = .byTruncatingTail
        // A short product name that is still a hair too wide for the room left
        // beside the price shrinks rather than losing its last word — three
        // words is already the short form.
        headlineLabel.adjustsFontSizeToFitWidth = true
        headlineLabel.minimumScaleFactor = 0.8

        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = LunaColors.tertiaryText
        detailLabel.numberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail

        priceLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        priceLabel.textColor = LunaColors.primaryText
        priceLabel.textAlignment = .right
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        changeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        changeLabel.textColor = LunaSurfacePalette.baseColor(for: .priceTracker)
        changeLabel.textAlignment = .right
        changeLabel.setContentHuggingPriority(.required, for: .horizontal)

        // A label's default vertical hugging is 250, which inside a filling
        // stack means "stretch me before you stretch anything with an opinion".
        // Every label in the header has an opinion: it is exactly as tall as its
        // text, and the slack belongs to the graph.
        for label in [headlineLabel, detailLabel, priceLabel, changeLabel] {
            label.setContentHuggingPriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let titles = UIStackView(arrangedSubviews: [headlineLabel, detailLabel])
        titles.axis = .vertical
        titles.spacing = 2

        let prices = UIStackView(arrangedSubviews: [priceLabel, changeLabel])
        prices.axis = .vertical
        prices.alignment = .trailing
        prices.spacing = 1

        let header = UIStackView(arrangedSubviews: [thumbnailView, titles, prices])
        header.accessibilityIdentifier = "priceTracker.header"
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 11
        // Only two bands may take spare height — the graph, then the seller
        // list. Everything else states that it wants exactly its own, or the
        // stack distributes the slack into the gaps between the header's rows.
        //
        // A UIStackView has no intrinsic height of its own, so hugging cannot
        // hold this band down inside a filling stack — it has to be TOLD what
        // it is worth. The titles column is a vertical stack of labels, whose
        // height IS determined by its content, so the header is exactly that
        // tall, and never shorter than the picture beside it.
        let natural = header.heightAnchor.constraint(equalTo: titles.heightAnchor)
        natural.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 46),
            thumbnailView.heightAnchor.constraint(equalToConstant: 46),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            natural,
        ])
        return header
    }

    private func makeGraphBand() -> UIView {
        graphView.translatesAutoresizingMaskIntoConstraints = false
        graphView.accessibilityIdentifier = "priceTracker.graph"
        // The graph is the band that takes the slack: a tracker with two sellers
        // leaves room a list cannot use, and a taller chart is the best thing to
        // spend it on. Hugging it loosely is what makes the stack grow this one
        // first, up to its cap; only then does the seller list stretch.
        graphView.setContentHuggingPriority(UILayoutPriority(100), for: .vertical)
        let ceiling = graphView.heightAnchor.constraint(
            lessThanOrEqualToConstant: Self.graphMaximumHeight)
        graphCeiling = ceiling
        NSLayoutConstraint.activate([
            graphView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: Self.graphMinimumHeight),
            ceiling,
        ])
        return graphView
    }

    /// The graph's preferred share of the surface, activated once the band is IN
    /// the hierarchy — a ratio against the container is not expressible until
    /// the two views have an ancestor in common.
    private func installGraphHeightRatio() {
        let preferred = graphView.heightAnchor.constraint(
            equalTo: view.heightAnchor, multiplier: Self.graphHeightFraction)
        preferred.priority = .defaultHigh
        preferred.isActive = true
    }

    private func configureAlertRow() {
        alertRow.onChanged = { [weak self] fraction in
            guard let self, let tracker = self.tracker, tracker.initialPrice > 0 else { return }
            self.graphView.setThresholdPrice(tracker.initialPrice * (1 - Decimal(fraction)))
        }
        alertRow.onCommitted = { [weak self] fraction in
            self?.commitThreshold(fraction: fraction)
        }
    }

    private func makeSellersHeading() -> UIView {
        sellersHeadingLabel.text = L10n.string("PriceTracker_tracking_sellersHeaderTitle")
        sellersHeadingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sellersHeadingLabel.textColor = LunaColors.secondaryText

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        configuration.baseForegroundColor = LunaSurfacePalette.baseColor(for: .priceTracker)
        configuration.contentInsets = .zero
        addSellerButton.configuration = configuration
        addSellerButton.accessibilityLabel = L10n.string(
            "PriceTracker_tracking_addSellerButtonLabel")
        if openContainingAppForAddSeller != nil {
            addSellerButton.showsMenuAsPrimaryAction = false
            addSellerButton.addTarget(
                self, action: #selector(openContainingAppForSellerSearch), for: .touchUpInside)
        } else {
            addSellerButton.showsMenuAsPrimaryAction = true
            addSellerButton.menu = addSellerMenu()
        }
        addSellerButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addSellerButton.widthAnchor.constraint(equalToConstant: 32),
            addSellerButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        let row = UIStackView(arrangedSubviews: [sellersHeadingLabel, UIView(), addSellerButton])
        row.accessibilityIdentifier = "priceTracker.sellersHeading"
        row.axis = .horizontal
        row.alignment = .center
        // Told, not hugged — see the header. This band is the label and the
        // add button, and it is 26pt tall in every state.
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return row
    }

    private func makeSellersViewport() -> UIView {
        sellersScrollView.accessibilityIdentifier = "priceTracker.sellers"
        sellersScrollView.showsVerticalScrollIndicator = true
        sellersScrollView.alwaysBounceVertical = false
        sellersScrollView.delegate = self
        sellersScrollView.translatesAutoresizingMaskIntoConstraints = false

        sellersStack.axis = .vertical
        sellersStack.spacing = 6
        sellersStack.translatesAutoresizingMaskIntoConstraints = false
        sellersScrollView.addSubview(sellersStack)

        // The viewport is exactly as tall as its rows, until they no longer fit —
        // then it stops at whatever is left and scrolls. That is the fix for a
        // list that used to be cut off just past its first row with nothing to
        // say it continued: the cut now lands mid-row, because the height is a
        // remainder rather than a guess.
        let fitsContent = sellersScrollView.heightAnchor.constraint(
            equalTo: sellersStack.heightAnchor)
        fitsContent.priority = UILayoutPriority(751)

        NSLayoutConstraint.activate([
            sellersStack.topAnchor.constraint(
                equalTo: sellersScrollView.contentLayoutGuide.topAnchor),
            sellersStack.bottomAnchor.constraint(
                equalTo: sellersScrollView.contentLayoutGuide.bottomAnchor),
            sellersStack.leadingAnchor.constraint(
                equalTo: sellersScrollView.contentLayoutGuide.leadingAnchor),
            sellersStack.trailingAnchor.constraint(
                equalTo: sellersScrollView.contentLayoutGuide.trailingAnchor),
            sellersStack.widthAnchor.constraint(
                equalTo: sellersScrollView.frameLayoutGuide.widthAnchor),
            fitsContent,
        ])
        sellersScrollView.setContentHuggingPriority(UILayoutPriority(751), for: .vertical)
        sellersScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return sellersScrollView
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSellersFade()
        presentPendingDeepLinkedSellerSearchIfPossible()
    }

    @objc private func openContainingAppForSellerSearch() {
        openContainingAppForAddSeller?(itemID)
    }

    @objc private func addSellerDeepLinkReceived(_ notification: Notification) {
        guard notification.userInfo?[PriceTrackerAddSellerRoute.itemIDKey] as? UUID == itemID
        else { return }
        _ = PriceTrackerAddSellerRoute.consume(ifMatching: itemID)
        pendingDeepLinkedSellerSearch = true
        presentPendingDeepLinkedSellerSearchIfPossible()
    }

    private func presentPendingDeepLinkedSellerSearchIfPossible() {
        guard pendingDeepLinkedSellerSearch, viewIfLoaded?.window != nil,
              presentedViewController == nil else { return }
        pendingDeepLinkedSellerSearch = false
        presentSearchOverlay()
    }

    /// Positions the fade over the bottom of the viewport, and retires it when
    /// there is nothing below to fade towards. The mask lives on the scrolling
    /// layer, so its frame is stated in the scroll view's own bounds — which
    /// move with the content offset.
    private func updateSellersFade() {
        let bounds = sellersScrollView.bounds
        let below = sellersScrollView.contentSize.height - bounds.maxY
        // Attached only while it has something to say. A mask that is present
        // but transparent is one arithmetic slip away from hiding the list it
        // was meant to hint at, and there is nothing to hint at here.
        guard bounds.height > 1, below > 1 else {
            sellersScrollView.layer.mask = nil
            return
        }
        let fade = min(below, Self.sellerFadeHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sellersScrollView.layer.mask = sellersFade
        sellersFade.frame = bounds
        sellersFade.locations = [0, NSNumber(value: Double(1 - fade / bounds.height)), 1]
        CATransaction.commit()
    }

    /// How much of the last visible row the fade covers.
    static let sellerFadeHeight: CGFloat = 22

    // MARK: - Content

    @objc private func readingListChanged() {
        if Thread.isMainThread { reload() }
        else { DispatchQueue.main.async { [weak self] in self?.reload() } }
    }

    public func reload() {
        guard let tracker else { return }
        headlineLabel.text = ProductTitleSummary.headline(for: tracker.productName)
        let detail = ProductTitleSummary.detail(for: tracker.productName)
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        headlineLabel.accessibilityLabel = tracker.productName

        priceLabel.text = PriceFormatting.string(
            amount: tracker.currentBestPrice, currency: tracker.displayCurrency)
        let discount = Int((tracker.discountFraction * 100).rounded())
        changeLabel.text = discount > 0
            ? L10n.string("PriceTracker_productCard_discountFormat", discount) : nil
        changeLabel.isHidden = discount <= 0

        loadThumbnail(tracker)
        let series = PriceHistory.series(for: tracker)
        graphCeiling?.constant = series.isEmpty
            ? Self.emptyGraphMaximumHeight : Self.graphMaximumHeight
        graphView.setData(
            series,
            currency: tracker.displayCurrency,
            thresholdPrice: tracker.alertThresholdPrice,
            baselinePrice: tracker.initialPrice)
        alertRow.configure(
            fraction: tracker.alertThresholdFraction,
            initialPrice: tracker.initialPrice, currency: tracker.initialCurrency)
        rebuildSellerRows(tracker)
    }

    private func loadThumbnail(_ tracker: PriceTracker) {
        PriceTrackerProductImage.load(
            imageFileName: tracker.imageFileName,
            pageURL: tracker.stores.first.flatMap { URL(string: $0.urlString) }
        ) { [weak self] loaded in
            let apply = {
                self?.thumbnailView.contentMode = .scaleAspectFill
                self?.thumbnailView.image = loaded
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
    }

    private func rebuildSellerRows(_ tracker: PriceTracker) {
        for view in sellersStack.arrangedSubviews {
            sellersStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let lowest = tracker.stores.compactMap(\.lastPrice).min()
        for listing in tracker.stores {
            let row = SellerRowView()
            row.configure(
                listing,
                isLowest: listing.lastPrice != nil && listing.lastPrice == lowest
                    && tracker.stores.count > 1,
                isFlashed: listing.urlString == highlightedURLString)
            row.addTarget(self, action: #selector(sellerRowTapped(_:)), for: .touchUpInside)
            if tracker.stores.count > 1 {
                row.addInteraction(UIContextMenuInteraction(delegate: self))
            }
            sellersStack.addArrangedSubview(row)
        }
        // While a fan-out is out, the list says so — the same pending marker the
        // tracker carries on disk, drawn wherever the sellers are.
        if tracker.pendingComparison != nil {
            sellersStack.addArrangedSubview(makeCheckingRow())
        }
    }

    /// The waiting row: a spinner and a line of copy, going nowhere. Not a
    /// button — there is no seller behind it yet.
    private func makeCheckingRow() -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let label = UILabel()
        label.text = L10n.string("PriceTracker_comparison_checkingSellersRow")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = LunaColors.secondaryText
        let row = UIStackView(arrangedSubviews: [spinner, label, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        row.accessibilityLabel = label.text
        return row
    }

    // MARK: - The alert threshold

    /// The ONE place a threshold is written, from the alert row's slider or its
    /// unset-state button. The graph only mirrors this value.
    ///
    /// Committing a threshold is the opt-in moment for notifications: an alert
    /// the user just asked for is the first thing Luna has to tell them about
    /// this product (launch never asks). Idempotent, and a no-op in the
    /// extension-hosted copy (an `.appex` can't ask), so every path just calls it.
    private func commitThreshold(fraction: Double) {
        guard var tracker else { return }
        tracker.setAlertThresholdFraction(fraction)
        store.updatePriceTracker(tracker, for: itemID)
        NotificationManager.requestAuthorization()
        reload()
    }

    // MARK: - Sellers

    @objc private func sellerRowTapped(_ row: SellerRowView) {
        InAppBrowser.present(urlString: row.urlString, from: self)
    }

    /// The two ways to add one, offered together in both apps: browse to a page,
    /// or paste its link. The card only ever offered the first and the editor
    /// only ever offered the second.
    private func addSellerMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: L10n.string("PriceTracker_tracking_searchActionTitle"),
                image: UIImage(systemName: "magnifyingglass")
            ) { [weak self] _ in self?.presentSearchOverlay() },
            UIAction(
                title: L10n.string("PriceTracker_tracking_pasteLinkActionTitle"),
                image: UIImage(systemName: "link")
            ) { [weak self] _ in self?.presentPasteLinkAlert() },
        ])
    }

    private func presentPasteLinkAlert() {
        let alert = UIAlertController(
            title: L10n.string("PriceTracker_tracking_addSellerAlertTitle"),
            message: L10n.string("PriceTracker_tracking_addSellerAlertMessage"),
            preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = L10n.string("PriceTracker_tracking_urlFieldPlaceholder")
            $0.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(
            title: L10n.string("Common_add"), style: .default
        ) { [weak self, weak alert] _ in
            guard let urlString = alert?.textFields?.first?.text, !urlString.isEmpty else { return }
            self?.addSeller(urlString: urlString)
        })
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        present(alert, animated: true)
    }

    /// Presents the web search/browse overlay preloaded with a shopping search
    /// for this product. Confirming a page adds it as a seller through the same
    /// mandatory-price add path.
    private func presentSearchOverlay() {
        guard let tracker else { return }
        let searchURL = ProductSearchURL.googleShoppingURL(forProductName: tracker.productName)
            ?? URL(string: "https://www.google.com")
        guard let searchURL else { return }
        let product = ProductInfo(
            name: tracker.productName,
            priceAmount: tracker.initialPrice,
            priceCurrency: tracker.initialCurrency,
            imageURL: nil, brand: tracker.brand, productID: tracker.productID,
            identifiers: tracker.identifiers)
        let sourcePoint = addSellerButton.convert(
            CGPoint(x: addSellerButton.bounds.midX, y: addSellerButton.bounds.midY), to: nil)
        let overlay = ProductSearchOverlayViewController(
            initialURL: searchURL,
            trackedProduct: product,
            eclipseSourcePointInWindow: sourcePoint,
            eclipseSceneFrameInWindow: view.convert(view.bounds, to: nil))
        overlay.delegate = self
        present(overlay, animated: true)
    }

    /// Adds `urlString` as a seller: fetches its price (mandatory, via the same
    /// `PriceFetcher` path the rest of the app uses) and only adds the store when
    /// a price is readable; surfaces a message otherwise. Dedupes a URL already
    /// tracked. `prefetchedHTML` (the search overlay's rendered `outerHTML`) lets
    /// the fetcher take its fast static path and SEE JS-loaded prices without a
    /// re-fetch.
    ///
    /// `report` (the search-overlay add path) receives the typed outcome so the
    /// overlay can dismiss on success or show a clear message — never a silent
    /// no-op. When `report` shows the message itself, the paste path omits it and
    /// this method presents its own alert.
    private func addSeller(
        urlString: String, prefetchedHTML: String? = nil,
        report: ((ProductSearchAddOutcome) -> Void)? = nil
    ) {
        guard let tracker else { return }
        if tracker.hasStore(urlString: urlString) {
            if let report {
                report(.duplicate)
            } else {
                presentPriceMessage(
                    title: L10n.string("PriceTracker_addSeller_alreadyTrackedTitle"),
                    message: L10n.string("PriceTracker_tracking_alreadyTrackedMessage"))
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let price = await self.priceFetcher.fetchPrice(
                forURLString: urlString, prefetchedHTML: prefetchedHTML)
            await MainActor.run {
                guard var current = self.tracker else { return }
                if current.hasStore(urlString: urlString) {
                    report?(.duplicate)
                    return
                }
                guard let price else {
                    if let report {
                        report(.noPrice)
                    } else if ProductPriceRescue.resolver != nil {
                        self.presentNoPriceWithRescueOption(urlString: urlString)
                    } else {
                        self.presentPriceMessage(
                            title: L10n.string("PriceTracker_tracking_noPriceFoundTitle"),
                            message: L10n.string("PriceTracker_tracking_noPriceMessage"))
                    }
                    return
                }
                current.upsertStore(PriceTrackerStore(
                    urlString: urlString, lastPrice: price.amount,
                    currency: price.currency, lastRefreshed: Date()))
                self.store.updatePriceTracker(current, for: self.itemID)
                self.reload()
                report?(.added)
            }
        }
    }

    /// The no-price alert, plus a "Retry with AI" action (only shown when the
    /// resolver is installed — i.e. the main app, never extensions). The label
    /// matches every other error surface's offer
    /// (`GlassStyle.retryWithAIConfiguration`).
    private func presentNoPriceWithRescueOption(urlString: String) {
        let alert = UIAlertController(
            title: L10n.string("PriceTracker_tracking_noPriceFoundTitle"),
            message: L10n.string("PriceTracker_tracking_noPriceRescueMessage"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: L10n.string("Common_retryWithAI"), style: .default
        ) { [weak self] _ in
            self?.askIntelligenceForPrice(urlString: urlString)
        })
        alert.addAction(UIAlertAction(title: L10n.string("Common_notNow"), style: .cancel))
        present(alert, animated: true)
    }

    /// Runs the injected URL-rescue price resolver and, on success, adds the
    /// seller through the same upsert tail the normal add path uses.
    private func askIntelligenceForPrice(urlString: String) {
        guard let resolver = ProductPriceRescue.resolver else { return }
        Task { @MainActor [weak self] in
            let resolved = await resolver(urlString)
            guard let self, var current = self.tracker else { return }
            guard let resolved else {
                self.presentPriceMessage(
                    title: L10n.string("PriceTracker_tracking_stillNoPriceTitle"),
                    message: L10n.string("PriceTracker_tracking_stillNoPriceMessage"))
                return
            }
            current.upsertStore(PriceTrackerStore(
                urlString: urlString, lastPrice: resolved.amount,
                currency: resolved.currency, lastRefreshed: Date()))
            self.store.updatePriceTracker(current, for: self.itemID)
            self.reload()
        }
    }

    private func removeSeller(urlString: String) {
        guard var tracker, tracker.removeStore(urlString: urlString) else { return }
        store.updatePriceTracker(tracker, for: itemID)
        reload()
    }
}

/// The app-shell route posts this after centering the requested product card.
/// Keeping the payload in one named seam lets an already-mounted card and a card
/// created by the centering reload behave identically.
@MainActor
public enum PriceTrackerAddSellerRoute {
    public static let itemIDKey = "itemID"
    private static var pendingItemID: UUID?

    public static func request(itemID: UUID) {
        pendingItemID = itemID
        NotificationCenter.default.post(
            name: .priceTrackerAddSellerRequested, object: nil,
            userInfo: [itemIDKey: itemID])
    }

    static func consume(ifMatching itemID: UUID) -> Bool {
        guard pendingItemID == itemID else { return false }
        pendingItemID = nil
        return true
    }
}

public extension Notification.Name {
    static let priceTrackerAddSellerRequested = Notification.Name(
        "LunaPriceTrackerAddSellerRequested")
}

// MARK: - Removing a seller

/// A seller comes off the list through the row's own context menu. The card used
/// to carry a permanent minus button beside every row (a destructive action one
/// mis-tap away, on a card whose whole point is the prices next to it) and the
/// editor hid the same action behind a table swipe. A long press is the one
/// gesture that works in both hosts and costs the layout nothing.
extension ProductDetailViewController: UIContextMenuInteractionDelegate {

    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let row = interaction.view as? SellerRowView else { return nil }
        let urlString = row.urlString
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: L10n.string("Common_openLink"),
                    image: UIImage(systemName: "safari")
                ) { _ in
                    guard let self else { return }
                    InAppBrowser.present(urlString: urlString, from: self)
                },
                UIAction(
                    title: L10n.string("Common_remove"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in self?.removeSeller(urlString: urlString) },
            ])
        }
    }
}

extension ProductDetailViewController: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateSellersFade()
    }
}

extension ProductDetailViewController: ProductSearchOverlayDelegate {
    public func productSearchOverlay(
        _ overlay: ProductSearchOverlayViewController,
        didConfirmPage urlString: String, html: String,
        completion: @escaping (ProductSearchAddOutcome) -> Void
    ) {
        addSeller(urlString: urlString, prefetchedHTML: html.isEmpty ? nil : html, report: completion)
    }
}
