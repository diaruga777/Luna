//
//  PriceTrackingViewController.swift
//  Clip
//

import UIKit

extension Notification.Name {
    /// Posted when an interactive save (paste/manual/app intent) created or merged
    /// a price tracker, so the foreground reading list can present its editor with
    /// a Cancel → save-as-article fallback. `userInfo`: `itemID: UUID`,
    /// `isMerge: Bool`, `highlightedURL: String?`.
    static let priceTrackerSavedInteractively =
        Notification.Name("priceTrackerSavedInteractively")
}

/// Shows and edits one price tracker: a table of its store URLs (each row shows
/// the extracted price; tapping opens the URL in the in-app browser), a **+**
/// button to add another store URL for the same product, and a bottom alert-config
/// control (a threshold slider shown both as a percent and as an absolute price).
///
/// Two entry points:
/// - **existing**: open an already-saved tracker (`init(itemID:)`).
/// - **creation/merge** (save-time UX): present at save time so the user can add
///   more URLs before committing, with a Cancel button that instead saves the URL
///   as a normal text article (`init(creation:)`).
final class PriceTrackingViewController: UIViewController {

    /// How the screen was opened.
    enum Mode {
        /// Viewing/editing an existing saved tracker.
        case existing(itemID: UUID)
        /// Presented at save time for a freshly detected product (creation flow):
        /// the item is already saved as a tracker, but a Cancel converts it to a
        /// normal article instead. `highlightedURL` is the just-added store URL to
        /// flash at the top (used when merging into an existing tracker).
        case creation(itemID: UUID, isMerge: Bool, highlightedURL: String?)
    }

    private let mode: Mode
    private let store = ReadingListStore.shared
    private let manager: PriceTrackingManaging

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let thresholdSlider = UISlider()
    private let thresholdLabel = UILabel()

    private var itemID: UUID {
        switch mode {
        case .existing(let id): return id
        case .creation(let id, _, _): return id
        }
    }

    private var tracker: PriceTracker? { store.item(withID: itemID)?.priceTracker }

    init(itemID: UUID, manager: PriceTrackingManaging = PriceTrackingManager()) {
        self.mode = .existing(itemID: itemID)
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    init(mode: Mode, manager: PriceTrackingManaging = PriceTrackingManager()) {
        self.mode = mode
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = tracker?.productName ?? "Price Tracker"

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "store")
        view.addSubview(tableView)

        let footer = makeThresholdFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addStoreTapped))

        switch mode {
        case .existing:
            break
        case .creation(_, let isMerge, _):
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "Cancel", style: .plain, target: self, action: #selector(cancelTapped))
            if isMerge {
                navigationItem.prompt = "Added to an existing tracker"
            }
        }

        syncThresholdControl()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .readingListChanged, object: nil)
    }

    @objc private func reload() {
        tableView.reloadData()
        syncThresholdControl()
    }

    // MARK: - Threshold footer

    private func makeThresholdFooter() -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemGroupedBackground

        thresholdLabel.font = .preferredFont(forTextStyle: .subheadline)
        thresholdLabel.textColor = .secondaryLabel
        thresholdLabel.numberOfLines = 0

        thresholdSlider.minimumValue = 0.01
        thresholdSlider.maximumValue = 0.90
        thresholdSlider.addTarget(self, action: #selector(thresholdChanged), for: .valueChanged)
        thresholdSlider.addTarget(self, action: #selector(thresholdCommitted),
                                  for: [.touchUpInside, .touchUpOutside])

        let title = UILabel()
        title.text = "Alert me when the price drops"
        title.font = .preferredFont(forTextStyle: .headline)

        let stack = UIStackView(arrangedSubviews: [title, thresholdSlider, thresholdLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private func syncThresholdControl() {
        guard let tracker else { return }
        thresholdSlider.value = Float(tracker.alertThresholdFraction)
        updateThresholdLabel(fraction: tracker.alertThresholdFraction, tracker: tracker)
        title = tracker.productName
    }

    private func updateThresholdLabel(fraction: Double, tracker: PriceTracker) {
        thresholdLabel.text = PriceFormatting.thresholdDescription(
            fraction: fraction, initialPrice: tracker.initialPrice, currency: tracker.initialCurrency)
    }

    @objc private func thresholdChanged() {
        guard let tracker else { return }
        updateThresholdLabel(fraction: Double(thresholdSlider.value), tracker: tracker)
    }

    @objc private func thresholdCommitted() {
        guard var tracker else { return }
        tracker.alertThresholdFraction = Double(thresholdSlider.value)
        store.updatePriceTracker(tracker, for: itemID)
    }

    // MARK: - Add store

    @objc private func addStoreTapped() {
        let alert = UIAlertController(
            title: "Add Store URL",
            message: "Track this product's price at another store.",
            preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "https://…"; $0.keyboardType = .URL }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            guard let urlString = alert.textFields?.first?.text, !urlString.isEmpty else { return }
            self?.addStore(urlString: urlString)
        })
        present(alert, animated: true)
    }

    private func addStore(urlString: String) {
        guard let tracker, !tracker.hasStore(urlString: urlString) else { return }
        Task { [weak self] in
            guard let self else { return }
            let info = await self.manager.detectProduct(urlString: urlString)
            await MainActor.run {
                guard var current = self.tracker else { return }
                let storeListing = PriceTrackerStore(
                    urlString: urlString,
                    lastPrice: info?.priceAmount,
                    currency: info?.priceCurrency ?? current.initialCurrency,
                    lastRefreshed: info != nil ? Date() : nil)
                current.upsertStore(storeListing)
                self.store.updatePriceTracker(current, for: self.itemID)
            }
        }
    }

    // MARK: - Cancel → save as article (creation flow)

    @objc private func cancelTapped() {
        guard case .creation = mode, let item = store.item(withID: itemID) else {
            dismiss(animated: true)
            return
        }
        let urlString = item.urlString
        // Drop the tracker save and re-save the URL as a normal article instead.
        store.delete(item)
        Task { await ReadingListIngestor.shared.handleSavePress(urlString: urlString, source: .manual) }
        dismissOrPop()
    }

    private func dismissOrPop() {
        if let navigationController, navigationController.viewControllers.first !== self,
           presentingViewController == nil {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }
}

extension PriceTrackingViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tracker?.stores.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "store", for: indexPath)
        guard let storeListing = tracker?.stores[indexPath.row] else { return cell }
        var config = cell.defaultContentConfiguration()
        config.text = storeListing.url?.host?.replacingOccurrences(of: "www.", with: "")
            ?? storeListing.urlString
        if let price = storeListing.lastPrice {
            config.secondaryText = PriceFormatting.string(
                amount: price, currency: storeListing.currency)
        } else {
            config.secondaryText = "Price unavailable"
        }
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator

        // Flash the just-added/merged URL at the top.
        if case .creation(_, _, let highlightedURL) = mode,
           highlightedURL == storeListing.urlString {
            cell.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Stores"
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let storeListing = tracker?.stores[indexPath.row] else { return }
        InAppBrowser.present(urlString: storeListing.urlString, from: self)
    }

    func tableView(
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
