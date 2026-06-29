//
//  PriceTrackingViewController.swift
//  ShareKit
//

import ClipStorage
import ClipHTMLClassification
import ClipURLClassification
import ClipModels
import UIKit

public extension Notification.Name {
    /// Posted when an interactive save (paste/manual/app intent) created or merged
    /// a price tracker, so the foreground reading list can present its editor with
    /// a "Read instead" → save-as-article fallback. `userInfo`: `itemID: UUID`,
    /// `isMerge: Bool`, `highlightedURL: String?`.
    public static let priceTrackerSavedInteractively =
        Notification.Name("priceTrackerSavedInteractively")
}

/// Shows and edits one price tracker: a table of its seller URLs (each row shows
/// the extracted price; tapping opens the URL in the in-app browser), an **Add
/// seller** footer (paste a URL, or web-search/browse to one), and a bottom
/// alert-config control (a threshold slider shown both as a percent and as an
/// absolute price).
///
/// Navigation chrome is decided by an explicit `PriceTrackingExitContext` (host +
/// entry), so the right control lands in the right context regardless of the view
/// hierarchy (see `ReaderKit/PriceTrackingExitContext.swift`):
/// - **Top-left** — Back chevron in-app (pops), Done in an extension (dismisses).
/// - **Top-right "Read instead"** — only at save time. **Creation** discards the
///   whole new tracker and saves the URL as a normal article; **merge** reverts
///   ONLY the just-added seller and saves that one URL as an article. **Existing**
///   (returning to a saved tracker) shows no "Read instead" button.
public final class PriceTrackingViewController: UIViewController, UIGestureRecognizerDelegate {

    /// How the screen was opened, mapped to a `PriceTrackingExitContext`.
    public enum Mode {
        /// Viewing/editing an already-saved tracker (in-app). No "Read instead".
        case existing(itemID: UUID)
        /// Save-time, a brand-new product saved as its OWN new tracker. "Read instead"
        /// discards the whole tracker and saves the URL as an article.
        case creation(itemID: UUID, host: PriceTrackingHost)
        /// Save-time, the just-saved URL was merged as a seller into an EXISTING
        /// tracker. "Read instead" reverts ONLY `addedStoreURLString` and saves that
        /// one URL as an article. `addedStoreURLString` is flashed at the top.
        case merge(itemID: UUID, addedStoreURLString: String, host: PriceTrackingHost)

        var itemID: UUID {
            switch self {
            case .existing(let id), .creation(let id, _), .merge(let id, _, _): return id
            }
        }

        /// The pure host + entry decision model for this mode.
        var exitContext: PriceTrackingExitContext {
            switch self {
            case .existing:
                return PriceTrackingExitContext(host: .inApp, entry: .existing)
            case .creation(_, let host):
                return PriceTrackingExitContext(host: host, entry: .creation)
            case .merge(_, let url, let host):
                return PriceTrackingExitContext(host: host, entry: .merge(addedStoreURLString: url))
            }
        }

        /// The just-added seller URL to flash at the top (merge only).
        var highlightedURLString: String? {
            if case .merge(_, let url, _) = self { return url }
            return nil
        }
    }

    private let mode: Mode
    private let store = ReadingListStore.shared
    private let manager: PriceTrackingManaging

    /// Re-saves a URL as a normal article when the user taps "Read instead". Injected
    /// so the editor stays extension-safe (ShareKit has no `ReadingListIngestor`): the
    /// main app installs `defaultSaveAsArticle` (→ the ingestor's forced-article save);
    /// the action extension passes a per-instance handler that re-appends + lets the app
    /// ingest. Falls back to the static default when no per-instance handler is given.
    private let saveAsArticleOverride: ((String) -> Void)?

    /// The main app's "Read instead" save-as-article behavior, installed once at launch
    /// so in-app `PriceTrackingViewController`s need no per-instance handler. Lives as a
    /// static hook (not a hard reference) to keep ShareKit free of main-app deps.
    public static var defaultSaveAsArticle: ((String) -> Void)?

    /// Invoked when the editor is dismissed via the extension **Done** button, so the
    /// host (action extension) can complete its request. nil in-app (the back chevron
    /// just pops). Set by the extension host after construction.
    public var onDone: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let thresholdSlider = AlertThresholdSlider()
    private let productHeader = UIView()
    private let productTitleLabel = UILabel()
    /// Icon-only "+" that sits inline with the "Sellers" section header (right),
    /// alongside the list it adds to.
    private let addSellerButton = UIButton(type: .system)
    /// Price-history graph slot, BELOW the table and ABOVE the alert footer, outside
    /// the scroll view. Shows the graph once there are ≥3 days of data, else a
    /// pending "Awaiting more data" state.
    private let graphContainer = UIView()
    private let graphTitleLabel = UILabel()
    private let graphView = PriceGraphView()
    /// The "Sellers" section header: a footnote title on the left and the icon-only
    /// add button on the right, inset to align with the grouped list.
    private lazy var sellersHeaderView: UIView = {
        let container = UIView()
        let label = UILabel()
        label.text = "Sellers"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(addSellerButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            addSellerButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            addSellerButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        return container
    }()
    /// UIKit owns the navigation controller's normal interactive-pop delegate. Keep
    /// it so this screen can temporarily opt in without changing other screens.
    private weak var previousInteractivePopGestureDelegate: UIGestureRecognizerDelegate?

    private var itemID: UUID { mode.itemID }
    private var exitContext: PriceTrackingExitContext { mode.exitContext }

    private var tracker: PriceTracker? { store.item(withID: itemID)?.priceTracker }

    public init(itemID: UUID, manager: PriceTrackingManaging = PriceTrackingManager()) {
        self.mode = .existing(itemID: itemID)
        self.manager = manager
        self.saveAsArticleOverride = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// `onReadInstead` overrides the "Read instead" re-save (extension surfaces inject
    /// their own; in-app callers omit it to use the static `defaultSaveAsArticle`).
    public init(
        mode: Mode, manager: PriceTrackingManaging = PriceTrackingManager(),
        onReadInstead: ((String) -> Void)? = nil
    ) {
        self.mode = mode
        self.manager = manager
        self.saveAsArticleOverride = onReadInstead
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = "Price Tracker"
        navigationItem.largeTitleDisplayMode = .never

        productHeader.backgroundColor = .systemGroupedBackground
        productHeader.translatesAutoresizingMaskIntoConstraints = false
        productTitleLabel.font = .preferredFont(forTextStyle: .title3)
        productTitleLabel.adjustsFontForContentSizeCategory = true
        productTitleLabel.textColor = .label
        productTitleLabel.numberOfLines = 0
        productTitleLabel.lineBreakMode = .byWordWrapping
        productTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        productHeader.addSubview(productTitleLabel)

        var addConfig = UIButton.Configuration.plain()
        addConfig.image = UIImage(systemName: "plus", withConfiguration:
            UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
        addConfig.contentInsets = .zero
        addSellerButton.configuration = addConfig
        addSellerButton.setContentHuggingPriority(.required, for: .horizontal)
        addSellerButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSellerButton.addTarget(self, action: #selector(addSellerTapped), for: .touchUpInside)
        addSellerButton.translatesAutoresizingMaskIntoConstraints = false
        addSellerButton.accessibilityLabel = "Add seller"
        view.addSubview(productHeader)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "store")
        view.addSubview(tableView)

        configureGraphContainer()
        view.addSubview(graphContainer)

        let footer = makeThresholdFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            productHeader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            productHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            productHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            productTitleLabel.topAnchor.constraint(equalTo: productHeader.topAnchor, constant: 12),
            productTitleLabel.leadingAnchor.constraint(equalTo: productHeader.layoutMarginsGuide.leadingAnchor),
            productTitleLabel.trailingAnchor.constraint(equalTo: productHeader.layoutMarginsGuide.trailingAnchor),
            productTitleLabel.bottomAnchor.constraint(equalTo: productHeader.bottomAnchor, constant: -10),
            tableView.topAnchor.constraint(equalTo: productHeader.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: graphContainer.topAnchor),
            graphContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            graphContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            graphContainer.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        // Responsive graph height: ~168pt preferred, but never more than 40% of the
        // safe area, so on short screens (small phones / landscape) the sellers table
        // and footer always remain visible. The table fills whatever's left.
        let graphHeight = graphContainer.heightAnchor.constraint(equalToConstant: 168)
        graphHeight.priority = .defaultHigh
        graphHeight.isActive = true
        graphContainer.heightAnchor.constraint(
            lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.4).isActive = true

        configureNavigationChrome()
        syncThresholdControl()
        refreshGraph()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
    }

    /// Installing a custom left button (the explicit Back/Done decision above)
    /// suppresses UIKit's interactive-pop recognizer by default. Restore it for the
    /// in-app pushed editor so the root reading list remains reachable by the normal
    /// left-edge swipe; extension-hosted editors still have no navigation stack.
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Authoritatively show the SHARED nav bar (and clear any leftover transform/alpha
        // a reader left behind) so this screen's header + back button are always present.
        // Readers tuck/hide the same bar; without re-asserting here, pushing the price
        // tracker after a reader would inherit a hidden/transparent bar — items set, but
        // invisible. The custom Dot Matrix push runs viewWillAppear, so this is reliable.
        if let bar = navigationController?.navigationBar {
            bar.transform = .identity
            bar.alpha = 1
        }
        navigationController?.setNavigationBarHidden(false, animated: false)
        refreshGraph()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard exitContext.host == .inApp,
              let popGesture = navigationController?.interactivePopGestureRecognizer else { return }
        if popGesture.delegate !== self {
            previousInteractivePopGestureDelegate = popGesture.delegate
        }
        popGesture.delegate = self
        popGesture.isEnabled = true
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let popGesture = navigationController?.interactivePopGestureRecognizer,
              popGesture.delegate === self else { return }
        // Return ownership to UIKit before another screen becomes visible.
        popGesture.delegate = previousInteractivePopGestureDelegate
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === navigationController?.interactivePopGestureRecognizer else {
            return true
        }
        guard exitContext.host == .inApp,
              let navigationController,
              navigationController.viewControllers.count > 1 else { return false }
        // Do not begin a second interactive transition while the navigation
        // controller is already pushing or popping.
        return navigationController.transitionCoordinator == nil
    }

    /// Installs the top-left (back/done) and top-right ("Read instead") buttons from
    /// the pure `PriceTrackingExitContext` decision.
    private func configureNavigationChrome() {
        switch exitContext.leftButton {
        case .back:
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "chevron.backward"),
                style: .plain, target: self, action: #selector(leftButtonTapped))
        case .done:
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(leftButtonTapped))
        }

        switch exitContext.readInsteadAction {
        case .hidden:
            navigationItem.rightBarButtonItem = nil
        case .discardTracker, .revertAddedStore:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Read instead", style: .plain,
                target: self, action: #selector(readInsteadTapped))
        }
    }

    @objc private func reload() {
        tableView.reloadData()
        syncThresholdControl()
    }


    // MARK: - Threshold footer

    // MARK: - Price-history graph

    private func configureGraphContainer() {
        graphContainer.backgroundColor = .systemGroupedBackground
        graphContainer.translatesAutoresizingMaskIntoConstraints = false

        graphTitleLabel.text = "Price History"
        graphTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        graphTitleLabel.textColor = .secondaryLabel
        graphTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        graphContainer.addSubview(graphTitleLabel)

        graphView.translatesAutoresizingMaskIntoConstraints = false
        graphContainer.addSubview(graphView)

        NSLayoutConstraint.activate([
            graphTitleLabel.topAnchor.constraint(equalTo: graphContainer.topAnchor, constant: 8),
            graphTitleLabel.leadingAnchor.constraint(equalTo: graphContainer.layoutMarginsGuide.leadingAnchor),
            graphTitleLabel.trailingAnchor.constraint(equalTo: graphContainer.layoutMarginsGuide.trailingAnchor),
            graphView.topAnchor.constraint(equalTo: graphTitleLabel.bottomAnchor, constant: 2),
            graphView.leadingAnchor.constraint(equalTo: graphContainer.leadingAnchor, constant: 12),
            graphView.trailingAnchor.constraint(equalTo: graphContainer.trailingAnchor, constant: -12),
            graphView.bottomAnchor.constraint(equalTo: graphContainer.bottomAnchor, constant: -8),
        ])
    }

    /// Shows the graph when there are ≥3 days of data, else a graph-shaped placeholder.
    private func refreshGraph() {
        guard let tracker else { graphContainer.isHidden = true; return }
        graphContainer.isHidden = false
        let series = PriceHistory.series(for: tracker)
        let hasEnough = PriceHistory.distinctDayCount(tracker) >= PriceHistory.minimumDaysForGraph
            && series.count >= 2
        if hasEnough {
            graphView.setData(series, currency: tracker.displayCurrency)
        } else {
            graphView.showPlaceholder()
        }
    }

    private func makeThresholdFooter() -> UIView {
        let container = UIView()
        container.backgroundColor = .systemGroupedBackground

        thresholdSlider.onCommitted = { [weak self] fraction in
            guard let self, var tracker = self.tracker else { return }
            tracker.alertThresholdFraction = fraction
            self.store.updatePriceTracker(tracker, for: self.itemID)
        }
        thresholdSlider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(thresholdSlider)
        NSLayoutConstraint.activate([
            thresholdSlider.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            thresholdSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            thresholdSlider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            thresholdSlider.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func syncThresholdControl() {
        guard let tracker else { return }
        thresholdSlider.configure(
            fraction: tracker.alertThresholdFraction,
            initialPrice: tracker.initialPrice, currency: tracker.initialCurrency)
        productTitleLabel.text = tracker.productName
    }

    // MARK: - Add seller

    /// The "Add seller" footer alert: a URL text field plus three vertically-stacked
    /// actions — Add (paste a URL), Search (browse to one), Cancel.
    @objc private func addSellerTapped() {
        let alert = UIAlertController(
            title: "Add a seller",
            message: "Track this product's price at another store.",
            preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "https://…"; $0.keyboardType = .URL }
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let urlString = alert?.textFields?.first?.text, !urlString.isEmpty else { return }
            self?.addSeller(urlString: urlString)
        })
        alert.addAction(UIAlertAction(title: "Search", style: .default) { [weak self] _ in
            self?.presentSearchOverlay()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Adds `urlString` as a seller: fetches its price (mandatory, via the same
    /// `PriceFetcher` path the rest of the app uses) and only adds the store when a
    /// price is readable; surfaces a message otherwise. Dedupes a URL already tracked.
    /// `prefetchedHTML` (the search overlay's rendered `outerHTML`) lets the fetcher
    /// take its fast static path and SEE JS-loaded prices without a re-fetch.
    ///
    /// `report` (the search-overlay add path) receives the typed outcome so the
    /// overlay can dismiss on success or show a clear message — never a silent no-op.
    /// When `report` shows the message itself, the paste path omits it and this method
    /// presents its own alert.
    private func addSeller(
        urlString: String, prefetchedHTML: String? = nil,
        report: ((ProductSearchAddOutcome) -> Void)? = nil
    ) {
        guard let tracker else { return }
        if tracker.hasStore(urlString: urlString) {
            if let report {
                report(.duplicate)
            } else {
                presentMessage(title: "Already tracked", message: "This page is already a seller.")
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let price = await self.manager.fetchPrice(
                urlString: urlString, prefetchedHTML: prefetchedHTML)
            await MainActor.run {
                guard var current = self.tracker else { return }
                if current.hasStore(urlString: urlString) {
                    report?(.duplicate)
                    return
                }
                guard let price else {
                    if let report {
                        report(.noPrice)
                    } else {
                        self.presentMessage(
                            title: "No price found",
                            message: "We couldn't read a price on that page, so it wasn't added.")
                    }
                    return
                }
                current.upsertStore(PriceTrackerStore(
                    urlString: urlString, lastPrice: price.amount,
                    currency: price.currency, lastRefreshed: Date()))
                self.store.updatePriceTracker(current, for: self.itemID)
                report?(.added)
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Search overlay

    /// Presents the web search/browse overlay preloaded with a Google Shopping search
    /// for this product. Confirming a page (via "+" or auto-detect) adds it as a
    /// seller through the same mandatory-price add path.
    private func presentSearchOverlay() {
        let productName = tracker?.productName ?? ""
        let searchURL = ProductSearchURL.googleShoppingURL(forProductName: productName)
            ?? URL(string: "https://www.google.com")
        guard let searchURL else { return }
        let trackedProduct = ProductInfo(
            name: tracker?.productName ?? productName,
            priceAmount: tracker?.initialPrice ?? 0,
            priceCurrency: tracker?.initialCurrency ?? "USD",
            imageURL: nil, brand: tracker?.brand, productID: tracker?.productID)
        let overlay = ProductSearchOverlayViewController(
            initialURL: searchURL, trackedProduct: trackedProduct)
        overlay.onUseThisPage = { [weak self] urlString, html, completion in
            self?.addSeller(
                urlString: urlString, prefetchedHTML: html.isEmpty ? nil : html,
                report: completion)
        }
        present(overlay, animated: true)
    }

    // MARK: - Exit

    /// Top-left button: pops back to the reading list (in-app) or dismisses/completes
    /// the hosting extension (extension). The tracker is already saved and every edit
    /// persists as it's made, so this just leaves the screen.
    @objc private func leftButtonTapped() {
        dismissOrPop()
    }

    /// Top-right "Read instead": overrides the save-time tracker classification.
    /// - **Creation**: discard the whole new tracker (delete its item) and re-save its
    ///   URL as a normal article.
    /// - **Merge**: revert ONLY the just-added seller (remove that URL from the
    ///   existing tracker, leaving it otherwise intact) and save that one URL as an
    ///   article.
    /// Then leave the screen. Never shown for the existing entry.
    @objc private func readInsteadTapped() {
        // The re-save is injected (extension-safe): a per-instance handler wins, else
        // the static default the main app installs. ShareKit holds no `ReadingListIngestor`.
        let saveAsArticle = saveAsArticleOverride ?? Self.defaultSaveAsArticle
        switch exitContext.readInsteadAction {
        case .hidden:
            return
        case .discardTracker:
            guard let item = store.item(withID: itemID) else { dismissOrPop(); return }
            let urlString = item.urlString
            store.delete(item)
            saveAsArticle?(urlString)
        case .revertAddedStore(let urlString):
            if var current = tracker, current.removeStore(urlString: urlString) {
                store.updatePriceTracker(current, for: itemID)
            }
            saveAsArticle?(urlString)
        }
        dismissOrPop()
    }

    /// Leaves the screen whichever way it was shown: pop when pushed onto a nav stack
    /// (in-app), else hand off to the extension host's `onDone` (which completes the
    /// extension request), else dismiss the modal presentation. Always exits.
    private func dismissOrPop() {
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else if let onDone {
            onDone()
        } else {
            dismiss(animated: true)
        }
    }
}

extension PriceTrackingViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tracker?.stores.count ?? 0
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "store", for: indexPath)
        guard let storeListing = tracker?.stores[indexPath.row] else { return cell }
        var config = cell.defaultContentConfiguration()
        config.text = storeListing.url?.host?.replacingOccurrences(of: "www.", with: "")
            ?? storeListing.urlString
        if let price = storeListing.lastPrice {
            let formatted = PriceFormatting.string(amount: price, currency: storeListing.currency)
            config.secondaryText = "\(formatted) · \(refreshDescription(for: storeListing))"
        } else {
            config.secondaryText = "Price unavailable · \(refreshDescription(for: storeListing))"
        }
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator

        // Flash the just-added/merged URL at the top.
        if mode.highlightedURLString == storeListing.urlString {
            cell.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        sellersHeaderView
    }

    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        40
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let storeListing = tracker?.stores[indexPath.row] else { return }
        InAppBrowser.present(urlString: storeListing.urlString, from: self)
    }

    public func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let tracker, tracker.stores.count > 1 else { return nil }
        let urlString = tracker.stores[indexPath.row].urlString
        let delete = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            guard let self, var current = self.tracker else { return done(false) }
            let removed = current.removeStore(urlString: urlString)
            if removed { self.store.updatePriceTracker(current, for: self.itemID) }
            done(removed)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

private extension PriceTrackingViewController {
    public func refreshDescription(for store: PriceTrackerStore) -> String {
        guard let refreshed = store.lastRefreshed else { return "Not yet refreshed" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d, h:mm a")
        return "Refreshed \(formatter.string(from: refreshed))"
    }
}
