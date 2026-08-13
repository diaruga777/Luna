//
//  ProductCardPresenter.swift
//  Luna
//
//  The product kind's card behavior, defined once for every app that shows a
//  price tracker: Luna Price Tracker and the central Luna app. Compiled into
//  exactly those two targets.
//
//  Both apps render the same in-card editor here, with product picture,
//  share, alert acknowledgement, and a fingerprint that includes price so a
//  moved price re-renders the card.
//

import LunaDesignSystem
import LunaModels
import LunaPriceUI
import LunaStorage
import UIKit

@MainActor
final class ProductCardPresenter: CardKindPresenting {

    private let store = SavesStore.shared
    /// Held so the interactive-save observer outlives `willBeginObservingStores`.
    private var savedInteractivelyObserver: NSObjectProtocol?

    // MARK: - Slot data

    /// A price change must re-render the card, so the fingerprint includes
    /// every store's last price and history count.
    func fingerprint(for item: SavedItem) -> String {
        guard let tracker = item.priceTracker else { return "" }
        let stores = tracker.stores.map {
            "\($0.urlString)|\($0.lastPrice.map(String.init(describing:)) ?? "")"
                + "|\($0.priceHistory.count)"
        }.joined(separator: ";")
        return [
            tracker.productName,
            tracker.imageFileName ?? "",
            // "none" is a real state: a tracker with no alert threshold at all.
            tracker.alertThresholdFraction.map { String($0) } ?? "none",
            String(tracker.isArchived),
            stores,
        ].joined(separator: "|")
    }

    /// A product row with no tracker payload has nothing of this kind to draw.
    func hasContent(for item: SavedItem) -> Bool { item.priceTracker != nil }

    /// A tracker's archived flag lives on the tracker, not on the row, so both
    /// are consulted: a row may be archived on only one of the two.
    func isArchived(_ item: SavedItem) -> Bool {
        item.isArchived || item.priceTracker?.isArchived == true
    }

    // MARK: - The card

    /// The editor: product image and title, seller list with its add button,
    /// read-only price graph, and the dedicated alert row.
    func cardContent(for item: SavedItem, host: CardPresenterHost)
        -> CardContentViewController?
    {
        guard item.priceTracker != nil else { return nil }
        return ProductCardContentViewController(itemID: item.id)
    }

    // MARK: - Strip and scrub preview

    /// The editor is a scrolling column of controls with hard edges, and a
    /// horizontal swipe pages the deck because nothing in it scrubs. It
    /// scrolls inside the deck's one card frame, matching every other kind's
    /// card rather than claiming a different rectangle for itself.
    func cardStyle(for item: SavedItem) -> CardCarouselCardStyle {
        var style = CardCarouselCardStyle()
        style.pagesOnInCardSwipes = true
        return style
    }

    func title(for item: SavedItem) -> String? {
        item.priceTracker?.productName
    }

    /// A product is marked by its tag, never by its seller's favicon.
    func loadSourceBadge(
        for item: SavedItem, completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(.symbol("tag.fill"))
    }

    func loadThumbnail(
        for item: SavedItem, host: CardPresenterHost,
        completion: @escaping (UIImage?) -> Void
    ) {
        PriceTrackerProductImage.load(
            imageFileName: item.priceTracker?.imageFileName,
            pageURL: item.priceTracker?.stores.first.flatMap { URL(string: $0.urlString) }
        ) { completion($0) }
    }

    /// A product chip is its own picture, with the app icon's green tag
    /// silhouette pinned bottom-trailing.
    func prefersThumbnailChip(for item: SavedItem) -> Bool { true }

    func loadMiniCarouselAccessory(
        for item: SavedItem, completion: @escaping (UIImage?) -> Void
    ) {
        PriceTrackerProductImage.load(
            imageFileName: item.priceTracker?.imageFileName,
            pageURL: item.priceTracker?.stores.first.flatMap { URL(string: $0.urlString) },
            completion: completion)
    }

    // MARK: - Verbs

    /// Share sits above the deck's own Archive/Delete, in both apps that show
    /// a product card.
    func menuActions(for item: SavedItem, host: CardPresenterHost) -> [UIMenuElement] {
        [
            UIAction(
                title: L10n.string("Common_share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self, weak host] _ in
                guard let self, let host else { return }
                self.share(item, host: host, sourceView: host.cardView(forItemID: item.id))
            },
        ]
    }

    /// What a product shares is the seller's page, not the save row's
    /// URL — a tracker with several stores is one save over many pages, and the
    /// first store is the one its card leads with. `sourceView` is nil when the
    /// card is not currently visible (for example, a menu reached another way);
    /// the share sheet then anchors to the deck itself.
    @discardableResult
    func share(_ item: SavedItem, host: CardPresenterHost, sourceView: UIView?) -> Bool {
        guard let urlString = item.priceTracker?.stores.first?.urlString,
              let url = URL(string: urlString)
        else { return false }
        LunaShareSheet.present(
            items: [url], from: host.presentingController,
            anchor: sourceView.map(LunaShareSheetAnchor.viewBounds))
        return true
    }

    /// Both stores this kind owns: the tracker's own flag and the saves-list
    /// row. Writing both keeps a product's archived state consistent across
    /// every app that shows it. Unarchiving also bumps the row's date, the
    /// one ordering rule's way of resurfacing a restored save — the same
    /// thing `markUnread` does for an article.
    func setArchived(_ archived: Bool, for item: SavedItem) {
        if var tracker = store.item(withID: item.id)?.priceTracker {
            tracker.isArchived = archived
            store.updatePriceTracker(tracker, for: item.id)
        }
        store.setArchived(archived, for: item.id)
        if !archived { store.bump(item.id) }
    }

    // MARK: - Lifecycle

    /// Arriving at an alerting tracker is how its alert is acknowledged, so it
    /// stops floating above the other cards' ordering.
    func itemDidCenter(_ item: SavedItem, host: CardPresenterHost) {
        guard var tracker = item.priceTracker, tracker.hasUnviewedAlert else { return }
        tracker.markAlertViewed()
        store.updatePriceTracker(tracker, for: item.id)
    }

    /// The card is the editor, so its own scroll view and controls own every
    /// touch. Consuming the tap keeps the deck from treating a product card
    /// as a reader and toggling immersion on it.
    @discardableResult
    func itemWasTapped(
        _ item: SavedItem, cardContent: CardContentViewController?,
        host: CardPresenterHost
    ) -> Bool { true }

    @discardableResult
    func openExternally(_ item: SavedItem, host: CardPresenterHost) -> Bool {
        guard let urlString = item.priceTracker?.stores.first?.urlString else { return false }
        InAppBrowser.present(urlString: urlString, from: host.presentingController)
        return true
    }

    // MARK: - Stores

    /// The price editor's own Save posts this; the deck answers by centering
    /// the tracker that was just written, in every app that shows a product
    /// card.
    func willBeginObservingStores(host: CardPresenterHost) {
        savedInteractivelyObserver = NotificationCenter.default.addObserver(
            forName: .priceTrackerSavedInteractively, object: nil, queue: .main
        ) { [weak host] notification in
            MainActor.assumeIsolated {
                guard let host else { return }
                if let id = notification.userInfo?["itemID"] as? UUID {
                    host.requestCentering(onItemID: id)
                }
                host.reloadDeck()
            }
        }
    }

    // MARK: - The archive tray

    /// A product's tray row leads with its name and its current best price,
    /// and its tap opens the seller's page.
    func archiveTrayItem(for item: SavedItem, host: CardPresenterHost)
        -> ArchiveTrayItem?
    {
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
                    imageFileName: tracker.imageFileName,
                    pageURL: tracker.stores.first.flatMap { URL(string: $0.urlString) },
                    completion: completion)
            },
            tap: { [weak self, weak host] in
                guard let self, let host else { return }
                _ = self.openExternally(item, host: host)
            },
            share: { [weak self, weak host] sourceView in
                guard let self, let host else { return }
                self.share(item, host: host, sourceView: sourceView)
            },
            unarchive: { [weak self, weak host] _ in
                guard let self, let host else { return }
                host.requestCentering(onItemID: item.id)
                self.setArchived(false, for: item)
                host.reloadDeck()
            },
            delete: { [weak host] in
                SavesStore.shared.delete(item)
                host?.reloadDeck()
            })
    }
}
