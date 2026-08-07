//
//  ProductCardPresenter.swift
//  Luna
//
//  The product kind's card behavior, defined ONCE for every app that shows a
//  price tracker — Luna Price Tracker and the central Luna app. Compiled into
//  exactly those two targets.
//
//  The central app used to render a tracked product as a generic link card
//  reading "Tap to see price history", with a globe badge, no product picture,
//  no share, no alert acknowledgement, and a fingerprint with no price in it (so
//  a price that moved never re-rendered). Tapping pushed a fullscreen editor.
//  Meanwhile the REAL in-card editor was compiled into that same binary, inside
//  the Price Tracker deck subclass, unreachable. Both apps now get this.
//

import LunaDesignSystem
import LunaModels
import LunaPriceUI
import LunaStorage
import UIKit

@MainActor
final class ProductCardPresenter: CardKindPresenting {

    private let store = ReadingListStore.shared
    /// Held so the interactive-save observer outlives `willBeginObservingStores`.
    private var savedInteractivelyObserver: NSObjectProtocol?

    // MARK: - Slot data

    /// A price change must re-render the card. The central app's fingerprint had
    /// no price component at all, so a tracker whose price moved kept drawing
    /// its old graph until something unrelated forced a reload.
    func fingerprint(for item: ReadingListItem) -> String {
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
    func hasContent(for item: ReadingListItem) -> Bool { item.priceTracker != nil }

    /// A tracker's archived flag lives on the tracker, not on the row — so both
    /// are consulted, which is what reconciles rows archived by only one of them
    /// before `setArchived` started writing both.
    func isArchived(_ item: ReadingListItem) -> Bool {
        item.isArchived || item.priceTracker?.isArchived == true
    }

    // MARK: - The card

    /// The real editor: product image and title, the price graph with its
    /// draggable alert threshold, and the seller list with its add button.
    func cardContent(for item: ReadingListItem, host: CardPresenterHost)
        -> CardContentViewController?
    {
        guard item.priceTracker != nil else { return nil }
        return ProductCardContentViewController(itemID: item.id)
    }

    // MARK: - Strip and scrub preview

    /// The editor is a scrolling column of controls with hard edges, and a
    /// horizontal swipe pages the deck because nothing in it scrubs. It used to
    /// take every point of the room (`.fill`) on the grounds that it has no
    /// aspect to honour — but sitting beside a 9:16 video card in the central
    /// app, "no aspect to honour" just meant "a different rectangle", so the
    /// column now scrolls inside the deck's one card frame.
    func cardStyle(for item: ReadingListItem) -> CardCarouselCardStyle {
        var style = CardCarouselCardStyle()
        style.pagesOnInCardSwipes = true
        return style
    }

    func title(for item: ReadingListItem) -> String? {
        item.priceTracker?.productName
    }

    /// A product is marked by its tag, never by its seller's favicon.
    func loadSourceBadge(
        for item: ReadingListItem, completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(.symbol("tag.fill"))
    }

    func loadThumbnail(
        for item: ReadingListItem, host: CardPresenterHost,
        completion: @escaping (UIImage?) -> Void
    ) {
        PriceTrackerProductImage.load(
            imageFileName: item.priceTracker?.imageFileName
        ) { completion($0 ?? PriceTrackerProductImage.fallback) }
    }

    /// A product chip is its own picture, with the app icon's green tag
    /// silhouette pinned bottom-trailing.
    func prefersThumbnailChip(for item: ReadingListItem) -> Bool { true }

    func loadMiniCarouselAccessory(
        for item: ReadingListItem, completion: @escaping (UIImage?) -> Void
    ) {
        completion(PriceTrackerTagIcon.image(size: 22))
    }

    // MARK: - Verbs

    /// Share sits above the deck's own Archive/Delete, as it always did here —
    /// and now in the central app too, which offered a product no share at all.
    func menuActions(for item: ReadingListItem, host: CardPresenterHost) -> [UIMenuElement] {
        [
            UIAction(
                title: L10n.string("Common_share"), image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self, weak host] _ in
                guard let self, let host else { return }
                self.share(
                    item, host: host,
                    sourceView: host.cardView(forItemID: item.id)
                        ?? host.presentingController.view!)
            },
        ]
    }

    /// What a product shares is the SELLER's page, not the reading-list row's
    /// URL — a tracker with several stores is one save over many pages, and the
    /// first store is the one its card leads with.
    @discardableResult
    func share(_ item: ReadingListItem, host: CardPresenterHost, sourceView: UIView) -> Bool {
        guard let urlString = item.priceTracker?.stores.first?.urlString,
              let url = URL(string: urlString)
        else { return false }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        host.presentingController.present(sheet, animated: true)
        return true
    }

    /// Both stores this kind owns: the tracker's own flag and the reading-list
    /// row. They were written separately, so a product archived in one app
    /// stayed live in the other. Unarchiving also bumps the row's date, which is
    /// the ONE ordering rule's way of resurfacing a restored save — the same
    /// thing `markUnread` does for an article.
    func setArchived(_ archived: Bool, for item: ReadingListItem) {
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
    func itemDidCenter(_ item: ReadingListItem, host: CardPresenterHost) {
        guard var tracker = item.priceTracker, tracker.hasUnviewedAlert else { return }
        tracker.markAlertViewed()
        store.updatePriceTracker(tracker, for: item.id)
    }

    /// The card IS the editor, so its own scroll view and controls own every
    /// touch. Consuming the tap is what keeps the central app's deck from
    /// treating a product card as a reader and toggling immersion on it.
    @discardableResult
    func itemWasTapped(
        _ item: ReadingListItem, cardContent: CardContentViewController?,
        host: CardPresenterHost
    ) -> Bool { true }

    @discardableResult
    func openExternally(_ item: ReadingListItem, host: CardPresenterHost) -> Bool {
        guard let urlString = item.priceTracker?.stores.first?.urlString else { return false }
        InAppBrowser.present(urlString: urlString, from: host.presentingController)
        return true
    }

    // MARK: - Stores

    /// The price editor's own Save posts this; the deck answers by centering the
    /// tracker that was just written. It used to be an observer on the Price
    /// Tracker deck subclass, so the central app never centered a product save
    /// made from the editor.
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

    /// A product's tray row leads with its name and its current best price, and
    /// its tap opens the seller's page. The central app showed a favicon, the
    /// save date, and a tap that asked for a reader it could never build.
    func archiveTrayItem(for item: ReadingListItem, host: CardPresenterHost)
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
                    imageFileName: tracker.imageFileName
                ) { completion($0 ?? PriceTrackerProductImage.fallback) }
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
                ReadingListStore.shared.delete(item)
                host?.reloadDeck()
            })
    }
}
